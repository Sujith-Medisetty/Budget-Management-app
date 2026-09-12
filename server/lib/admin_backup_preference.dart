import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'config.dart';
import 'gcp_scheduler_client.dart';
import 'token_store.dart';

/// `POST /admin/backup-preference` — the admin saves a new daily backup
/// time in the app, the app calls this endpoint, and the server
/// repoints Cloud Scheduler's `pocket-backup-fanout` job onto the new
/// local hour:minute. The previous architecture hardcoded the cron at
/// `0 3 * * * UTC` (set by deploy.sh) and trusted a device-side ±60 min
/// window to silently filter out users whose saved time didn't happen
/// to fall near that wall clock — quietly dropping every such backup.
///
/// With this endpoint the saved time *is* the scheduled time: the
/// fanout fires inside the user's local hour, the device sees the
/// trigger arrive during its preferred window, and the upload runs.
///
/// Auth: same admin gate as the other /admin/* endpoints — either
///   - OIDC from a Google-managed caller (the Cloud Run service
///     account itself, via Pub/Sub or another Google trigger — gated
///     on the `aud` claim), or
///   - Mobile Bearer (HS256 Pocket apiToken) whose resolved account
///     email matches `ADMIN_EMAIL`.
/// For v1, only the admin uses this endpoint from the mobile app, so
/// no per-user preferences are stored — `pocket-backup-fanout` is a
/// single shared job that everyone receives.
///
/// Body:
///   `{ "hour": 19, "minute": 0, "timeZone": "America/Los_Angeles" }`
///
/// Validations are minimal but strict — Cloud Scheduler rejects
/// malformed values too, but fronting them with a 400 here gives the
/// mobile side a useful error instead of "scheduler PATCH 400".
Future<Response> Function(Request) backupPreferenceHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  GcpSchedulerClient? scheduler,
}) {
  final log = Logger('backup-preference');
  final s = scheduler ?? GcpSchedulerClient(config);

  return (Request req) async {
    if (!config.adminEnabled) {
      return Response.forbidden('admin endpoint disabled');
    }
    // Same admin gate as trigger-backup-fcm + apply-billing-retention:
    // OIDC (via looksLikeOidc) OR Pocket apiToken whose account is
    // the admin email.
    final bearer = req.headers['authorization'];
    if (bearer != null && bearer.startsWith('Bearer ')) {
      final token = bearer.substring(7);
      try {
        if (auth.looksLikeOidc(token)) {
          final serviceUrl =
              config.pubsubAudience.replaceFirst('/pubsub/push', '');
          await auth.verifyPubSubJwt(token, serviceUrl);
        } else {
          final claims = auth.verifyApiToken(token);
          final sub = claims['sub'] as String?;
          if (sub == null) {
            return Response.forbidden('invalid token');
          }
          final account = await tokens.get(sub);
          if (account == null || account.email != config.adminEmail) {
            return Response.forbidden('not admin');
          }
        }
      } catch (e) {
        log.warning('admin gate failed: $e');
        return Response.forbidden('auth error');
      }
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }

    final hour = body['hour'];
    final minute = body['minute'];
    final timeZone = body['timeZone'];
    if (hour is! int || minute is! int || timeZone is! String) {
      return Response.badRequest(
          body: 'hour (int), minute (int), timeZone (string) required');
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return Response.badRequest(
          body: 'hour must be 0..23 and minute 0..59');
    }
    // Cloud Scheduler accepts any IANA TZ identifier Google knows
    // about. We don't validate client-side — a typo here produces a
    // 400 from the API that's surfaced through the snackbar.
    final schedule = '$minute $hour * * *';
    log.info(
        'patching ${GcpSchedulerClient.backupFanoutJob}: '
        'schedule="$schedule" tz="$timeZone"');

    try {
      final res = await s.patchJob(
        GcpSchedulerClient.backupFanoutJob,
        schedule: schedule,
        timeZone: timeZone,
      );
      return Response.ok(
        jsonEncode({
          'jobName': res.jobName,
          'schedule': res.schedule,
          'timeZone': res.timeZone,
          'hour': hour,
          'minute': minute,
        }),
        headers: {'content-type': 'application/json'},
      );
    } catch (e) {
      log.warning('patch failed: $e');
      return Response(502,
          body: jsonEncode({'error': 'scheduler patch failed: $e'}),
          headers: {'content-type': 'application/json'});
    }
  };
}
