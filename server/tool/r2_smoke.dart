// Smoke-test for R2BackupStore. PUT a tiny blob, GET it back, DELETE
// it. Standalone — uses the env vars already on the VM. Run with:
//
//   cd /opt/pocket/server
//   dart --disable-analytics run tool/r2_smoke.dart
//
// Exits 0 on success, 1 on any failure.
import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';

import 'package:pocket_server/r2_backup_store.dart';

Future<void> main() async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen(
    (r) => print('[${r.level.name}] ${r.message}'),
  );

  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final endpoint = dotenv['R2_ENDPOINT'];
  final bucket = dotenv['R2_BUCKET'];
  final accessKey = dotenv['R2_ACCESS_KEY_ID'];
  final secretKey = dotenv['R2_SECRET_ACCESS_KEY'];
  if (endpoint == null || bucket == null || accessKey == null || secretKey == null) {
    print('FAIL: missing R2_* env vars');
    return;
  }

  final store = R2BackupStore(
    endpoint: endpoint,
    bucket: bucket,
    accessKeyId: accessKey,
    secretAccessKey: secretKey,
  );
  await store.init();

  // Use a unique sub so we don't clobber a real backup.
  const testSub = 'smoke-test-r2-001';
  print('→ PUT  ${store.bucket}/$testSub.json.gz');
  await store.put(
    testSub,
    transactions: [
      {'id': 1, 'merchant': 'Test Cafe', 'amount': 4.25, 'note': 'smoke'},
    ],
    budgets: [
      {'id': 1, 'name': 'Smoke Budget', 'amount': 100.0},
    ],
  );

  print('→ GET');
  final snapshot = await store.get(testSub);
  if (snapshot == null) {
    print('FAIL: GET returned null');
    return;
  }
  if (snapshot.transactions.length != 1 ||
      snapshot.transactions.first['merchant'] != 'Test Cafe') {
    print('FAIL: GET roundtrip mismatch');
    return;
  }
  print('  uploadedAt=${snapshot.uploadedAt.toIso8601String()}');
  print('  transactions=${snapshot.transactions.length}');
  print('  budgets=${snapshot.budgets.length}');

  print('→ DELETE');
  await store.remove(testSub);

  print('→ GET (after delete, expect null)');
  final afterDelete = await store.get(testSub);
  if (afterDelete != null) {
    print('FAIL: GET after DELETE returned non-null');
    return;
  }

  print('OK — R2 roundtrip works.');
}