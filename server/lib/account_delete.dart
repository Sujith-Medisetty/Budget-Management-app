import 'account_cleanup.dart';
import 'auth.dart';
import 'backup_scheduler.dart';
import 'backup_snapshot.dart';
import 'config.dart';
import 'crypto.dart';
import 'dart:async';
import 'dart:convert';
import 'gmail_filter_rules.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';

/// `POST /account/delete` — explicit user-driven nuclear wipe.
///
/// Distinct from `/oauth/signout` and the FCM `UNREGISTERED` path:
/// those preserve the GCS backup so the same Google account can
/// sign back in and recover. THIS endpoint is "I'm done with Pocket
/// forever" and so it deletes the backup too.
///
/// Idempotent by design. Each wipe step is wrapped to swallow
/// "already gone" errors (Firestore 404s are not founds — they mean
/// the previous attempt did its job). A client retrying after a
/// transient failure won't double-wipe anything that matters.
Handler accountDeleteHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenCipher cipher,
  TokenAuth auth,
  FilterRuleStore rules,
  BackupStore backups, {
  BackupScheduler? backupScheduler,
}) {
  final log = Logger('account-delete');
  return (Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response.forbidden('missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(authHeader.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) return Response.forbidden('invalid token');
      sub = s;
    } on FormatException catch (e) {
      return Response.forbidden('bad token: ${e.message}');
    }

    log.info('account delete requested by $sub');

    // Reuses the same trail as the FCM-detected uninstall path, with
    // the explicit `backups:` arg passed so the GCS object goes too.
    // Each step is internally best-effort — `deleteAccountCompletely`
    // logs and continues on per-step failures, so the user always
    // gets a clear "deleted" outcome from their POV.
    await deleteAccountCompletely(
      config: config,
      tokens: tokens,
      cipher: cipher,
      rules: rules,
      backups: backups,
      backupScheduler: backupScheduler,
      sub: sub,
      reason: 'user-requested-account-delete',
    );

    return Response.ok(jsonEncode({'deleted': true, 'sub': sub}),
        headers: {'content-type': 'application/json'});
  };
}

// A read-only "what's my last backup timestamp" check for the
// mobile-side freshness gate before delete. The mobile uses this to
// prompt "take a fresh backup first" if the last one is too old.
// Lives here as an extension rather than in `backup_snapshot.dart`
// because it depends on a `BackupStore` implementation.
extension BackupFreshness on BackupStore {
  Future<DateTime?> backupUploadedAt(String sub) async =>
      (await get(sub))?.uploadedAt;
}

