// One-shot: delete the stale Firestore account record for
// medisujith@gmail.com. The record was sealed under an old
// TOKEN_ENCRYPTION_KEY; the running revision uses a different key,
// so every Pub/Sub push throws SecretBoxAuthenticationError on
// decrypt. Deleting the record makes Pub/Sub's "no account found"
// branch return 200 OK, and the next /oauth/callback will re-create
// it under the current key.
//
// Run from server/ with:
//   dart run --define-from-file=.env tool/delete_account.dart medisujith@gmail.com

import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';


Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/delete_account.dart <email>');
    exit(1);
  }
  final email = args.first;

  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);
  final store = AccountsRepo(endpoint: pgEndpointFromEnv());
  await store.init();

  final record = await store.findByEmail(email);
  if (record == null) {
    stderr.writeln('no account found for $email — nothing to delete');
    exit(1);
  }
  stderr.writeln('found account: sub=${record.sub} email=$email');
  await store.remove(record.sub);
  stderr.writeln('deleted accounts/${record.sub}');
}
