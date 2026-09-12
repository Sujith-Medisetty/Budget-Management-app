// One-shot: verify what filter rules the app set are mirrored to Gmail.
// Compares server-side (Firestore) vs Gmail-side (filters API).
//
// Run from server/ with:
//   dart run --define-from-file=.env tool/list_gmail_filters.dart medisujith@gmail.com

import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/accounts_filter_rule_store.dart';


Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/list_gmail_filters.dart <email>');
    exit(1);
  }
  final email = args.first;

  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);
  final cipher = TokenCipher(config.tokenEncryptionKey);

  final tokens = AccountsRepo(endpoint: pgEndpointFromEnv());
  await tokens.init();
  final rules = AccountsFilterRuleStore(tokens: tokens);
  await rules.init();

  final record = await tokens.findByEmail(email);
  if (record == null) {
    stderr.writeln('no account for $email');
    exit(1);
  }
  stderr.writeln('account: sub=${record.sub}');

  // Server-side rules (what the app pushed).
  final serverSet = await rules.get(record.sub);
  stderr.writeln('--- server-side rules (Firestore) ---');
  if (serverSet == null) {
    stderr.writeln('  (none)');
  } else {
    stderr.writeln('  enabled=${serverSet.enabled} '
        'logic=${serverSet.logic.name} count=${serverSet.rules.length}');
    for (final r in serverSet.rules) {
      stderr.writeln('    id=${r.id} sender=${r.sender} subject=${r.subject} '
          'body=${r.body}');
    }
  }

  // Mint an access token from the stored refresh token.
  final refreshPlain = await cipher.open(record.refreshToken);
  stderr.writeln('--- minted access token (length=${refreshPlain.length} chars) ---');
  final tok = await http.post(Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': config.webClientId,
        'client_secret': config.webClientSecret,
        'refresh_token': refreshPlain,
        'grant_type': 'refresh_token',
      });
  stderr.writeln('OAuth response: ${tok.statusCode} body=${tok.body}');
  if (tok.statusCode != 200) {
    stderr.writeln('refresh-token exchange failed');
    exit(1);
  }
  final accessToken = jsonDecode(tok.body)['access_token'] as String;
  stderr.writeln('access_token length: ${accessToken.length}');

  // List Gmail-side filters.
  final list = await http.get(
    Uri.parse('https://gmail.googleapis.com/gmail/v1/users/me/settings/filters'),
    headers: {'authorization': 'Bearer $accessToken'},
  );
  stderr.writeln('Gmail filters API: ${list.statusCode} bodyLen=${list.body.length}');
  stderr.writeln('  body preview: ${list.body.substring(0, list.body.length.clamp(0, 400))}');
  if (list.statusCode != 200) {
    stderr.writeln('gmail filters list failed: ${list.body}');
    exit(1);
  }
  final body = jsonDecode(list.body) as Map<String, dynamic>;
  final filters = ((body['filter'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  stderr.writeln('--- gmail-side filters (${filters.length}) ---');
  for (final f in filters) {
    final c = (f['criteria'] as Map?) ?? const {};
    final a = (f['action'] as Map?) ?? const {};
    stderr.writeln('  id=${f['id']}');
    stderr.writeln('    criteria: ${c.entries.map((e) => "${e.key}=${e.value}").join(', ')}');
    stderr.writeln('    action:   ${a.entries.map((e) => "${e.key}=${e.value}").join(', ')}');
  }
}
