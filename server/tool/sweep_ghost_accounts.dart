import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:googleapis_auth/auth_io.dart';

/// One-time Firestore cleanup: deletes accounts/filter_rules/envelopes
/// for any account that's not the real medisujith user. Run with
/// --confirm to actually delete (default = dry run).
///
/// Why a script and not server code: this is a one-time operation
/// against 9 dev/test account docs and ~240 loadtest envelope docs.
/// The server has no "list + delete by prefix" endpoint and adding
/// one for this single use is overkill.

const realSub = '107602711769738620458';
const realEmail = 'medisujith@gmail.com';

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

  var deleted = 0;

  // 1. Accounts: keep the real medisujith sub, delete everything else.
  final accRes = await client.get(Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/accounts?pageSize=300'));
  final accBody = jsonDecode(accRes.body) as Map<String, dynamic>;
  for (final d in (accBody['documents'] as List).cast<Map<String, dynamic>>()) {
    final id = (d['name'] as String).split('/').last;
    if (id == realSub) {
      print('KEEP account $id ($realEmail)');
      continue;
    }
    final email = ((d['fields'] as Map?)?['email'] as Map?)?['stringValue'] as String? ?? '<no email>';
    if (confirm) {
      final r = await client.delete(Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/accounts/$id'));
      if (r.statusCode == 200 || r.statusCode == 404) {
        print('DEL  account $id ($email)');
        deleted++;
      } else {
        print('FAIL account $id: ${r.statusCode}');
      }
    } else {
      print('WOULD DEL account $id ($email)');
      deleted++;
    }
  }

  // 2. filter_rules: keep the medisujith sub's doc, delete the rest.
  final ruleRes = await client.get(Uri.parse(
      'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/filter_rules?pageSize=300'));
  final ruleBody = jsonDecode(ruleRes.body) as Map<String, dynamic>;
  for (final d in (ruleBody['documents'] as List).cast<Map<String, dynamic>>()) {
    final id = (d['name'] as String).split('/').last;
    if (id == realSub) {
      print('KEEP filter_rules $id');
      continue;
    }
    if (confirm) {
      final r = await client.delete(Uri.parse(
          'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/filter_rules/$id'));
      if (r.statusCode == 200 || r.statusCode == 404) {
        print('DEL  filter_rules $id');
        deleted++;
      } else {
        print('FAIL filter_rules $id: ${r.statusCode}');
      }
    } else {
      print('WOULD DEL filter_rules $id');
      deleted++;
    }
  }

  // 3. Envelopes: delete all loadtest envelopes. The 24h Firestore
  // TTL is the safety net from here on — we'd have no envelope
  // data after today either way. Only delete if from a loadtest
  // sender (merchant.com, bigbank.com, the test@ examples).
  var pageToken = '';
  do {
    final url = Uri.parse(
        'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/envelopes?pageSize=300${pageToken.isNotEmpty ? '&pageToken=$pageToken' : ''}');
    final res = await client.get(url);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    for (final d in (body['documents'] as List).cast<Map<String, dynamic>>()) {
      final id = (d['name'] as String).split('/').last;
      final fields = (d['fields'] as Map?)?.cast<String, dynamic>() ?? {};
      final from = (fields['from'] as Map?)?['stringValue'] as String? ?? '';
      // Real envelopes come from real banks (chase, wellsfargo, paypal,
      // amazon, etc.) or service notifications. merchant.com and
      // bigbank.com are the loadtest senders.
      final isLoadtest = from.contains('merchant.com') || from.contains('bigbank.com');
      if (!isLoadtest) continue;
      if (confirm) {
        final r = await client.delete(Uri.parse(
            'https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/envelopes/$id'));
        if (r.statusCode == 200 || r.statusCode == 404) {
          deleted++;
        } else {
          print('FAIL envelope $id: ${r.statusCode}');
        }
      } else {
        deleted++;
      }
    }
    pageToken = (body['nextPageToken'] as String?) ?? '';
  } while (pageToken.isNotEmpty);

  print('---');
  print('${confirm ? "DELETED" : "WOULD DELETE"}: $deleted doc(s)');
  client.close();
}
