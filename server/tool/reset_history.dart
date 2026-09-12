// Reset lastHistoryId for every non-test account so the next Pub/Sub
// push re-publishes all messages since the new watermark. Used to
// recover from a "stored historyId is past all messages" state where
// the server finds 0 new messages on every push.

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';


Future<void> main(List<String> args) async {
  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);
  final store = AccountsRepo(endpoint: pgEndpointFromEnv());
  await store.init();

  const newHistoryId = '4550703';
  final accounts = await store.all();
  for (final r in accounts) {
    if (r.email.contains('test')) continue;
    print('resetting ${r.email} lastHistoryId: '
        '${r.lastHistoryId} -> $newHistoryId');
    await store.put(r.sub, r.copyWith(lastHistoryId: newHistoryId));
  }
  print('done');
  exit(0);
}