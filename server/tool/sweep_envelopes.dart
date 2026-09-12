import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:googleapis_auth/auth_io.dart';

/// Wipes ALL envelopes. The 24h Firestore TTL is the new safety net
/// and the mobile app is being updated to call DELETE /envelope after
/// consumption — so leftover docs are just dead weight.
Future<void> main(List<String> args) async {
  final confirm = args.contains('--confirm');
  if (!confirm) {
    print('DRY RUN — pass --confirm to actually delete');
  }
  final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
  final project = dotenv['GCP_PROJECT']!;
  final saPath = dotenv['FCM_SERVICE_ACCOUNT_JSON']!;
  final json = jsonDecode(await File(saPath).readAsString()) as Map<String, dynamic>;
  final creds = ServiceAccountCredentials.fromJson(json);
  final client = await clientViaServiceAccount(creds, ['https://www.googleapis.com/auth/datastore']);

  var pageToken = '';
  var ids = <String>[];
  do {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/envelopes?pageSize=300${pageToken.isNotEmpty ? '&pageToken=$pageToken' : ''}');
    final res = await client.get(url);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    for (final d in (body['documents'] as List).cast<Map<String, dynamic>>()) {
      ids.add((d['name'] as String).split('/').last);
    }
    pageToken = (body['nextPageToken'] as String?) ?? '';
  } while (pageToken.isNotEmpty);

  print('found ${ids.length} envelope(s)');
  if (!confirm) {
    print('would delete all of them. re-run with --confirm.');
    client.close();
    return;
  }
  var deleted = 0;
  for (final id in ids) {
    final r = await client.delete(Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/envelopes/$id'));
    if (r.statusCode == 200 || r.statusCode == 404) {
      deleted++;
    } else {
      print('FAIL $id: ${r.statusCode}');
    }
  }
  print('deleted $deleted envelope(s)');
  client.close();
}
