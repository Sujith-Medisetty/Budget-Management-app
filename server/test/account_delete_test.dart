import 'dart:convert';

import 'package:pocket_server/account_delete.dart';
import 'package:pocket_server/backup_snapshot.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/auth.dart';
import 'package:pocket_server/gmail_filter_rules.dart';
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

class _FakeRuleStore implements FilterRuleStore {
  final Map<String, FilterRuleSet> docs = {};
  int removeCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<FilterRuleSet?> get(String sub) async => docs[sub];

  @override
  Future<void> put(String sub, FilterRuleSet set) async => docs[sub] = set;

  @override
  Future<void> remove(String sub) async {
    removeCalls++;
    docs.remove(sub);
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

Request _request({String? bearer, String body = '{}'}) {
  final headers = {'content-type': 'application/json'};
  if (bearer != null) headers['authorization'] = bearer;
  return Request(
    'POST',
    Uri.parse('http://localhost/account/delete'),
    headers: headers,
    body: body,
  );
}

Handler _handler(_FakeTokenStore tokens, _FakeRuleStore rules, _FakeBackupStore backups) =>
    accountDeleteHandler(
      _config(),
      tokens,
      TokenCipher('0123456789012345'),
      _auth(),
      rules,
      backups,
    );

void main() {
  group('account/delete', () {
    test('rejects when missing bearer', () async {
      final h = _handler(_FakeTokenStore(), _FakeRuleStore(), _FakeBackupStore());
      final res = await h(_request());
      expect(res.statusCode, 403);
    });

    test('rejects bearer with bad signature', () async {
      // Sign with a different secret so the verifyApiToken check fails.
      final bad = TokenAuth(apiTokenSecret: 'wrong-secret').signApiToken(
        sub: 'sub-1',
        ttl: const Duration(minutes: 5),
      );
      final h = _handler(_FakeTokenStore(), _FakeRuleStore(), _FakeBackupStore());
      final res = await h(_request(bearer: 'Bearer $bad'));
      expect(res.statusCode, 403);
    });

    test('wipes account, filter rules, and backup', () async {
      final tokens = _FakeTokenStore()
        ..records['sub-1'] = AccountRecord(
          sub: 'sub-1',
          email: 'me@example.com',
          refreshToken: 'enc:blob',
          lastWatchAt: DateTime.utc(2026, 9, 1),
          lastHistoryId: 'hist-1',
          fcmTokens: {'fcm-1'},
        );
      final rules = _FakeRuleStore();
      final backups = _FakeBackupStore()..docs['sub-1'] = BackupSnapshot(
            uploadedAt: DateTime.utc(2026, 9, 7),
            transactions: const [{'id': 1}],
            budgets: const [],
          );

      final res = await _handler(tokens, rules, backups)(
        _request(bearer: _bearer('sub-1')),
      );

      expect(res.statusCode, 200);
      final body = jsonDecode(await res.readAsString()) as Map<String, dynamic>;
      expect(body['deleted'], true);
      expect(body['sub'], 'sub-1');

      expect(tokens.records.containsKey('sub-1'), isFalse,
          reason: 'account record should be gone');
      expect(rules.docs.containsKey('sub-1'), isFalse,
          reason: 'filter rules should be gone');
      expect(backups.docs.containsKey('sub-1'), isFalse,
          reason: 'GCS backup should be removed');
      expect(backups.removeCalls, 1);
    });

    test('idempotent: re-running on already-wiped user is a no-op 200', () async {
      // Simulates the client retrying after a transient network blip
      // — the second call must not error, must still return 200.
      final tokens = _FakeTokenStore();
      final rules = _FakeRuleStore();
      final backups = _FakeBackupStore();

      final h = _handler(tokens, rules, backups);
      final first = await h(_request(bearer: _bearer('sub-1')));
      expect(first.statusCode, 200);

      final second = await h(_request(bearer: _bearer('sub-1')));
      expect(second.statusCode, 200);
    });
  });

  group('BackupStore.backupUploadedAt', () {
    test('returns null when no backup exists', () async {
      final s = _FakeBackupStore();
      expect(await s.backupUploadedAt('sub-x'), isNull);
    });

    test('returns the snapshot timestamp when a backup exists', () async {
      final s = _FakeBackupStore()
        ..docs['sub-1'] = BackupSnapshot(
          uploadedAt: DateTime.utc(2026, 9, 7, 12),
          transactions: const [],
          budgets: const [],
        );
      final ts = await s.backupUploadedAt('sub-1');
      expect(ts, isNotNull);
      expect(ts!.toIso8601String(), '2026-09-07T12:00:00.000Z');
    });
  });
}