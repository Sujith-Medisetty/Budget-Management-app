import 'dart:async';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import 'package:pocket_server/accounts.dart';
import 'package:pocket_server/accounts_filter_rule_store.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/account_cleanup.dart';
import 'package:pocket_server/account_delete.dart';
import 'package:pocket_server/auth.dart';
import 'package:pocket_server/backup.dart';
import 'package:pocket_server/backup_scheduler.dart';
import 'package:pocket_server/backup_snapshot.dart';
import 'package:pocket_server/budgets.dart';
import 'package:pocket_server/budgets_repo.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/devices.dart';
import 'package:pocket_server/envelope_delete.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:pocket_server/fcm.dart';
import 'package:pocket_server/filters_status.dart';
import 'package:pocket_server/filters_sync.dart';
import 'package:pocket_server/firebase_custom_token.dart';
import 'package:pocket_server/firebase_token_endpoint.dart';
import 'package:pocket_server/gmail_fetch.dart';
import 'package:pocket_server/gmail_watch.dart';
import 'package:pocket_server/r2_backup_store.dart';
import 'package:pocket_server/mime.dart';
import 'package:pocket_server/oauth.dart';
import 'package:pocket_server/pubsub_handler.dart';
import 'package:pocket_server/sync.dart';

/// R2 is the only backup target — the user's transactions + budgets
/// live on the phone (source of truth) and the server-side copy lives
/// in R2 (the "object store"). Postgres holds only scheduling
/// metadata (prefs + last_backup_at + pocket_schedules row), never
/// the backup blob. Sign-out and `/backup/remove` both call
/// `BackupStore.remove(sub)` so the R2 object is deleted in lockstep
/// with the local copy going away on the phone.
///
/// Fail-fast on missing R2_* env: a silent local-disk fallback used to
/// live here, but it masked deploys where the R2 creds got dropped
/// from `.env`. Now the server refuses to start unless all four R2_*
/// vars are present — better to fail at boot than to write backups
/// somewhere the operator isn't watching.
///
/// R2 env vars (all four required):
///   `R2_ENDPOINT`          e.g. https://&lt;account&gt;.r2.cloudflarestorage.com
///   `R2_BUCKET`            e.g. pocket-backups
///   `R2_ACCESS_KEY_ID`     32-char hex
///   `R2_SECRET_ACCESS_KEY` long mixed string
BackupStore _pickBackupStore(DotEnv dotenv) {
  final log = Logger('boot');
  final endpoint = dotenv['R2_ENDPOINT'];
  final bucket = dotenv['R2_BUCKET'];
  final accessKey = dotenv['R2_ACCESS_KEY_ID'];
  final secretKey = dotenv['R2_SECRET_ACCESS_KEY'];
  final missing = <String>[];
  if (endpoint == null || endpoint.isEmpty) missing.add('R2_ENDPOINT');
  if (bucket == null || bucket.isEmpty) missing.add('R2_BUCKET');
  if (accessKey == null || accessKey.isEmpty) missing.add('R2_ACCESS_KEY_ID');
  if (secretKey == null || secretKey.isEmpty) missing.add('R2_SECRET_ACCESS_KEY');
  if (missing.isNotEmpty) {
    throw StateError(
      'backup store: R2 creds missing (${missing.join(', ')}) — '
      'server refuses to start. R2 is the only supported backup target; '
      'add the four R2_* vars to /opt/pocket/server/.env and restart.',
    );
  }
  log.info('backup store: R2 (bucket=$bucket)');
  return R2BackupStore(
    endpoint: endpoint!,
    bucket: bucket!,
    accessKeyId: accessKey!,
    secretAccessKey: secretKey!,
  );
}

