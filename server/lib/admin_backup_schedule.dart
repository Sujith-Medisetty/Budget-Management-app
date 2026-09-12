import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'config.dart';
import 'gcp_scheduler_client.dart';
import 'token_store.dart';

/// Per-user Cloud Scheduler job management. Replaces the
/// single-shared `pocket-backup-fanout` job (still in deploy.sh as
/// a safety-net-disabled job) with one HTTP job per active user,
/// named `pocket-backup-{sub}`. The job points at
/// `/admin/trigger-backup-fcm?sub={sub}` and fires on the user's
/// chosen local hour:minute in their IANA timezone.
///
/// Auth gate: the path's `sub` must match the authenticated user's
/// `sub` (or the user is the admin). This lets the client call it
/// directly from the Backup settings screen — the user is the one
/// who knows their own sub. Admin can call on behalf of any user.

/// The Cloud Run service URL the per-user job POSTs to. Built
/// from [ServerConfig.pubsubAudience] (the same value the
/// /pubsub/push handler validates against) by stripping the
/// `/pubsub/push` suffix.
String _serviceUrl(ServerConfig config) =>
    config.pubsubAudience.replaceFirst('/pubsub/push', '');

/// Job name for a user. Public so the deploy script and tests can
/// reach the same convention.
String backupJobNameForSub(String sub) => 'pocket-backup-$sub';

/// Returns null on success, or a `Response` describing the failure.
/// Pass-through so the caller can chain cleanly: `final deny = ...
/// ; if (deny != null) return deny;`.
Future<Response?> _authorize({
  required ServerConfig config,
  required TokenStore tokens,
  required TokenAuth auth,
  required Request req,
  required String targetSub,
  required String logTag,
}) async {
  final log = Logger(logTag);
  final bearer = req.headers['authorization'];
  if (bearer == null || !bearer.startsWith('Bearer ')) {
    return Response.forbidden('missing bearer');
  }
  final token = bearer.substring(7);
  Map<String, dynamic> claims;
  try {
    if (auth.looksLikeOidc(token)) {
      // OIDC isn't expected to hit these endpoints today (only Cloud
      // Scheduler OIDC pushes /admin/trigger-backup-fcm), but we
      // accept it under the same audience rule as the rest of the
      // admin surface so the gate is uniform.
      await auth.verifyPubSubJwt(token, _serviceUrl(config));
      // The OIDC token's `sub` is the service account identity, not
      // a Pocket user — only allow if the caller is the admin
      // service account (we approximate that as "matches admin
      // email's account").
      final adminEmail = config.adminEmail;
      if (adminEmail == null || adminEmail.isEmpty) {
        return Response.forbidden('admin not configured');
      }
      final adminRecord = await tokens.findByEmail(adminEmail);
      if (adminRecord == null || adminRecord.sub != targetSub) {
        return Response.forbidden('oidc caller not allowed for this sub');
      }
      return null;
    }
    claims = auth.verifyApiToken(token);
  } on FormatException catch (e) {
    log.warning('token verify failed: ${e.message}');
    return Response.forbidden('bad token');
  } catch (e) {
    log.warning('token verify failed: $e');
    return Response.forbidden('auth error');
  }
  final sub = claims['sub'] as String?;
  if (sub == null) return Response.forbidden('invalid token');
  if (sub == targetSub) return null;
  // Admin can act on behalf of any sub.
  if (!config.adminEnabled) {
    return Response.forbidden('not allowed');
  }
  final account = await tokens.get(sub);
  if (account == null || account.email != config.adminEmail) {
    return Response.forbidden('not allowed');
  }
  return null;
}

