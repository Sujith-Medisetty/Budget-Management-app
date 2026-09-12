import 'dart:convert';

import 'package:pocket_server/auth.dart';
import 'package:pocket_server/backup.dart';
import 'package:pocket_server/backup_snapshot.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/token_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _FakeBackupStore implements BackupStore {
  final Map<String, BackupSnapshot> docs = {};
  int removeCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> put(
    String sub, {
    required List<Map<String, Object?>> transactions,
    required List<Map<String, Object?>> budgets,
  }) async {
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
  Map<String, AccountRecord> records = {};
  int removeCalls = 0;

  @override
  Future<AccountRecord?> get(String sub) async => records[sub];

  @override
  Future<List<AccountRecord>> all() async => records.values.toList();

  @override
  Future<void> put(String sub, AccountRecord r) async => records[sub] = r;

  @override
  Future<void> remove(String sub) async {
    removeCalls++;
    records.remove(sub);
  }

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
      gcsBackupBucket: 'test-bucket',
    );

TokenAuth _auth() => TokenAuth(apiTokenSecret: 'test-secret');

String _bearer(String sub) {
  final token = _auth().signApiToken(
    sub: sub,
    ttl: const Duration(minutes: 5),
  );
  return 'Bearer $token';
}

Request _request({String? bearer}) {
  final headers = {'content-type': 'application/json'};
  if (bearer != null) headers['authorization'] = bearer;
  return Request(
    'POST',
    Uri.parse('http://localhost/backup/remove'),
    headers: headers,
  );
}

void main() {
  group('backup/remove', () {
    test('rejects when missing bearer', () async {
      final h = backupRemoveHandler(
        _config(),
        _FakeTokenStore(),
        _auth(),
        store: _FakeBackupStore(),
      );
      final res = await h(_request());
      expect(res.statusCode, 403);
    });

    test('removes the backup only — account record stays put', () async {
      // This is the load-bearing assertion: it has to be ONLY the
      // backup that goes. The whole point of /backup/remove is to
      // preserve the account record so the user can sign back in.
      final tokens = _FakeTokenStore()
        ..records['sub-1'] = AccountRecord(
          sub: 'sub-1',
          email: 'me@example.com',
          refreshToken: 'enc:blob',
          lastWatchAt: DateTime.utc(2026, 9, 1),
          lastHistoryId: 'hist-1',
        );
      final backups = _FakeBackupStore()
        ..docs['sub-1'] = BackupSnapshot(
          uploadedAt: DateTime.utc(2026, 9, 7),
          transactions: const [{'id': 1}],
          budgets: const [],
        );

      final res = await backupRemoveHandler(
        _config(),
        tokens,
        _auth(),
        store: backups,
      )(_request(bearer: _bearer('sub-1')));

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['removed'], true);
      expect(body['sub'], 'sub-1');

      expect(backups.docs.containsKey('sub-1'), isFalse,
          reason: 'backup should be gone');
      expect(backups.removeCalls, 1);
      expect(tokens.records.containsKey('sub-1'), isTrue,
          reason: 'account record MUST survive /backup/remove');
      expect(tokens.removeCalls, 0,
          reason: '/backup/remove is not /account/delete');
    });

    test('idempotent: removing a non-existent backup is a no-op 200', () async {
      final tokens = _FakeTokenStore();
      final backups = _FakeBackupStore();

      final h = backupRemoveHandler(_config(), tokens, _auth(), store: backups);
      final res = await h(_request(bearer: _bearer('sub-x')));
      expect(res.statusCode, 200);
      // 404 inside BackupStore.remove is silently a no-op — that's
      // the contract this endpoint relies on to be retry-safe.
    });
  });
}