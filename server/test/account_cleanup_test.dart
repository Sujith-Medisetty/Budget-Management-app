import 'package:pocket_server/account_cleanup.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/gmail_filter_rules.dart';
import 'package:pocket_server/gmail_filter_sync.dart';
import 'package:pocket_server/token_store.dart';
import 'package:test/test.dart';

const _config = ServerConfig(
  gcpProject: 'test',
  pubsubTopic: 'gmail-history',
  webClientId: 'web-client-id',
  webClientSecret: 'web-client-secret',
  pubsubAudience: 'https://test/pubsub',
  apiTokenSecret: 'unit-test-secret-do-not-use-in-prod',
  tokenEncryptionKey:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  gmailTestMode: false,
  oauthTestMode: true,
  fcmDryRun: true,
  fcmProjectId: 'test',
);

/// In-memory stores for the cleanup test. Records the same calls the
/// real Firestore-backed stores would record, so tests can assert
/// that deleteAccountCompletely wipes everything in the right order.
class _MemTokenStore implements TokenStore {
  final Map<String, AccountRecord> _records = {};
  int removeCalls = 0;

  @override
  Future<void> put(String sub, AccountRecord record) async {
    _records[sub] = record;
  }

  @override
  Future<AccountRecord?> get(String sub) async => _records[sub];

  @override
  Future<void> remove(String sub) async {
    removeCalls++;
    _records.remove(sub);
  }

  @override
  Future<AccountRecord?> findByEmail(String email) async {
    for (final r in _records.values) {
      if (r.email == email) return r;
    }
    return null;
  }

  @override
  Future<String?> subForEmail(String email) async {
    final hit = await findByEmail(email);
    return hit?.sub;
  }

  @override
  Future<List<AccountRecord>> all() async => _records.values.toList();
}

class _MemRuleStore implements FilterRuleStore {
  final Map<String, FilterRuleSet> _sets = {};
  int removeCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<void> put(String sub, FilterRuleSet set) async {
    _sets[sub] = set;
  }

  @override
  Future<FilterRuleSet?> get(String sub) async => _sets[sub];

  @override
  Future<void> remove(String sub) async {
    removeCalls++;
    _sets.remove(sub);
  }
}

/// Records every `deleteFilter(id)` call. Lets us assert that
/// `deleteAccountCompletely` actually walks the rule set and hits
/// the Gmail REST API for every id, not just the first.
class _FakeGmailFilterSync extends GmailFilterSync {
  _FakeGmailFilterSync({required super.accessToken});
  final List<String> deleted = [];
  bool throwOnNext = false;

  @override
  Future<void> deleteFilter(String id) async {
    if (throwOnNext) {
      throwOnNext = false;
      throw StateError('gmail down');
    }
    deleted.add(id);
  }
}

