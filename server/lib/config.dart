import 'package:dotenv/dotenv.dart';

class ServerConfig {
  const ServerConfig({
    required this.gcpProject,
    required this.pubsubTopic,
    required this.webClientId,
    required this.webClientSecret,
    required this.pubsubAudience,
    required this.apiTokenSecret,
    required this.tokenEncryptionKey,
    required this.gmailTestMode,
    required this.oauthTestMode,
    required this.fcmDryRun,
    required this.fcmProjectId,
    this.fcmServiceAccountJsonPath,
    this.adminEmail,
    this.gcsBackupBucket = 'pocket-backups',
  });

  // GCP project hosting Pub/Sub, Firestore, FCM, Cloud Run.
  final String gcpProject;

  // Fully-qualified Pub/Sub topic — the target we pass to users.watch().
  final String pubsubTopic;
  final String webClientId;
  final String webClientSecret;

  // Equals the Cloud Run service URL — Google sets this as `aud`.
  final String pubsubAudience;

  // HS256 secret for short-lived API tokens handed to mobile.
  final String apiTokenSecret;

  // 32-byte hex (64 chars) key for AES-GCM encryption of refresh tokens.
  final String tokenEncryptionKey;

  // Test seams — when true, handlers skip real Google/Firestore calls
  // and use canned responses. Local dev only; never set in prod.
  final bool gmailTestMode;
  final bool oauthTestMode;
  final bool fcmDryRun;
  final String fcmProjectId;
  final String? fcmServiceAccountJsonPath;

  // Gmail address allowed to reach the `/admin/*` backup endpoints. The
  // API token only carries a numeric `sub`, so the handler resolves
  // sub -> account email and compares it here. Null disables those
  // endpoints entirely (403), which is the safe default for any deploy
  // that forgets to set it.
  final String? adminEmail;

  // GCS bucket that holds one gzipped JSON blob per user at
  // `{googleSub}.json.gz`. Defaults to `pocket-backups` so the
  // production deploy doesn't need to set the env var explicitly —
  // any other env (staging, local) overrides via `GCS_BACKUP_BUCKET`.
  final String gcsBackupBucket;

  bool get adminEnabled => (adminEmail ?? '').isNotEmpty;

  /// The bare Cloud Run service URL — derived from [pubsubAudience]
  /// by stripping the trailing `/pubsub/push`. Used by the Firestore
  /// event handler to construct the per-user scheduler URI.
  String get serverPublicUrl {
    final aud = pubsubAudience;
    const suffix = '/pubsub/push';
    return aud.endsWith(suffix) ? aud.substring(0, aud.length - suffix.length) : aud;
  }
}

/// Reads config from a single source: dotenv's merged map (which
/// includes Platform.environment when `includePlatformEnvironment` is
/// true). This way:
///   - Local dev: `dart run bin/main.dart` reads from `.env`.
///   - Cloud Run: no `.env` file, env vars come from the service config.
/// Both paths converge on `dotenv['KEY']`.
ServerConfig loadConfig(DotEnv dotenv) {
  String env(String key) {
    if (!dotenv.isDefined(key)) {
      throw StateError('Missing required env var: $key');
    }
    return dotenv[key]!;
  }

  String? envOpt(String key) => dotenv[key];

  return ServerConfig(
    gcpProject: env('GCP_PROJECT'),
    pubsubTopic: env('PUBSUB_TOPIC'),
    webClientId: env('WEB_CLIENT_ID'),
    webClientSecret: env('WEB_CLIENT_SECRET'),
    pubsubAudience: env('PUBSUB_AUDIENCE'),
    apiTokenSecret: env('API_TOKEN_SECRET'),
    tokenEncryptionKey: env('TOKEN_ENCRYPTION_KEY'),
    gmailTestMode: (dotenv['GMAIL_TEST_MODE'] ?? '') == '1',
    oauthTestMode: (dotenv['OAUTH_TEST_MODE'] ?? '') == '1',
    fcmDryRun: (dotenv['FCM_DRY_RUN'] ?? '') == '1',
    fcmProjectId: env('FCM_PROJECT_ID'),
    fcmServiceAccountJsonPath: envOpt('FCM_SERVICE_ACCOUNT_JSON'),
    adminEmail: envOpt('ADMIN_EMAIL'),
    gcsBackupBucket: dotenv['GCS_BACKUP_BUCKET'] ?? 'pocket-backups',
  );
}
