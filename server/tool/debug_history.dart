// Debug tool: trade refresh_token for access_token, then list Gmail
// history directly to see what the API actually returns. Used to
// diagnose the 404 on users.history.list.

import 'dart:convert';

import 'package:dio/dio.dart' hide Response;
import 'package:dotenv/dotenv.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/accounts_repo.dart' show AccountsRepo, pgEndpointFromEnv;
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';


Future<void> main() async {
  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final config = loadConfig(dotenv);
  final cipher = TokenCipher(config.tokenEncryptionKey);
  final store = AccountsRepo(endpoint: pgEndpointFromEnv());
  await store.init();

  final records = await store.all();
  final real = records.firstWhere(
    (r) => !r.email.contains('test'),
    orElse: () => throw StateError('no real account'),
  );
  print('account: ${real.email} sub=${real.sub}');
  print('stored: lastHistoryId=${real.lastHistoryId} lastWatchAt=${real.lastWatchAt}');

  final plain = await cipher.open(real.refreshToken);

  // Trade refresh_token for access_token.
  final tokenRes = await Dio().post<Map<String, dynamic>>(
    'https://oauth2.googleapis.com/token',
    data: {
      'client_id': config.webClientId,
      'client_secret': config.webClientSecret,
      'refresh_token': plain,
      'grant_type': 'refresh_token',
    },
    options: Options(
      contentType: Headers.formUrlEncodedContentType,
      responseType: ResponseType.json,
    ),
  );
  final at = tokenRes.data!['access_token'] as String;
  print('minted access_token (len=${at.length})');

  // Try history.list with various startHistoryIds to see what works.
  for (final id in [
    if (real.lastHistoryId != null) real.lastHistoryId!,
    '1',
  ]) {
    print('\n[history.list startHistoryId=$id]');
    final res = await Dio().get<Map<String, dynamic>>(
      'https://gmail.googleapis.com/gmail/v1/users/me/history',
      queryParameters: {
        'startHistoryId': id,
        'historyTypes': 'messageAdded',
        'maxResults': 5,
      },
      options: Options(
        headers: {'authorization': 'Bearer $at'},
        responseType: ResponseType.json,
      ),
    );
    print('  status: ${res.statusCode}');
    if (res.statusCode == 200) {
      final body = res.data!;
      print('  historyId: ${body['historyId']}');
      print('  count: ${(body['history'] as List?)?.length ?? 0}');
    } else {
      print('  body: ${jsonEncode(res.data)}');
    }
  }
}