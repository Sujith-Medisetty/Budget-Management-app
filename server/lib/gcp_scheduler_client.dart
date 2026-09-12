import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart' as auth_io;
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'config.dart';

/// Thin wrapper over the Cloud Scheduler REST API. Currently used by
/// `POST /admin/backup-preference` to re-point the daily backup
/// fanout job onto whatever hour:minute the user just saved in the
/// app — the original deploy.sh hardcoded a single 03:00 UTC cron and
/// the device-side ±60 min window silently dropped every backup whose
/// local preference wasn't near that wall clock.
///
/// Auth: same `cloud-platform` service account already mounted via
/// `FCM_SERVICE_ACCOUNT_JSON` (the same key BigQuery + FCM use). The
/// account needs `roles/cloudscheduler.admin` on the project — that
/// binding is added out-of-band; this client doesn't grant it.
class GcpSchedulerClient {
  GcpSchedulerClient(this.config, {http.Client? client}) : _injected = client;

  /// The fixed job name the deploy.sh creates for daily backup
  /// fanout. Pulled out so the handler, the deploy script, and this
  /// client can't drift.
  static const String backupFanoutJob = 'pocket-backup-fanout';

  final ServerConfig config;
  final http.Client? _injected;
  http.Client? _client;
  static const _scope = 'https://www.googleapis.com/auth/cloud-platform';
  final _log = Logger('gcp-scheduler');

  String get _region => 'us-central1';

  Future<http.Client> _authed() async {
    final injected = _injected;
    if (injected != null) return injected;
    if (_client != null) return _client!;
    final path = config.fcmServiceAccountJsonPath;
    if (path == null) {
      throw StateError('FCM_SERVICE_ACCOUNT_JSON must be set');
    }
    final raw = await File(path).readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final creds = auth_io.ServiceAccountCredentials.fromJson(json);
    _client = await auth_io.clientViaServiceAccount(creds, [_scope]);
    return _client!;
  }

  Future<void> close() async {
    _client?.close();
    _client = null;
  }