Future<void> main(List<String> args) async {
  // Catch uncaught async errors that would otherwise kill the
  // isolate and trigger a Cloud Run cold start. Same rationale the
  // Cloud Run version had; on the VM this lets systemd Restart=always
  // survive a single pathological request instead of dropping the
  // process.
  await runZonedGuarded(() async {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen(
      (r) => stdout.writeln('[${r.level.name}] ${r.message}'),
    );
    final log = Logger('pocket_server');

    final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
    stdout.writeln('loaded .env');

    final config = loadConfig(dotenv);

    final cipher = TokenCipher(config.tokenEncryptionKey);

    // One Postgres pool powers the account repo + envelope store +
    // (later) any other query handler. Connection opens lazily on the
    // first request if init() isn't called here, but doing it at boot
    // surfaces "wrong password" early instead of as the first 503.
    final tokenStore = AccountsRepo(endpoint: pgEndpointFromEnv(dotenv: dotenv));
    await tokenStore.init();
    final envelopeStore = PostgresEnvelopeStore(repo: tokenStore);
    await envelopeStore.init();
    final ruleStore = AccountsFilterRuleStore(tokens: tokenStore);
    await ruleStore.init();
    final budgetsRepo = BudgetsRepo(accounts: tokenStore);
    final backupStore = _pickBackupStore(dotenv);
    await backupStore.init();

    final tokenAuth = TokenAuth(apiTokenSecret: config.apiTokenSecret);
    const mime = MimeExtractor();
    final fetcher = GmailFetcher(config);
    // Per-user systemd-timer manager. The accounts repo is passed
    // (not the TokenStore interface) so the scheduler can read/write
    // the pocket_schedules row directly. PATCH /accounts/<sub> and
    // account cleanup both call into this; nothing else needs it.
    final backupScheduler = BackupScheduler(accounts: tokenStore);
    final fcm = FcmPublisher(
      config: config,
      // Same callback the Cloud Run version had. On uninstall FCM
      // hands us an UNREGISTERED code; we drop the token from the
      // account row, and if the FCM set empties we wipe the whole
      // account (Gmail filter + accounts/{sub} + the per-user watch
      // re-registration on next sign-in) so nothing outlives the
      // uninstall.
      onTokenUnregistered: (sub, token) async {
        final record = await tokenStore.get(sub);
        if (record == null) return;
        final remaining = {...record.fcmTokens}..remove(token);
        if (remaining.length == record.fcmTokens.length) {
          // Already gone (race between signout and a queued publish).
          return;
        }
        await tokenStore.put(
          sub,
          record.copyWith(fcmTokens: remaining),
        );
        if (remaining.isEmpty) {
          await deleteAccountCompletely(
            config: config,
            tokens: tokenStore,
            cipher: cipher,
            rules: ruleStore,
            backups: backupStore,
            backupScheduler: backupScheduler,
            sub: sub,
            reason: 'fcm-token-unregistered-and-set-emptied',
          );
        }
      },
    );
    await fcm.init();
    final watch = GmailWatchRegistrar(config: config, tokens: tokenStore);
    final FirebaseCustomTokenMinter? firebaseMinter;
    final saPath = config.fcmServiceAccountJsonPath;
    if (saPath != null) {
      firebaseMinter = FirebaseCustomTokenMinter(saPath);
    } else {
      firebaseMinter = null;
    }

    final router = Router()
      ..get('/health', (_) => Response.ok('ok'))
      ..post('/oauth/exchange',
          oauthExchange(config, tokenStore, cipher, tokenAuth, watch,
              firebaseMinter: firebaseMinter))
      ..post('/oauth/signout',
          oauthSignout(config, tokenStore))
      ..post('/auth/firebase-token',
          firebaseTokenHandler(tokenAuth, firebaseMinter))
      ..post('/devices/register',
          devicesRegister(tokenStore, tokenAuth))
      ..post('/devices/signout',
          devicesSignout(tokenStore, tokenAuth))
      ..delete('/envelope',
          envelopeDeleteHandler(tokenAuth, envelopeStore))
      ..get('/sync', syncSince(config, tokenStore, tokenAuth, envelopeStore))
      ..post('/filters/sync',
          filtersSyncHandler(config, tokenStore, cipher, tokenAuth))
      ..get('/filters/status',
          filtersStatusHandler(config, tokenStore, cipher, tokenAuth))
      ..post('/backup/upload',
          backupUploadHandler(config, tokenStore, tokenAuth, store: backupStore))
      ..get('/backup/current',
          backupGetHandler(config, tokenStore, tokenAuth, store: backupStore))
      ..post('/backup/remove',
          backupRemoveHandler(config, tokenStore, tokenAuth, store: backupStore))
      ..post('/account/delete',
          accountDeleteHandler(config, tokenStore, cipher, tokenAuth, ruleStore, backupStore,
              backupScheduler: backupScheduler))
      ..get('/accounts/<sub>',
          accountsGetHandler(config, tokenStore, tokenAuth))
      ..patch('/accounts/<sub>',
          accountsPatchHandler(config, tokenStore, tokenAuth, backupScheduler, budgetsRepo))
      ..post('/admin/trigger-backup-fcm',
          triggerBackupFcmHandler(config, tokenStore, tokenAuth, fcm: fcm))
      ..get('/budgets',
          budgetsListHandler(tokenStore, tokenAuth, budgetsRepo))
      ..get('/budgets/ensure-current',
          budgetsEnsureCurrentHandler(tokenStore, tokenAuth, budgetsRepo))
      ..patch('/budgets/match',
          budgetsPatchMatchHandler(tokenStore, tokenAuth, budgetsRepo))
      ..post('/pubsub/push',
          pubsubHandler(config, tokenStore, mime, tokenAuth, cipher, fcm, fetcher, envelopeStore));

    final handler = Pipeline()
        .addMiddleware(logRequests())
        .addHandler(router.call);

    final port = int.parse(Platform.environment['PORT'] ?? '8080');
    final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
    log.info('listening on http://${server.address.host}:${server.port}');

    ProcessSignal.sigterm.watch().listen((_) async {
      log.info('SIGTERM received, closing...');
      await server.close(force: false);
      await tokenStore.close();
      exit(0);
    });
    ProcessSignal.sigint.watch().listen((_) async {
      await server.close(force: false);
      await tokenStore.close();
      exit(0);
    });
  }, (error, stack) {
    stderr.writeln('[zoned] $error');
    stderr.writeln(stack);
  });
}