/// `POST /admin/backup-schedule` — create, update, or delete the
/// per-user Cloud Scheduler job. Body:
///   `{ "sub": "<googleSub>", "hour": 22, "minute": 0,
///      "timeZone": "America/Los_Angeles", "enabled": true }`
///   (the path-param syntax shown is a placeholder — actual sub is
///   the user's Google subject id)
///
/// When `enabled=true`, the named job is created (or updated if it
/// already exists) with cron `$minute $hour * * *`. When false, the
/// job is deleted — the user explicitly opted out, so we tear the
/// trigger down rather than firing FCMs they'll just ignore.
Future<Response> Function(Request) backupScheduleHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  GcpSchedulerClient? scheduler,
  String? oidcServiceAccountEmail,
}) {
  final log = Logger('backup-schedule');
  final s = scheduler ?? GcpSchedulerClient(config);

  return (Request req) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }
    final sub = body['sub'];
    final hour = body['hour'];
    final minute = body['minute'];
    final timeZone = body['timeZone'];
    final enabled = body['enabled'];
    if (sub is! String) {
      return Response.badRequest(body: 'sub (string) required');
    }
    if (enabled is! bool) {
      return Response.badRequest(body: 'enabled (bool) required');
    }
    if (enabled) {
      if (hour is! int || minute is! int || timeZone is! String) {
        return Response.badRequest(
            body: 'hour (int), minute (int), timeZone (string) required '
                'when enabled=true');
      }
      if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
        return Response.badRequest(
            body: 'hour must be 0..23 and minute 0..59');
      }
    }

    final deny = await _authorize(
      config: config,
      tokens: tokens,
      auth: auth,
      req: req,
      targetSub: sub,
      logTag: 'backup-schedule',
    );
    if (deny != null) return deny;

    final jobName = backupJobNameForSub(sub);

    // The Cloud Scheduler job and the Firestore `accounts.backupPrefs`
    // field must stay in lockstep — the hydrator reads `backupPrefs`
    // on every sign-in to rebuild local state. If we only manage the
    // job, the next sign-in re-creates the job from stale Firestore
    // state (or vice versa). Mirror the change into the account
    // record here so a single POST handles both sides.
    final currentRecord = await tokens.get(sub);
    if (currentRecord == null) {
      return Response(404,
          body: jsonEncode({'error': 'no account for $sub'}),
          headers: {'content-type': 'application/json'});
    }
    final nextPrefs = enabled
        ? BackupPrefs(
            enabled: true,
            hour: hour as int,
            minute: minute as int,
            // Carry forward the cadence + notify flags the user
            // already configured — this endpoint only manages
            // enabled/hour/minute, the rest ride along on
            // PATCH /accounts/<sub>.
            frequency: currentRecord.backupPrefs.frequency,
            notifyComplete: currentRecord.backupPrefs.notifyComplete,
            notifyFailed: currentRecord.backupPrefs.notifyFailed,
            notifyRestoreComplete:
                currentRecord.backupPrefs.notifyRestoreComplete,
          )
        : const BackupPrefs(enabled: false);
    final now = DateTime.now().toUtc();
    final updatedRecord = currentRecord.copyWith(
      backupPrefs: nextPrefs,
      createdAt: currentRecord.createdAt ?? now,
      updatedAt: now,
    );
    try {
      await tokens.put(sub, updatedRecord);
    } catch (e) {
      log.warning('firestore put($sub) failed: $e');
      return Response(502,
          body: jsonEncode({'error': 'firestore put failed: $e'}),
          headers: {'content-type': 'application/json'});
    }

    if (!enabled) {
      // Disable + delete: the user opted out. We tear the job down
      // rather than disabling it (no reason to keep dead config
      // around). Idempotent — 404 is fine.
      try {
        await s.deleteJob(jobName);
      } catch (e) {
        log.warning('delete $jobName failed: $e');
        return Response(502,
            body: jsonEncode({'error': 'scheduler delete failed: $e'}),
            headers: {'content-type': 'application/json'});
      }
      return Response.ok(
        jsonEncode({
          'sub': sub,
          'enabled': false,
          'jobName': jobName,
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Upsert: try GET first; if 404, create; otherwise PATCH the
    // existing schedule. PATCH-then-CREATE-with-updateMask doesn't
    // work on a non-existent job (Cloud Scheduler returns 404).
    final existing = await s.getJob(jobName);
    final schedule = '$minute $hour * * *';
    try {
      if (existing == null) {
        final res = await s.createJob(
          jobName: jobName,
          schedule: schedule,
          timeZone: timeZone as String,
          uri: '${_serviceUrl(config)}/admin/trigger-backup-fcm?sub=$sub',
          oidcServiceAccountEmail:
              oidcServiceAccountEmail ?? _defaultOidcSa(config),
          audience: _serviceUrl(config),
        );
        log.info('created $jobName: schedule="$schedule" tz="$timeZone"');
        return Response.ok(
          jsonEncode({
            'sub': sub,
            'enabled': true,
            'hour': hour,
            'minute': minute,
            'timeZone': timeZone,
            'jobName': res.jobName,
            'schedule': res.schedule,
          }),
          headers: {'content-type': 'application/json'},
        );
      }
      final res = await s.patchJob(
        jobName,
        schedule: schedule,
        timeZone: timeZone as String,
      );
      log.info('patched $jobName: schedule="$schedule" tz="$timeZone"');
      return Response.ok(
        jsonEncode({
          'sub': sub,
          'enabled': true,
          'hour': hour,
          'minute': minute,
          'timeZone': timeZone,
          'jobName': res.jobName,
          'schedule': res.schedule,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      log.warning('upsert $jobName failed: $e');
      return Response(502,
          body: jsonEncode({'error': 'scheduler upsert failed: $e'}),
          headers: {'content-type': 'application/json'});
    }
  };
}

/// `GET /admin/backup-schedule/{sub}` — return the current job
/// state for the named sub. 404 means "no job" (= user hasn't
/// enabled backup). The path's sub is the auth subject.
Future<Response> Function(Request) backupScheduleGetHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  GcpSchedulerClient? scheduler,
}) {
  final s = scheduler ?? GcpSchedulerClient(config);

  return (Request req) async {
    // shelf_router passes the `{sub}` capture as `req.params['sub']`.
    final sub = req.params['sub'];
    if (sub == null || sub.isEmpty) {
      return Response.badRequest(body: 'sub path param required');
    }
    final deny = await _authorize(
      config: config,
      tokens: tokens,
      auth: auth,
      req: req,
      targetSub: sub,
      logTag: 'backup-schedule-get',
    );
    if (deny != null) return deny;

    final jobName = backupJobNameForSub(sub);
    final job = await s.getJob(jobName);
    if (job == null) {
      return Response(404,
          body: jsonEncode({'error': 'no schedule for $sub'}),
          headers: {'content-type': 'application/json'});
    }
    // Cloud Scheduler stores schedule as a cron string and timeZone
    // as an IANA name. We parse the cron back to hour/minute so the
    // client can render the Backup screen without a second round
    // trip. Cron is always 5 fields: "minute hour * * *".
    final parts = job.schedule.split(' ');
    int? hour;
    int? minute;
    if (parts.length == 5) {
      minute = int.tryParse(parts[0]);
      hour = int.tryParse(parts[1]);
    }
    return Response.ok(
      jsonEncode({
        'sub': sub,
        'enabled': true,
        'hour': hour,
        'minute': minute,
        'timeZone': job.timeZone,
        'jobName': job.jobName,
        'schedule': job.schedule,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `DELETE /admin/backup-schedule/{sub}` — explicit teardown for
/// sign-out. Same auth as the POST/GET. Idempotent.
Future<Response> Function(Request) backupScheduleDeleteHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  GcpSchedulerClient? scheduler,
}) {
  final log = Logger('backup-schedule-delete');
  final s = scheduler ?? GcpSchedulerClient(config);

  return (Request req) async {
    final sub = req.params['sub'];
    if (sub == null || sub.isEmpty) {
      return Response.badRequest(body: 'sub path param required');
    }
    final deny = await _authorize(
      config: config,
      tokens: tokens,
      auth: auth,
      req: req,
      targetSub: sub,
      logTag: 'backup-schedule-delete',
    );
    if (deny != null) return deny;

    final jobName = backupJobNameForSub(sub);
    try {
      await s.deleteJob(jobName);
    } catch (e) {
      log.warning('delete $jobName failed: $e');
      return Response(502,
          body: jsonEncode({'error': 'scheduler delete failed: $e'}),
          headers: {'content-type': 'application/json'});
    }
    return Response.ok(
      jsonEncode({'sub': sub, 'enabled': false, 'jobName': jobName}),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// Default OIDC service account for the scheduler job to assume
/// when calling the Cloud Run service. The same SA `deploy.sh`
/// grants `roles/run.invoker` on the service. Kept here as a
/// constant so test wiring can override it; production uses the
/// `pocket-server@<project>.iam` SA.
String _defaultOidcSa(ServerConfig config) =>
    'pocket-server@${config.gcpProject}.iam.gserviceaccount.com';