void main() {
  group('deleteAccountCompletely', () {
    late _MemTokenStore tokens;
    late _MemRuleStore rules;
    late TokenCipher cipher;
    late _FakeGmailFilterSync fakeGmail;

    setUp(() {
      tokens = _MemTokenStore();
      rules = _MemRuleStore();
      cipher = TokenCipher(_config.tokenEncryptionKey);
      fakeGmail = _FakeGmailFilterSync(accessToken: 'fake-access');
    });

    test('wipes accounts/{sub} + filter_rules/{sub} + every Gmail filter',
        () async {
      const sub = 'sub-1';
      final sealed = await cipher.seal('refresh-token');
      await tokens.put(
        sub,
        AccountRecord(
          sub: sub,
          refreshToken: sealed,
          email: 'a@b.com',
          lastWatchAt: DateTime.now().toUtc(),
          lastHistoryId: 'h1',
          fcmTokens: const {'tok'},
          pocketLabelId: 'Label_2',
        ),
      );
      await rules.put(
        sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            FilterRule(
              id: 'gid-abc',
              sender: const RuleField(
                value: 'paypal',
                matchType: MatchType.contains,
              ),
            ),
            FilterRule(
              id: 'gid-def',
              sender: const RuleField(
                value: 'amazon',
                matchType: MatchType.contains,
              ),
            ),
          ],
        ),
      );

      await deleteAccountCompletely(
        config: _config,
        tokens: tokens,
        cipher: cipher,
        rules: rules,
        sub: sub,
        reason: 'test',
        exchangeRefresh: (_) async => 'fake-access',
        gmailFactory: (_, {pocketLabelId}) => fakeGmail,
      );

      expect(fakeGmail.deleted, ['gid-abc', 'gid-def'],
          reason: 'every Gmail filter must be DELETED');
      expect(tokens.removeCalls, 1, reason: 'accounts/{sub} deleted');
      expect(rules.removeCalls, 1, reason: 'filter_rules/{sub} deleted');
      expect(tokens._records.containsKey(sub), isFalse);
      expect(rules._sets.containsKey(sub), isFalse);
    });

    test('missing account record: still attempts filter cleanup, does not throw',
        () async {
      // No tokens.put() — simulates the race where /oauth/signout
      // already deleted the record before deleteAccountCompletely ran.
      const sub = 'sub-missing';

      await deleteAccountCompletely(
        config: _config,
        tokens: tokens,
        cipher: cipher,
        rules: rules,
        sub: sub,
        reason: 'test',
        exchangeRefresh: (_) async => 'fake-access',
        gmailFactory: (_, {pocketLabelId}) => fakeGmail,
      );

      expect(tokens.removeCalls, 1,
          reason: 'idempotent delete attempt still made');
      expect(rules.removeCalls, 1);
      expect(fakeGmail.deleted, isEmpty,
          reason: 'no rules means nothing to delete on Gmail side');
    });

    test('one Gmail filter delete fails: others still deleted, Firestore still wiped',
        () async {
      const sub = 'sub-network';
      final sealed = await cipher.seal('refresh-token');
      await tokens.put(
        sub,
        AccountRecord(
          sub: sub,
          refreshToken: sealed,
          email: 'a@b.com',
          lastWatchAt: DateTime.now().toUtc(),
          lastHistoryId: 'h1',
          pocketLabelId: 'Label_2',
        ),
      );
      await rules.put(
        sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            FilterRule(
              id: 'gid-fail',
              sender: const RuleField(
                value: 'paypal',
                matchType: MatchType.contains,
              ),
            ),
            FilterRule(
              id: 'gid-ok',
              sender: const RuleField(
                value: 'amazon',
                matchType: MatchType.contains,
              ),
            ),
          ],
        ),
      );
      fakeGmail.throwOnNext = true; // first deleteFilter() throws

      await deleteAccountCompletely(
        config: _config,
        tokens: tokens,
        cipher: cipher,
        rules: rules,
        sub: sub,
        reason: 'test',
        exchangeRefresh: (_) async => 'fake-access',
        gmailFactory: (_, {pocketLabelId}) => fakeGmail,
      );

      expect(fakeGmail.deleted, ['gid-ok'],
          reason: 'second filter should still be deleted despite first failing');
      expect(tokens._records.containsKey(sub), isFalse);
      expect(rules._sets.containsKey(sub), isFalse);
    });

    test('refresh-token exchange fails: filter cleanup skipped, Firestore still wiped',
        () async {
      const sub = 'sub-revoke';
      final sealed = await cipher.seal('refresh-token');
      await tokens.put(
        sub,
        AccountRecord(
          sub: sub,
          refreshToken: sealed,
          email: 'a@b.com',
          lastWatchAt: DateTime.now().toUtc(),
          lastHistoryId: 'h1',
          pocketLabelId: 'Label_2',
        ),
      );
      await rules.put(
        sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            FilterRule(
              id: 'gid-1',
              sender: const RuleField(
                value: 'paypal',
                matchType: MatchType.contains,
              ),
            ),
          ],
        ),
      );

      await deleteAccountCompletely(
        config: _config,
        tokens: tokens,
        cipher: cipher,
        rules: rules,
        sub: sub,
        reason: 'test',
        exchangeRefresh: (_) async =>
            throw StateError('refresh-token revoked'),
        gmailFactory: (_, {pocketLabelId}) => fakeGmail,
      );

      expect(fakeGmail.deleted, isEmpty,
          reason: 'no access token = no Gmail calls');
      expect(tokens._records.containsKey(sub), isFalse);
      expect(rules._sets.containsKey(sub), isFalse);
    });

    test('null-id rules (regex-only) are skipped, id-bearing rules are deleted',
        () async {
      const sub = 'sub-regex';
      final sealed = await cipher.seal('refresh-token');
      await tokens.put(
        sub,
        AccountRecord(
          sub: sub,
          refreshToken: sealed,
          email: 'a@b.com',
          lastWatchAt: DateTime.now().toUtc(),
          lastHistoryId: 'h1',
          pocketLabelId: 'Label_2',
        ),
      );
      await rules.put(
        sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            // Regex-only — no Gmail mirror, no id.
            FilterRule(
              sender: const RuleField(
                value: r'regex.*pattern',
                matchType: MatchType.regex,
              ),
            ),
            FilterRule(
              id: 'gid-mixed',
              sender: const RuleField(
                value: 'amazon',
                matchType: MatchType.contains,
              ),
            ),
          ],
        ),
      );

      await deleteAccountCompletely(
        config: _config,
        tokens: tokens,
        cipher: cipher,
        rules: rules,
        sub: sub,
        reason: 'test',
        exchangeRefresh: (_) async => 'fake-access',
        gmailFactory: (_, {pocketLabelId}) => fakeGmail,
      );

      expect(fakeGmail.deleted, ['gid-mixed'],
          reason: 'only the id-bearing rule should hit Gmail');
      expect(tokens._records.containsKey(sub), isFalse);
    });
  });
}
