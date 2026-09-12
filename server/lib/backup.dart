import 'auth.dart';
import 'backup_snapshot.dart';
import 'config.dart';
import 'dart:async';
import 'dart:convert';
import 'fcm.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';

/// `POST /backup/upload` — atomic overwrite of the user's single
/// backup object in GCS. Body:
///   `{ "transactions": [<row>...], "budgets": [<row>...] }`
///
/// Each row is a Map matching the SQLite schema (so the mobile side
/// can do straight INSERTs without field renaming). Returns
/// `{ "uploadedAt": "<iso>", "transactions": N, "budgets": N }`.
///
/// Auth: Bearer apiToken. Same auth the rest of the mobile-facing
/// endpoints use — the backup contains the user's own data so any
/// authenticated Pocket session can write or read it.
///
/// Size sanity cap: 100 MB request body uncompressed. At ~200 bytes/
/// transaction that's ~580,000 transactions — way more than any
/// human user could plausibly produce. Going over almost certainly
/// means a bug on the client, not a legitimate backup; rejecting
/// early keeps the GCS object small and stops a runaway loop from
/// blowing past the bucket's free tier.
const int _maxBodyBytes = 100 * 1024 * 1024;

Future<Response> Function(Request) backupUploadHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  required BackupStore store,
}) {
  final log = Logger('backup-upload');

  return (Request req) async {
    await store.init();

    final authHeader = req.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response.forbidden('missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(authHeader.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) {
        return Response.forbidden('invalid token');
      }
      sub = s;
    } on FormatException catch (e) {
      return Response.forbidden('bad token: ${e.message}');
    }

    final raw = await req.readAsString();
    if (raw.length > _maxBodyBytes) {
      return Response(413,
          body: 'backup payload too large: ${raw.length} > $_maxBodyBytes');
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }

    final txnsRaw = body['transactions'];
    final budgetsRaw = body['budgets'];
    if (txnsRaw is! List || budgetsRaw is! List) {
      return Response.badRequest(
          body: 'transactions + budgets must be arrays');
    }
    final transactions = <Map<String, Object?>>[];
    for (final r in txnsRaw) {
      if (r is! Map) {
        return Response.badRequest(body: 'transaction rows must be objects');
      }
      transactions.add(r.cast<String, Object?>());
    }
    final budgets = <Map<String, Object?>>[];
    for (final r in budgetsRaw) {
      if (r is! Map) {
        return Response.badRequest(body: 'budget rows must be objects');
      }
      budgets.add(r.cast<String, Object?>());
    }

    await store.put(sub,
        transactions: transactions, budgets: budgets);
    log.info('backup uploaded: ${transactions.length} txns, '
        '${budgets.length} budgets for $sub');

    return Response.ok(
      jsonEncode({
        'uploadedAt': DateTime.now().toUtc().toIso8601String(),
        'transactions': transactions.length,
        'budgets': budgets.length,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `GET /backup/current` — returns the user's single backup document.
/// Response shape:
///   `{ "uploadedAt": "<iso>", "transactions": [...], "budgets": [...] }`
/// 404 means "no backup yet" (never uploaded, or wiped on disconnect).
Future<Response> Function(Request) backupGetHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  required BackupStore store,
}) {
  final log = Logger('backup-get');

  return (Request req) async {
    await store.init();

    final authHeader = req.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response.forbidden('missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(authHeader.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) {
        return Response.forbidden('invalid token');
      }
      sub = s;
    } on FormatException catch (e) {
      return Response.forbidden('bad token: ${e.message}');
    }

    final snap = await store.get(sub);
    if (snap == null) {
      return Response(404,
          body: jsonEncode({'error': 'no backup for this user'}),
          headers: {'content-type': 'application/json'});
    }
    log.info('backup fetched: ${snap.transactions.length} txns, '
        '${snap.budgets.length} budgets for $sub');
    return Response.ok(
      jsonEncode({
        'uploadedAt': snap.uploadedAt.toUtc().toIso8601String(),
        'transactions': snap.transactions,
        'budgets': snap.budgets,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `POST /backup/remove` — deletes ONLY the user's GCS backup
/// snapshot. Leaves accounts/{sub}, filter_rules/{sub}, and the
/// Gmail-side filter untouched.
///
/// Distinct from `POST /account/delete` (which wipes everything):
/// this is the "delete backup but keep my account" path that the
/// mobile disconnect dialog uses when a user is signing out for
/// privacy reasons but plans to come back later from a fresh
/// install. After this, the user's account record is still alive,
/// push still works, the Gmail filter still mirrors their server-
/// side rules — but `GET /backup/current` returns 404 until they
/// upload again.
///
/// Idempotent: deleting an already-gone backup is a no-op so the
/// client can retry without coordination.
Future<Response> Function(Request) backupRemoveHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  required BackupStore store,
}) {
  final log = Logger('backup-remove');

  return (Request req) async {
    await store.init();

    final authHeader = req.headers['authorization'];
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

    log.info('backup remove requested by $sub');
    await store.remove(sub);
    return Response.ok(jsonEncode({'removed': true, 'sub': sub}),
        headers: {'content-type': 'application/json'});
  };
}

/// `POST /admin/trigger-backup-fcm` — sends a `type: backup_trigger`
/// FCM data message. With the per-user Cloud Scheduler model, the
/// `?sub=<googleSub>` query param scopes the fire to one user — the
/// per-user job URL includes this. The old broadcast behavior (no
/// `sub` param) is kept as a safety net during the deploy
/// migration window; the deploy script disables the shared
/// `pocket-backup-fanout` job after creating the per-user one, so
/// the broadcast path is effectively dead in production.
///
/// Auth: admin email gate — Cloud Scheduler
/// OIDC tokens skip the gate, mobile Bearer tokens must match
/// `config.adminEmail`.
///
/// When fired per-user, the trigger is sent only to that user's
/// FCM tokens (not iterated across all accounts). Each device that
/// receives the trigger runs `BackupService.upload()` and overwrites
/// its own `backups/{sub}` doc — last write wins, which is fine
/// because each device is the source of truth for its own data.
Future<Response> Function(Request) triggerBackupFcmHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth, {
  required FcmPublisher fcm,
}) {
  final log = Logger('trigger-backup-fcm');

  return (Request req) async {
    if (!config.adminEnabled) {
      return Response.forbidden('admin endpoint disabled');
    }
    // Two bearer shapes land here:
    //   - Cloud Scheduler OIDC: `Authorization: Bearer <RS256>`. The
    //     handler verifies signature + audience (the bare service
    //     URL — `--oidc-token-audience "$url"` in deploy.sh). No
    //     Pocket account is attached, so we can't gate on email.
    //   - Mobile Bearer apiToken (HS256). Gate on adminEmail.
    // Header inspection (`looksLikeOidc`) routes between the two —
    // trying `verifyApiToken` first on an OIDC token throws
    // FormatException and we'd 403 a legitimate scheduler hit.
    final bearer = req.headers['authorization'];
    if (bearer != null && bearer.startsWith('Bearer ')) {
      final token = bearer.substring(7);
      try {
        if (auth.looksLikeOidc(token)) {
          // pubsubAudience = serviceUrl + /pubsub/push; Cloud
          // Scheduler's aud is the bare URL (no suffix), so strip
          // the suffix before comparing.
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

    final targetSub = req.url.queryParameters['sub'];
    if (targetSub != null && targetSub.isNotEmpty) {
      // Per-user job fired: send the trigger to only that user's
      // registered FCM tokens. No `fcmTokens` check is done here —
      // we still publish, the publish call's own dead-token
      // handling is what cleans up the token set in the account
      // record.
      final record = await tokens.get(targetSub);
      if (record == null) {
        log.warning('trigger for unknown sub=$targetSub');
        return Response(404,
            body: jsonEncode({'error': 'unknown sub: $targetSub'}),
            headers: {'content-type': 'application/json'});
      }
      var sent = 0;
      var skipped = 0;
      if (record.fcmTokens.isEmpty) {
        skipped++;
      } else {
        try {
          await fcm.publishToTokens(
            sub: record.sub,
            tokens: record.fcmTokens,
            data: {'type': 'backup_trigger'},
          );
          sent++;
        } catch (e) {
          log.warning('backup-trigger publish for ${record.sub} failed: $e');
        }
      }
      log.info('backup_trigger (sub=$targetSub) sent=$sent skipped=$skipped');
      return Response.ok(
        jsonEncode({
          'sub': targetSub,
          'sent': sent,
          'skipped': skipped,
        }),
        headers: {'content-type': 'application/json'},
      );
    }

    // Broadcast path (safety net during the deploy-migration
    // window). Iterate every account and send the trigger to each
    // that has FCM tokens registered. New code should never reach
    // here — the shared `pocket-backup-fanout` job is disabled by
    // deploy.sh after the per-user job is created.
    final accounts = await tokens.all();
    var sent = 0;
    var skipped = 0;
    for (final record in accounts) {
      if (record.fcmTokens.isEmpty) {
        skipped++;
        continue;
      }
      try {
        await fcm.publishToTokens(
          sub: record.sub,
          tokens: record.fcmTokens,
          data: {'type': 'backup_trigger'},
        );
        sent++;
      } catch (e) {
        log.warning('backup-trigger publish for ${record.sub} failed: $e');
      }
    }
    log.info('backup_trigger dispatched (broadcast): sent=$sent skipped=$skipped');
    return Response.ok(
      jsonEncode({
        'sent': sent,
        'skipped': skipped,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