  /// PATCH the named job's [schedule] (cron 5-field, e.g. `"0 19 * * *"`)
  /// and [timeZone] (IANA TZ string like `America/Los_Angeles` or `UTC`).
  /// Returns the new schedule / timeZone on success; throws on any
  /// non-2xx response so the handler can surface a useful error.
  Future<JobPatchResult> patchJob(
    String jobName, {
    required String schedule,
    required String timeZone,
  }) async {
    final c = await _authed();
    // updateMask tells Cloud Scheduler to merge ONLY the listed fields
    // into the existing job. Without it the API requires every
    // required field (target, retryConfig, etc.) to be resent in the
    // body — a partial PATCH returns 400 "Job.target must be set".
    final uri = Uri.parse(
      'https://cloudscheduler.googleapis.com/v1/'
      'projects/${config.gcpProject}/locations/$_region/jobs/$jobName'
      '?updateMask=schedule,timeZone',
    );
    final res = await c.patch(
      uri,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'schedule': schedule,
        'timeZone': timeZone,
      }),
    );
    if (res.statusCode != 200) {
      _log.warning('PATCH $jobName failed: ${res.statusCode} ${res.body}');
      throw StateError(
          'cloudscheduler PATCH $jobName: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return JobPatchResult(
      jobName: jobName,
      schedule: body['schedule'] as String? ?? schedule,
      timeZone: body['timeZone'] as String? ?? timeZone,
    );
  }

  /// Create a new HTTP job. Used for the per-user
  /// `pocket-backup-{sub}` scheduler. Returns the API's response
  /// (jobName, schedule, timeZone) on success; throws on non-2xx.
  ///
  /// [uri] is the HTTPS endpoint the job POSTs to on each fire.
  /// [oidcServiceAccountEmail] is the identity Cloud Scheduler uses
  /// when calling [uri] (must be granted `roles/run.invoker` on
  /// the Cloud Run service). [audience] is the `aud` claim baked
  /// into the OIDC token — typically the bare Cloud Run service
  /// URL.
  Future<JobCreateResult> createJob({
    required String jobName,
    required String schedule,
    required String timeZone,
    required String uri,
    required String oidcServiceAccountEmail,
    required String audience,
  }) async {
    final c = await _authed();
    final res = await c.post(
      Uri.parse(
        'https://cloudscheduler.googleapis.com/v1/'
        'projects/${config.gcpProject}/locations/$_region/jobs',
      ),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        // Cloud Scheduler's create endpoint requires the job's `name`
        // be the fully-qualified path
        // `projects/{project}/locations/{region}/jobs/{jobName}`.
        // The shorter `{jobName}` form is only valid on UPDATE.
        'name':
            'projects/${config.gcpProject}/locations/$_region/jobs/$jobName',
        'description': 'Pocket per-user backup trigger',
        'schedule': schedule,
        'timeZone': timeZone,
        'httpTarget': {
          'uri': uri,
          'httpMethod': 'POST',
          'oidcToken': {
            'serviceAccountEmail': oidcServiceAccountEmail,
            'audience': audience,
          },
        },
        // Cloud Scheduler's retryConfig uses maxRetryDuration /
        // minBackoff / maxBackoff / maxDoublings — no maxAttempts.
        // Defaults match the existing fanout job (5s min, 3600s max,
        // 5 doublings). The device's own upload retry handles real
        // failures, so scheduler-level retries are just a safety
        // net for transient 5xx.
      }),
    );
    if (res.statusCode != 200 && res.statusCode != 201) {
      _log.warning('create $jobName failed: ${res.statusCode} ${res.body}');
      throw StateError(
          'cloudscheduler create $jobName: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return JobCreateResult(
      jobName: (body['name'] as String?) ?? jobName,
      schedule: body['schedule'] as String? ?? schedule,
      timeZone: body['timeZone'] as String? ?? timeZone,
    );
  }

  /// Look up an existing job. Returns null if the job doesn't exist
  /// (404). Throws on other non-2xx responses.
  Future<JobGetResult?> getJob(String jobName) async {
    final c = await _authed();
    final res = await c.get(
      Uri.parse(
        'https://cloudscheduler.googleapis.com/v1/'
        'projects/${config.gcpProject}/locations/$_region/jobs/$jobName',
      ),
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      _log.warning('get $jobName failed: ${res.statusCode} ${res.body}');
      throw StateError(
          'cloudscheduler get $jobName: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return JobGetResult(
      jobName: body['name'] as String? ?? jobName,
      schedule: body['schedule'] as String? ?? '',
      timeZone: body['timeZone'] as String? ?? 'UTC',
    );
  }

  /// Delete an existing job. Idempotent: 404 is treated as success
  /// (the user-facing intent is "ensure the job does not exist").
  /// Throws on other non-2xx responses.
  Future<void> deleteJob(String jobName) async {
    final c = await _authed();
    final res = await c.delete(
      Uri.parse(
        'https://cloudscheduler.googleapis.com/v1/'
        'projects/${config.gcpProject}/locations/$_region/jobs/$jobName',
      ),
    );
    if (res.statusCode == 404) return;
    if (res.statusCode != 200) {
      _log.warning('delete $jobName failed: ${res.statusCode} ${res.body}');
      throw StateError(
          'cloudscheduler delete $jobName: ${res.statusCode} ${res.body}');
    }
    _log.info('deleted scheduler job $jobName');
  }
}

class JobPatchResult {
  const JobPatchResult({
    required this.jobName,
    required this.schedule,
    required this.timeZone,
  });
  final String jobName;
  final String schedule;
  final String timeZone;
}

class JobCreateResult {
  const JobCreateResult({
    required this.jobName,
    required this.schedule,
    required this.timeZone,
  });
  final String jobName;
  final String schedule;
  final String timeZone;
}

class JobGetResult {
  const JobGetResult({
    required this.jobName,
    required this.schedule,
    required this.timeZone,
  });
  final String jobName;
  final String schedule;
  final String timeZone;
}
