import 'dart:convert';

import 'package:pocket_server/auth.dart';
import 'package:pocket_server/backup.dart';
import 'package:pocket_server/backup_snapshot.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/token_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeBackupStore implements BackupStore {
  Map<String, BackupSnapshot> docs = {};
  int putCalls = 0;
  int removeCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> put(
    String sub, {
    required List<Map<String, Object?>> transactions,
    required List<Map<String, Object?>> budgets,
  }) async {
    putCalls++;
    docs[sub] = BackupSnapshot(
      uploadedAt: DateTime.now().toUtc(),
      transactions: transactions,
      budgets: budgets,
    );
  }

  @override
  Future<BackupSnapshot?> get(String sub) async => docs[sub];

  @override
  Future<void> remove(String sub) async {
    removeCalls++;
    docs.remove(sub);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTokenStore implements TokenStore {
  _FakeTokenStore(this.record);
  AccountRecord? record;
  final List<AccountRecord> allReturned = [];

  @override
  Future<AccountRecord?> get(String sub) async => record?.sub == sub ? record : null;

  @override
  Future<List<AccountRecord>> all() async {
    allReturned.addAll([?record]);
    return allReturned;
  }

  @override
  Future<void> put(String sub, AccountRecord r) async => record = r;
  @override
  Future<void> remove(String sub) async => record = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ServerConfig _config() => const ServerConfig(
      gcpProject: 'pocket-mail-sync',
      pubsubTopic: 'projects/pocket-mail-sync/topics/t',
      pubsubAudience: 'https://pocket-server.example.run.app',
      fcmProjectId: 'pocket-mail-sync',
      fcmServiceAccountJsonPath: null,
      fcmDryRun: true,
      gmailTestMode: true,
      oauthTestMode: true,
      adminEmail: 'test@example.com',
      apiTokenSecret: 'test-secret',
      webClientId: 'wc',
      webClientSecret: 'wcs',
      tokenEncryptionKey: '0123456789012345',
    );

TokenAuth _auth() => TokenAuth(apiTokenSecret: 'test-secret');

String _bearer(String sub) {
  final token = _auth().signApiToken(
    sub: sub,
    ttl: const Duration(minutes: 5),
  );
  return 'Bearer $token';
}

Request _request({String method = 'POST', String? bearer, String? body}) {
  final headers = {'content-type': 'application/json'};
  if (bearer != null) headers['authorization'] = bearer;
  return Request(
    method,
    Uri.parse('http://localhost/'),
    headers: headers,
    body: body,
  );
}

void main() {
  group('backup upload', () {
    test('stores transactions + budgets under sub', () async {
      final store = _FakeBackupStore();
      final tokens = _FakeTokenStore(null);
      final handler = backupUploadHandler(_config(), tokens, _auth(),
          store: store);

      final body = jsonEncode({
        'transactions': [
          {
            'id': 1,
            'notification_key': 'gmail:abc',
            'source': 'gmail',
            'amount': 12.50,
            'merchant': 'PAYPAL',
            'occurred_at': 1725000000000,
            'ignored': 0,
          },
        ],
        'budgets': [
          {
            'id': 1,
            'name': 'Sep',
            'amount': 500,
            'period': 'monthly',
            'start_date': '2026-09-01',
            'end_date': '2026-09-30',
            'active': 1,
            'created_at': 1725000000000,
          },
        ],
      });

      final res = await handler(_request(
        bearer: _bearer('sub-1'),
        body: body,
      ));

      expect(res.statusCode, 200);
      expect(store.putCalls, 1);
      final snap = store.docs['sub-1']!;
      expect(snap.transactions, hasLength(1));
      expect(snap.transactions.first['merchant'], 'PAYPAL');
      expect(snap.budgets, hasLength(1));
      expect(snap.budgets.first['name'], 'Sep');
    });

    test('rejects when missing bearer', () async {
      final store = _FakeBackupStore();
      final tokens = _FakeTokenStore(null);
      final handler = backupUploadHandler(_config(), tokens, _auth(),
          store: store);

      final res = await handler(_request(body: '{}'));
      expect(res.statusCode, 403);
      expect(store.putCalls, 0);
    });

    test('rejects non-object rows', () async {
      final store = _FakeBackupStore();
      final tokens = _FakeTokenStore(null);
      final handler = backupUploadHandler(_config(), tokens, _auth(),
          store: store);

      final res = await handler(_request(
        bearer: _bearer('sub-1'),
        body: jsonEncode({'transactions': ['not-a-map'], 'budgets': []}),
      ));
      expect(res.statusCode, 400);
      expect(store.putCalls, 0);
    });
  });

  group('backup get', () {
    test('returns 404 when no backup exists', () async {
      final store = _FakeBackupStore();
      final tokens = _FakeTokenStore(null);
      final handler = backupGetHandler(_config(), tokens, _auth(),
          store: store);

      final res = await handler(Request(
        'GET',
        Uri.parse('http://localhost/'),
        headers: {'authorization': _bearer('sub-x')},
      ));
      expect(res.statusCode, 404);
    });

    test('returns stored snapshot with uploadedAt', () async {
      final store = _FakeBackupStore();
      final tokens = _FakeTokenStore(null);
      store.docs['sub-1'] = BackupSnapshot(
        uploadedAt: DateTime.utc(2026, 9, 7, 12, 0),
        transactions: [
          {'id': 1, 'amount': 5.0},
        ],
        budgets: [],
      );
      final handler = backupGetHandler(_config(), tokens, _auth(),
          store: store);

      final res = await handler(Request(
        'GET',
        Uri.parse('http://localhost/'),
        headers: {'authorization': _bearer('sub-1')},
      ));
      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['uploadedAt'], '2026-09-07T12:00:00.000Z');
      expect(body['transactions'], hasLength(1));
    });
  });
}
