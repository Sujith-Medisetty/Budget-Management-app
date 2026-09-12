import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';

import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/fcm.dart';

/// Sends a `type: backup_trigger` FCM to one user's registered devices.
///
/// Invoked by the per-user systemd service unit
/// `pocket-backup-{sub}.service` when its matching timer fires. The
/// mobile client receives the FCM and runs its local backup → R2
/// upload flow; the server's only job here is the FCM ping.
///
/// The CLI bypasses the HTTP layer on purpose: it's invoked from
/// systemd on the same VM that runs `pocket-server`, but it should
/// not depend on that server being up (a deploy restart shouldn't
/// drop scheduled backups). Going direct to FCM + Postgres also
/// keeps the admin gate's `adminEmail` requirement out of this
/// path — the per-user timer is per-user, no admin needed.
///
/// Exit codes:
///   0 — published (or zero fcm tokens, which is treated as success —
///       the timer firing for an uninstalled device is expected).
///   2 — sub arg missing or wrong shape.
///   3 — Postgres / config load failed (visible in journald).
///
/// Args:
///   --sub `googleSub`   required, the user's Google sub
///
/// `.env` is loaded from CWD (the unit sets
/// `WorkingDirectory=/opt/pocket/server`), so the same env the server
/// uses is in scope.
Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    // Plain `print` so journald captures it as a single line per record
    // (matches the `sweep` tool's logging style).
    // ignore: avoid_print
    print('[${r.level.name}] [trigger-backup] ${r.message}');
  });
  final log = Logger('trigger-backup');

  final sub = _parseSub(args);
  if (sub == null) {
    log.severe('--sub <googleSub> required');
    exit(2);
  }
  log.info('start (sub=$sub)');

  try {
    final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
    final config = loadConfig(dotenv);
    final repo = AccountsRepo(endpoint: pgEndpointFromEnv(dotenv: dotenv));
    await repo.init();
    final record = await repo.get(sub);
    if (record == null) {
      // Account was deleted between the timer being scheduled and
      // firing. BackupScheduler.disableForDeletedSub is supposed to
      // keep the unit in lock-step, but this can happen if the
      // disable raced the next fire. Treat as success — nothing to
      // do — and don't tear the timer down here (the scheduler
      // already did, or will, on its next sync).
      log.warning('no account for sub=$sub — nothing to trigger');
      await repo.close();
      exit(0);
    }
    if (record.fcmTokens.isEmpty) {
      log.info('sub=$sub has no FCM tokens registered — skipping publish '
          '(device uninstalled?)');
      await repo.close();
      exit(0);
    }

    final fcm = FcmPublisher(config: config);
    await fcm.init();
    await fcm.publishToTokens(
      sub: record.sub,
      tokens: record.fcmTokens,
      data: {'type': 'backup_trigger'},
    );
    await repo.close();
    log.info('done (sub=$sub, tokens=${record.fcmTokens.length})');
  } catch (e, st) {
    log.severe('failed (sub=$sub): $e');
    log.severe(st.toString());
    exit(3);
  }
}

String? _parseSub(List<String> args) {
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--sub') return args[i + 1];
  }
  return null;
}
