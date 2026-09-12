// One-shot recovery: re-run users.watch() for every account in
// Firestore that doesn't yet have a `lastHistoryId`. Used when the
// Pub/Sub topic IAM was missing and the original OAuth-time watch
// silently failed.
//
// Run from the server/ directory with:
//   dart run --define-from-file=.env tool/recover_watch.dart
//
// Make sure GMAIL_TEST_MODE / OAUTH_TEST_MODE / FCM_DRY_RUN are
// unset or 0 — this tool hits real Google APIs.

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';

import 'package:pocket_server/gmail_watch.dart';

Future<void> main(List<String> args) async {
  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);
  if (config.gmailTestMode || config.oauthTestMode) {
    stderr.writeln('refusing to run with *_TEST_MODE=1 — those bypass '
        'Google APIs. Unset them in .env and re-run.');
    exit(1);
  }
  final cipher = TokenCipher(config.tokenEncryptionKey);
  final store = AccountsRepo(endpoint: pgEndpointFromEnv());
  await store.init();
  final watch = GmailWatchRegistrar(config: config, tokens: store);

  final accounts = await store.all();
  if (accounts.isEmpty) {
    print('no accounts in Firestore — nothing to recover.');
    return;
  }

  print('found ${accounts.length} account(s)');
  for (final record in accounts) {
    print('\n[${record.email}] sub=${record.sub} '
        'lastHistoryId=${record.lastHistoryId ?? '<null>'} '
        'revoked=${record.revoked}');
    if (record.revoked) {
      print('  → skipped (revoked)');
      continue;
    }
    try {
      final plain = await cipher.open(record.refreshToken);
      await watch.refresh(record.sub, plain);
      print('  ✓ users.watch refreshed');
    } catch (e) {
      print('  ✗ failed: $e');
    }
  }
}