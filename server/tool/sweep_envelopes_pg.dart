import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';

import 'package:pocket_server/accounts_repo.dart';

/// Wipes envelopes whose `ttl` has passed. Replaces the legacy
/// Firestore sweep (deleted with the GCP migration); the storage
/// backend is now Postgres on the VM.
///
/// Runs as a systemd oneshot unit (see `systemd/pocket-sweep.service`)
/// triggered every 6 hours by `systemd/pocket-sweep.timer`. Exits 0
/// on success, 1 on any failure — `Type=oneshot` reports the status
/// to journald either way.
///
/// Exit codes:
///   0 — sweep ran, deleted zero-or-more rows
///   1 — connection / query failed (visible in `journalctl -u pocket-sweep`)
///
/// All status is logged via the `sweep` Logger so journald captures it
/// without needing a file. `journalctl -u pocket-sweep --since today`
/// answers "did the sweep run today" and `journalctl -u pocket-sweep
/// -n 200` shows the last 200 lines for spot-checks.
Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    // Plain `print` so journald captures it as a single line per record
    // (Logger writes through stderr; that becomes journald's MESSAGE=).
    // ignore: avoid_print
    print('[${r.level.name}] [sweep] ${r.message}');
  });
  final log = Logger('sweep');

  final startedAt = DateTime.now().toUtc();
  log.info('start at ${startedAt.toIso8601String()}');

  try {
    final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
    final endpoint = pgEndpointFromEnv(dotenv: dotenv);
    final settings = ConnectionSettings(sslMode: SslMode.disable);
    final conn = await Connection.open(endpoint, settings: settings);
    try {
      final res = await conn.execute(
        'DELETE FROM envelopes WHERE ttl < NOW() RETURNING message_id',
      );
      final deleted = res.length;
      final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
      log.info('deleted $deleted row(s) in ${elapsedMs}ms');
      log.info('done ok');
    } finally {
      await conn.close();
    }
    exit(0);
  } catch (e, st) {
    log.severe('FAILED: $e');
    log.severe(st.toString());
    exit(1);
  }
}
