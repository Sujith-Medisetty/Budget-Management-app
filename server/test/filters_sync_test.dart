import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pocket_server/auth.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/filters_status.dart';
import 'package:pocket_server/filters_sync.dart';
import 'package:pocket_server/gmail_filter_rules.dart';
import 'package:pocket_server/gmail_filter_sync.dart';
import 'package:pocket_server/gmail_labels.dart';
import 'package:pocket_server/token_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// Hand-rolled fake of `GmailFilterSync`. Subclassing so we inherit
/// the constructor signature the handler uses — no factory needed.
class _FakeGmail extends GmailFilterSync {
  _FakeGmail() : super(accessToken: 'test-token');

  final List<String> createIds = ['gid-1', 'gid-2', 'gid-3'];
  final List<FilterRule> created = [];
  final List<String> deleted = [];

  int _createIndex = 0;

  @override
  Future<String> createFilter(FilterRule rule) async {
    // Mirror the real implementation's untranslatable check so test
    // expectations match production behavior.
    if (criteriaFor(rule).isEmpty) {
      throw const UntranslatableRule();
    }
    if (createShouldThrow != null) {
      throw createShouldThrow!;
    }
    if (_createIndex >= createIds.length) {
      throw StateError('test ran out of fake ids — pass more');
    }
    created.add(rule);
    return createIds[_createIndex++];
  }

  /// When non-null, the next [createFilter] call throws this instead
  /// of returning an id — simulates a Gmail-side create rejection
  /// (e.g. 400 for malformed criteria). Cleared after one use so
  /// subsequent calls in the same test still succeed.
  Object? createShouldThrow;

  @override
  Future<void> deleteFilter(String id) async {
    deleted.add(id);
  }

  /// Override the live-id set so individual tests can simulate
  /// "user deleted filter X in Gmail's UI". Defaults to all created
  /// ids, meaning "no Gmail-side deletions" — the prune loop is a
  /// no-op unless a test sets [liveOverride] explicitly.
  Set<String>? liveOverride;

  /// When non-null, listExistingFilterIds throws this — used to
  /// simulate Gmail API failures (network/timeout/5xx).
  Object? listShouldThrow;

  @override
  Future<Set<String>> listExistingFilterIds({
    Set<String>? injected,
  }) async {
    if (listShouldThrow != null) throw listShouldThrow!;
    return liveOverride ?? created.map((r) => r.id).whereType<String>().toSet();
  }

  /// Mirror of [listExistingFilterIds] for the import path — returns
  /// stub [FilterRule]s carrying only an id (so the prune/import
  /// merge logic in `/filters/status` exercises the same shape it
  /// would see from real Gmail).
  ///
  /// When [importableFilters] is set, return that list instead. Used
  /// by tests that want to simulate "Gmail has these full-criteria
  /// filters that we don't know about yet" — the import-path tests
  /// need real `from` / `subject` / `body` data to verify the merge
  /// ends up with the right rule objects.
  List<FilterRule>? importableFilters;

  @override
  Future<List<FilterRule>> listExistingFilters({
    List<Map<String, dynamic>>? injected,
  }) async {
    if (listShouldThrow != null) throw listShouldThrow!;
    if (importableFilters != null) return importableFilters!;
    final ids = liveOverride ?? created.map((r) => r.id).whereType<String>().toSet();
    return ids
        .map((id) => FilterRule(id: id))
        .toList(growable: false);
  }
}

/// In-memory FilterRuleStore for tests. Same shape as
/// `AccountsFilterRuleStore.get` / `put` but without the network.
class _FakeRuleStore implements FilterRuleStore {
  final Map<String, FilterRuleSet> _data = {};

  int initCalls = 0;

  @override
  Future<void> init() async {
    initCalls++;
  }

  @override
  Future<FilterRuleSet?> get(String sub) async => _data[sub];

  @override
  Future<void> put(String sub, FilterRuleSet set) async {
    _data[sub] = set;
  }

  @override
  Future<void> remove(String sub) async {
    _data.remove(sub);
  }
}

const _config = ServerConfig(
  gcpProject: 'test',
  pubsubTopic: 't',
  webClientId: 'w',
  webClientSecret: 's',
  pubsubAudience: 'a',
  apiTokenSecret: 'unit-test-secret',
  tokenEncryptionKey:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  gmailTestMode: true,
  oauthTestMode: true,
  fcmDryRun: true,
  fcmProjectId: 'test',
);

const _cipherKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Request _post(String apiToken, FilterRuleSet set) {
  return Request(
    'POST',
    Uri.parse('http://test/filters/sync'),
    headers: {
      'authorization': 'Bearer $apiToken',
      'content-type': 'application/json',
    },
    body: jsonEncode({'rules': jsonEncode(set.toJson())}),
  );
}

FilterRule _rule({
  String? id,
  String? from,
  String? subject,
  String? body,
  MatchType matchType = MatchType.contains,
}) {
  RuleField? f(String? v) =>
      v == null ? null : RuleField(value: v, matchType: matchType);
  return FilterRule(
    id: id,
    sender: f(from),
    subject: f(subject),
    body: f(body),
  );
}

void main() {
  group('FilterRule JSON round-trip', () {
    test('preserves id field', () {
      final r = FilterRule(
        id: 'gid-1',
        sender: const RuleField(
            value: 'paypal.com', matchType: MatchType.contains),
      );
      final j = r.toJson();
      expect(j['id'], 'gid-1');
      final back = FilterRule.fromJson(j);
      expect(back.id, 'gid-1');
      expect(back.sender?.value, 'paypal.com');
    });

    test('omits id when null (legacy / un-mirrored rule)', () {
      final r = FilterRule(
        sender: const RuleField(
            value: 'paypal.com', matchType: MatchType.contains),
      );
      expect(r.toJson().containsKey('id'), isFalse);
      final back = FilterRule.fromJson({
        'sender': {'value': 'paypal.com', 'matchType': 'contains'},
      });
      expect(back.id, isNull);
    });

    test('round-trip preserves all three rule fields', () {
      final r = FilterRule(
        sender: const RuleField(value: 'a@x', matchType: MatchType.regex),
        subject: const RuleField(
            value: 'receipt', matchType: MatchType.contains),
        body: const RuleField(value: 'USD', matchType: MatchType.contains),
      );
      final back = FilterRule.fromJson(r.toJson());
      expect(back.sender?.matchType, MatchType.regex);
      expect(back.subject?.value, 'receipt');
      expect(back.body?.value, 'USD');
    });

    test('isEmpty ignores id (id is metadata, not a criterion)', () {
      final r = FilterRule(id: 'gid-1');
      expect(r.isEmpty, isTrue);
    });
  });

  group('FilterRuleSet logic', () {
    test('disabled = process everything', () {
      final s = FilterRuleSet(
        enabled: false,
        logic: Logic.and,
        rules: [
          FilterRule(
            subject: const RuleField(
                value: 'never matches', matchType: MatchType.contains),
          ),
        ],
      );
      expect(s.allows(from: 'x', subject: 'y', body: 'z'), isTrue);
    });

    test('empty rules = process everything (opt-in)', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: const <FilterRule>[],
      );
      expect(s.allows(from: 'x', subject: 'y', body: 'z'), isTrue);
    });

    test('OR: any rule matching → capture (returns true)', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
          FilterRule(
            sender: const RuleField(
                value: 'stripe.com', matchType: MatchType.contains),
          ),
        ],
      );
      // A rule matches → email becomes a transaction.
      expect(s.allows(from: 'service@paypal.com', subject: 'x', body: 'y'),
          isTrue);
      expect(s.allows(from: 'service@stripe.com', subject: 'x', body: 'y'),
          isTrue);
      // No rule matches → silently dropped (doesn't become a
      // transaction).
      expect(s.allows(from: 'random@x.com', subject: 'x', body: 'y'), isFalse);
    });

    test('AND: all rules matching → capture (returns true)', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.and,
        rules: [
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
          FilterRule(
            subject: const RuleField(
                value: 'receipt', matchType: MatchType.contains),
          ),
        ],
      );
      // Both match → capture.
      expect(
          s.allows(from: 'a@paypal.com', subject: 'your receipt', body: ''),
          isTrue);
      // Only one matches → drop (AND needs intersection).
      expect(s.allows(from: 'a@paypal.com', subject: 'shipping', body: ''),
          isFalse);
    });

    test('empty rule in list is a no-op', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          const FilterRule(),
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
        ],
      );
      // Empty rule doesn't contribute to the OR tally; the PayPal
      // rule still matches the PayPal sender → capture.
      expect(s.allows(from: 'a@paypal.com', subject: '', body: ''), isTrue);
    });
  });

  group('GmailFilterSync criteria translation', () {
    test('sender contains → from field', () {
      final f = GmailFilterSync(accessToken: 't');
      final c = f.criteriaFor(_rule(from: 'paypal.com'));
      expect(c['from'], 'paypal.com');
      expect(c.containsKey('subject'), isFalse);
      expect(c.containsKey('query'), isFalse);
    });

    test('subject contains → subject field', () {
      final f = GmailFilterSync(accessToken: 't');
      final c = f.criteriaFor(_rule(subject: 'receipt'));
      expect(c['subject'], 'receipt');
    });

    test('body contains → query field (Gmail has no body field)', () {
      final f = GmailFilterSync(accessToken: 't');
      final c = f.criteriaFor(_rule(body: 'USD'));
      expect(c['query'], 'USD');
      expect(c.containsKey('body'), isFalse);
    });

    test('regex matchType → criteria map is empty (caller throws)', () {
      final f = GmailFilterSync(accessToken: 't');
      // criteriaFor skips regex fields with a warning. The throw
      // happens in createFilter when it sees the empty criteria map.
      final c = f.criteriaFor(
          _rule(from: '.*@paypal\\.com', matchType: MatchType.regex));
      expect(c, isEmpty);
    });

    test('mixed: sender + subject → from AND subject', () {
      final f = GmailFilterSync(accessToken: 't');
      final c = f.criteriaFor(_rule(from: 'paypal.com', subject: 'receipt'));
      expect(c['from'], 'paypal.com');
      expect(c['subject'], 'receipt');
    });
  });

  group('filtersSyncHandler', () {
    late TokenAuth auth;
    late TokenCipher cipher;
    late InMemoryTokenStore tokens;
    late _FakeRuleStore store;
    late _FakeGmail gmail;
    late Handler handler;

    setUp(() async {
      auth = TokenAuth(apiTokenSecret: _config.apiTokenSecret);
      cipher = TokenCipher(_cipherKey);
      tokens = InMemoryTokenStore();
      await tokens.put(
        'sub-1',
        AccountRecord(
          sub: 'sub-1',
          refreshToken: await cipher.seal('test-refresh'),
          email: 'me@example.com',
          lastWatchAt: DateTime.utc(2026, 9, 5),
          lastHistoryId: '1',
        ),
      );
      store = _FakeRuleStore();
      gmail = _FakeGmail();
      handler = filtersSyncHandler(
        _config,
        tokens,
        cipher,
        auth,
        store: store,
        gmailFactory: (_, {pocketLabelId}) => gmail,
        exchangeRefresh: (_) async => 'test-access-token',
      );
    });

    test('returns 403 without bearer token', () async {
      final req = Request('POST', Uri.parse('http://test/filters/sync'));
      final r = await handler(req);
      expect(r.statusCode, 403);
    });

    test('returns 400 on missing rules field', () async {
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final req = Request(
        'POST',
        Uri.parse('http://test/filters/sync'),
        headers: {
          'authorization': 'Bearer $apiToken',
          'content-type': 'application/json',
        },
        body: jsonEncode({}),
      );
      final r = await handler(req);
      expect(r.statusCode, 400);
    });

    test('returns 400 on invalid JSON', () async {
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final req = Request(
        'POST',
        Uri.parse('http://test/filters/sync'),
        headers: {
          'authorization': 'Bearer $apiToken',
          'content-type': 'application/json',
        },
        body: 'not json',
      );
      final r = await handler(req);
      expect(r.statusCode, 400);
    });

    test('first sync: creates a Gmail filter per rule, returns ids',
        () async {
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(from: 'paypal.com'),
          _rule(from: 'stripe.com'),
        ],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      expect(gmail.created.length, 2);
      expect(gmail.deleted, isEmpty);
      // Merged response should carry the assigned ids.
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules[0].id, 'gid-1');
      expect(merged.rules[1].id, 'gid-2');
      // Stored on the server-side store too.
      expect(store._data['sub-1']?.rules.length, 2);
      // Init was called on the store.
      expect(store.initCalls, 1);
    });

    test('id round-trip: existing rule changed → delete + recreate', () async {
      // Server state has rule with id 'gid-existing'. Phone sends back
      // the same rule with different criteria — handler deletes the
      // old Gmail filter and creates a new one, returning the new id.
      await store.put(
        'sub-1',
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [_rule(id: 'gid-existing', from: 'paypal.com')],
        ),
      );
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      // Phone sends the same rule (same id) but with a different sender.
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [_rule(id: 'gid-existing', from: 'paypal.net')],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      expect(gmail.deleted, ['gid-existing']);
      expect(gmail.created.length, 1);
      // Response carries the new id.
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules[0].id, 'gid-1');
      expect(merged.rules[0].id, isNot('gid-existing'));
    });

    test('removed rule: id on server, absent in incoming → deleted',
        () async {
      await store.put(
        'sub-1',
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            _rule(id: 'gid-remove', from: 'old.com'),
            _rule(id: 'gid-keep', from: 'new.com'),
          ],
        ),
      );
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      // Phone sends only the kept rule.
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [_rule(id: 'gid-keep', from: 'new.com')],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      expect(gmail.deleted, ['gid-remove']);
      expect(gmail.created, isEmpty);
    });

    test('empty rule (no fields) → kept but no Gmail call', () async {
      // A rule with no criteria can't translate to Gmail — phone
      // sends it, server returns it without an id and skips Gmail.
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [const FilterRule()],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      expect(gmail.created, isEmpty);
      expect(gmail.deleted, isEmpty);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules.length, 1);
      expect(merged.rules[0].isEmpty, isTrue);
      expect(merged.rules[0].id, isNull);
    });

    test('regex-only rule → kept without id (phone-side still matches)',
        () async {
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [_rule(from: r'.*@paypal\.com', matchType: MatchType.regex)],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      // Regex can't be mirrored → no Gmail create call.
      expect(gmail.created, isEmpty);
      // But the rule itself is still in the merged set, just without an id.
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules.length, 1);
      expect(merged.rules[0].id, isNull);
      expect(merged.rules[0].sender?.matchType, MatchType.regex);
    });

    test('refresh-token exchange failure → 502', () async {
      final handler = filtersSyncHandler(
        _config,
        tokens,
        cipher,
        auth,
        store: store,
        gmailFactory: (_, {pocketLabelId}) => gmail,
        exchangeRefresh: (_) async =>
            throw StateError('oauth down'),
      );
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final r = await handler(_post(
        apiToken,
        FilterRuleSet(
            enabled: true, logic: Logic.or, rules: [_rule(from: 'a')]),
      ));
      expect(r.statusCode, 502);
    });

    test(
        'create filter failure → rule KEPT with id=null + errors map '
        '(was: silently dropped, screen went empty)',
        () async {
      // Regression guard: previously a Gmail 400 caused the rule to
      // be silently dropped from the merged set, so the phone's
      // `replaceFromSync` overwrote local state with an empty rule
      // list — the user saw "Saved successfully" and then a blank
      // screen. Now the rule survives with id=null and the response
      // includes an errors map keyed by rule index.
      gmail.createShouldThrow =
          StateError('gmail filter create failed: 400 {error:invalid}');

      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final r = await handler(_post(
        apiToken,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [_rule(from: 'paypal.com')],
        ),
      ));
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      // Rule survives — Gmail didn't mirror it but we don't lose
      // the user's edit.
      expect(merged.rules, hasLength(1));
      expect(merged.rules.single.id, isNull);
      expect(merged.rules.single.sender?.value, 'paypal.com');
      // Errors map points at the failed rule by index so the client
      // can surface a warning.
      expect(body['errors'], isA<Map>());
      expect((body['errors'] as Map).containsKey('0'), isTrue);
      // Persisted state matches what the client received.
      final stored = await store.get('sub-1');
      expect(stored!.rules, hasLength(1));
      expect(stored.rules.single.id, isNull);
    });

    test(
        'gmailTestMode: skips real OAuth + Gmail, hands back fake ids',
        () async {
      // Build a fresh handler without gmailFactory / exchangeRefresh so
      // the real GmailFilterSync + _exchangeRefreshToken paths run.
      // _config has gmailTestMode: true, so both short-circuit.
      final handler = filtersSyncHandler(
        _config,
        tokens,
        cipher,
        auth,
        store: store,
      );
      final apiToken =
          auth.signApiToken(sub: 'sub-1', ttl: const Duration(hours: 1));
      final incoming = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(from: 'paypal.com'),
          _rule(from: 'stripe.com'),
        ],
      );
      final r = await handler(_post(apiToken, incoming));
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      // Fake ids are assigned in order, prefixed `test-gid-`.
      expect(merged.rules[0].id, 'test-gid-1');
      expect(merged.rules[1].id, 'test-gid-2');
    });
  });

  group('filter rule end-to-end intent (allowlist)', () {
    test('OR: rule matches sender → capture (returns true)', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
        ],
      );
      expect(
          s.allows(from: 'service@paypal.com', subject: 'Receipt', body: ''),
          isTrue);
    });

    test('OR: rule does not match sender → drop (returns false)', () {
      final s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
        ],
      );
      expect(s.allows(from: 'friend@gmail.com', subject: 'Hi', body: ''),
          isFalse);
    });

    test('master off → everything captures (opt-in)', () {
      final s = FilterRuleSet(
        enabled: false,
        logic: Logic.or,
        rules: [
          FilterRule(
            sender: const RuleField(
                value: 'paypal.com', matchType: MatchType.contains),
          ),
        ],
      );
      expect(s.allows(from: 'service@paypal.com', subject: 'x', body: ''),
          isTrue);
    });
  });

  group('GET /filters/status (prune orphan Gmail-side ids)', () {
    late TokenAuth auth;
    late TokenCipher cipher;
    late InMemoryTokenStore tokens;
    late _FakeRuleStore store;
    late _FakeGmail gmail;

    setUp(() async {
      auth = TokenAuth(apiTokenSecret: _config.apiTokenSecret);
      cipher = TokenCipher(_cipherKey);
      tokens = InMemoryTokenStore();
      await tokens.put(
        'sub-1',
        AccountRecord(
          sub: 'sub-1',
          refreshToken: await cipher.seal('test-refresh'),
          email: 'me@example.com',
          lastWatchAt: DateTime.utc(2026, 9, 5),
          lastHistoryId: '1',
        ),
      );
      store = _FakeRuleStore();
      gmail = _FakeGmail();
    });

    // already correct

    Request get(String apiToken) => Request(
          'GET',
          Uri.parse('http://test/filters/status'),
          headers: {'authorization': 'Bearer $apiToken'},
        );

    Future<Response> buildHandler() async {
      return filtersStatusHandler(
        _config,
        tokens,
        cipher,
        auth,
        store: store,
        gmailFactory: (_, {pocketLabelId}) => gmail,
      )(get(auth.signApiToken(
        sub: 'sub-1',
        ttl: const Duration(hours: 1),
      )));
    }

    test('returns 403 without bearer token', () async {
      final r = await filtersStatusHandler(
        _config,
        tokens,
        cipher,
        auth,
        store: store,
        gmailFactory: (_, {pocketLabelId}) => gmail,
      )(Request('GET', Uri.parse('http://test/filters/status')));
      expect(r.statusCode, 403);
    });

    test('nothing in store → returns defaults, no prune', () async {
      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final cleaned = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(cleaned.enabled, isFalse);
      expect(cleaned.rules, isEmpty);
    });

    test('all stored ids still in Gmail → kept, store untouched', () async {
      await store.put('sub-1', FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(id: 'gid-1', from: 'paypal.com'),
          _rule(id: 'gid-2', from: 'stripe.com'),
        ],
      ));
      gmail.liveOverride = {'gid-1', 'gid-2'}; // both still in Gmail

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final cleaned = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(cleaned.rules, hasLength(2));
      expect(cleaned.rules.every((r) => r.id != null), isTrue);
      final stored = await store.get('sub-1');
      expect(stored!.rules, hasLength(2));
    });

    test('user deleted gid-2 in Gmail → pruned from store + response',
        () async {
      await store.put('sub-1', FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(id: 'gid-1', from: 'paypal.com'),
          _rule(id: 'gid-2', from: 'stripe.com'),
        ],
      ));
      gmail.liveOverride = {'gid-1'}; // gid-2 deleted in Gmail UI

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final cleaned = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(cleaned.rules, hasLength(1));
      expect(cleaned.rules.single.id, 'gid-1');
      final stored = await store.get('sub-1');
      expect(stored!.rules, hasLength(1));
    });

    test('null-id rule (regex-only) survives even if Gmail list is empty',
        () async {
      await store.put('sub-1', FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          FilterRule(
            sender: const RuleField(
              value: '^service@.*\\.com\$',
              matchType: MatchType.regex,
            ),
          ),
        ],
      ));
      gmail.liveOverride = {}; // Gmail has zero filters

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final cleaned = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(cleaned.rules, hasLength(1));
      expect(cleaned.rules.single.id, isNull);
    });
  });

  group('GET /filters/status (import Gmail-side filters)', () {
    late _FakeGmail gmail;
    late _FakeRuleStore store;
    late TokenAuth auth;
    late TokenCipher cipher;
    late InMemoryTokenStore tokens;
    late String apiToken;
    late Future<Response> Function() buildHandler;

    setUp(() async {
      gmail = _FakeGmail();
      store = _FakeRuleStore();
      auth = TokenAuth(apiTokenSecret: _config.apiTokenSecret);
      cipher = TokenCipher(_cipherKey);
      tokens = InMemoryTokenStore();
      await tokens.put('sub-1', AccountRecord(
        sub: 'sub-1',
        email: 'me@example.com',
        refreshToken: await cipher.seal('test-refresh'),
        lastWatchAt: DateTime.utc(2026, 9, 5),
        lastHistoryId: '1',
      ));
      apiToken = auth.signApiToken(
        sub: 'sub-1',
        ttl: const Duration(hours: 1),
      );
      buildHandler = () async {
        final handler = filtersStatusHandler(
          _config,
          tokens,
          cipher,
          auth,
          store: store,
          gmailFactory: (_, {pocketLabelId}) => gmail,
        );
        return handler(Request(
          'GET',
          Uri.parse('http://test/filters/status'),
          headers: {'authorization': 'Bearer $apiToken'},
        ));
      };
    });

    test(
        'Gmail has filters, store is empty → all Gmail filters '
        'imported into the stored set', () async {
      // Empty store; user has filters only in Gmail's UI.
      gmail.importableFilters = [
        FilterRule(
          id: 'gid-A',
          sender: const RuleField(
            value: 'paypal.com', matchType: MatchType.contains),
        ),
        FilterRule(
          id: 'gid-B',
          subject: const RuleField(
            value: 'receipt', matchType: MatchType.contains),
          body: const RuleField(
            value: 'invoice', matchType: MatchType.contains),
        ),
      ];

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules, hasLength(2));
      final byId = {for (final r in merged.rules) r.id: r};
      expect(byId['gid-A']?.sender?.value, 'paypal.com');
      expect(byId['gid-B']?.subject?.value, 'receipt');
      expect(byId['gid-B']?.body?.value, 'invoice');

      // The merge is persisted to the store so the next sync has
      // the Gmail ids to PATCH / DELETE against.
      final stored = await store.get('sub-1');
      expect(stored!.rules, hasLength(2));
      expect(stored.rules.map((r) => r.id).toSet(),
          {'gid-A', 'gid-B'});
    });

    test(
        'Gmail has new filter not in store → import added alongside '
        'existing rules', () async {
      await store.put('sub-1', FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(id: 'gid-old', from: 'amazon.com'),
        ],
      ));
      // Gmail has the old one plus a new one we don't know about.
      gmail.importableFilters = [
        FilterRule(
          id: 'gid-old',
          sender: const RuleField(
            value: 'amazon.com', matchType: MatchType.contains),
        ),
        FilterRule(
          id: 'gid-new',
          sender: const RuleField(
            value: 'venmo.com', matchType: MatchType.contains),
        ),
      ];

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules, hasLength(2));
      expect(merged.rules.map((r) => r.id).toSet(),
          {'gid-old', 'gid-new'});
    });

    test(
        'Gmail filter with same id already in store → no duplicate, '
        'store criteria unchanged', () async {
      await store.put('sub-1', FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          _rule(id: 'gid-A', from: 'paypal.com'),
        ],
      ));
      // Gmail has the same id with the same criteria — no churn.
      gmail.importableFilters = [
        FilterRule(
          id: 'gid-A',
          sender: const RuleField(
            value: 'paypal.com', matchType: MatchType.contains),
        ),
      ];

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.rules, hasLength(1));
      expect(merged.rules.single.id, 'gid-A');
      // When nothing changed the store is left alone — the
      // import path is no-op when ids line up.
      final stored = await store.get('sub-1');
      expect(stored!.rules.single.id, 'gid-A');
    });

    test(
        'import path does NOT flip the master enabled switch — '
        'Pocket-only decision', () async {
      // Store starts disabled (master switch off). Even if Gmail has
      // lots of filters, importing them mustn't turn the switch on.
      await store.put('sub-1', FilterRuleSet.defaults);
      gmail.importableFilters = [
        FilterRule(
          id: 'gid-A',
          sender: const RuleField(
            value: 'paypal.com', matchType: MatchType.contains),
        ),
      ];

      final r = await buildHandler();
      expect(r.statusCode, 200);
      final body = jsonDecode(await r.readAsString()) as Map<String, dynamic>;
      final merged = FilterRuleSet.fromJson(
          jsonDecode(body['rules'] as String) as Map<String, dynamic>);
      expect(merged.enabled, isFalse);
      expect(merged.rules, hasLength(1));
    });
  });

  group('GmailFilterSync listExistingFilterIds — real HTTP', () {
    /// Config with gmailTestMode = false so the real HTTP path runs
    /// (the test-mode short-circuit returns early before touching the
    /// injected client). All other fields are placeholders.
    final prodLikeConfig = ServerConfig(
      gcpProject: 'test',
      pubsubTopic: 't',
      webClientId: 'w',
      webClientSecret: 's',
      pubsubAudience: 'a',
      apiTokenSecret: 'unit-test-secret',
      tokenEncryptionKey:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      gmailTestMode: false,
      oauthTestMode: true,
      fcmDryRun: true,
      fcmProjectId: 'test',
    );

    test('204 No Content → empty set (real Gmail response for zero filters)',
        () async {
      final client = _CannedClient(204, '');
      final sync = GmailFilterSync(
        accessToken: 't',
        client: client,
        config: prodLikeConfig,
      );
      final ids = await sync.listExistingFilterIds();
      expect(ids, isEmpty);
      expect(client.seen, hasLength(1));
    });

    test('200 with empty filter array → empty set', () async {
      final client = _CannedClient(200, '{"filter":[]}');
      final sync = GmailFilterSync(
          accessToken: 't', client: client, config: prodLikeConfig);
      final ids = await sync.listExistingFilterIds();
      expect(ids, isEmpty);
    });

    test('200 with two filters → returns both ids', () async {
      final body = jsonEncode({
        'filter': [
          {'id': 'gid-1'},
          {'id': 'gid-2'},
        ],
      });
      final client = _CannedClient(200, body);
      final sync = GmailFilterSync(
          accessToken: 't', client: client, config: prodLikeConfig);
      expect(await sync.listExistingFilterIds(), {'gid-1', 'gid-2'});
    });

    test('non-200 (e.g. 401, 500) → throws StateError', () async {
      final client = _CannedClient(401, 'unauthorized');
      final sync = GmailFilterSync(
          accessToken: 't', client: client, config: prodLikeConfig);
      expect(sync.listExistingFilterIds(), throwsStateError);
    });
  });

  group('GmailFilterSync createFilter — request body', () {
    test(
        'POST body includes criteria AND a non-empty action '
        '(Gmail rejects filters without actions)',
        () async {
      // Regression: earlier code only sent `criteria` and got back 400
      // "Filter doesn't have any actions". The action must use one
      // of Gmail's three recognized fields: `addLabelIds[]`,
      // `removeLabelIds[]`, `forward` — anything else (like
      // `important: false`) is silently ignored, leaving the action
      // empty, and Gmail rejects the filter.
      final client = _BodyCapturingClient();
      final sync = GmailFilterSync(
        accessToken: 't',
        client: client,
        pocketLabelId: null, // legacy / no label yet → STARRED fallback
        config: ServerConfig(
          gcpProject: 'test',
          pubsubTopic: 't',
          webClientId: 'w',
          webClientSecret: 's',
          pubsubAudience: 'a',
          apiTokenSecret: 'unit-test-secret',
          tokenEncryptionKey:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          gmailTestMode: false, // exercise the real POST path
          oauthTestMode: true,
          fcmDryRun: true,
          fcmProjectId: 'test',
        ),
      );
      final id = await sync.createFilter(_rule(from: 'paypal.com'));
      expect(id, 'gid-new');
      expect(client.lastBody, isNotNull);
      final sent = jsonDecode(client.lastBody!) as Map<String, dynamic>;
      expect(sent['criteria'], isA<Map>());
      expect((sent['criteria'] as Map)['from'], 'paypal.com');
      final action = sent['action'] as Map;
      expect(action['addLabelIds'], isA<List>());
      expect(action['addLabelIds'], contains('STARRED'));
    });

    test(
        'when pocketLabelId is set, filter action adds the Pocket label '
        '(drives users.watch selection)',
        () async {
      final client = _BodyCapturingClient();
      final sync = GmailFilterSync(
        accessToken: 't',
        client: client,
        pocketLabelId: 'Label_42',
        config: ServerConfig(
          gcpProject: 'test',
          pubsubTopic: 't',
          webClientId: 'w',
          webClientSecret: 's',
          pubsubAudience: 'a',
          apiTokenSecret: 'unit-test-secret',
          tokenEncryptionKey:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          gmailTestMode: false,
          oauthTestMode: true,
          fcmDryRun: true,
          fcmProjectId: 'test',
        ),
      );
      await sync.createFilter(_rule(from: 'paypal.com'));
      final sent =
          jsonDecode(client.lastBody!) as Map<String, dynamic>;
      final action = sent['action'] as Map;
      expect(action['addLabelIds'], contains('Label_42'));
      // STARRED is NOT added when we have a Pocket label — adding
      // both would mark every matching email starred which clutters
      // the user's inbox.
      expect(action['addLabelIds'], isNot(contains('STARRED')));
    });

    test(
        'POST 400 "Filter already exists" → recover by listing '
        'existing filters and returning the matching id',
        () async {
      // Simulates the production failure mode: Gmail already has a
      // filter with identical criteria (from a previous install or
      // manual creation). POST returns 400; the recovery path lists
      // filters and matches by criteria, returning the existing id so
      // the rule is properly mirrored.
      final client = _SequenceClient([
        // 1st call: POST → 400 "Filter already exists"
        (
          400,
          jsonEncode({
            'error': {
              'code': 400,
              'message': 'Filter already exists',
            },
          }),
        ),
        // 2nd call: GET → list containing a matching filter
        (
          200,
          jsonEncode({
            'filter': [
              {
                'id': 'gid-existing',
                'criteria': {'from': 'paypal.com'},
                'action': {'addLabelIds': ['STARRED']},
              },
              {
                'id': 'gid-other',
                'criteria': {'from': 'stripe.com'},
                'action': {'addLabelIds': ['STARRED']},
              },
            ],
          }),
        ),
      ]);
      final sync = GmailFilterSync(
        accessToken: 't',
        client: client,
        config: ServerConfig(
          gcpProject: 'test',
          pubsubTopic: 't',
          webClientId: 'w',
          webClientSecret: 's',
          pubsubAudience: 'a',
          apiTokenSecret: 'unit-test-secret',
          tokenEncryptionKey:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          gmailTestMode: false,
          oauthTestMode: true,
          fcmDryRun: true,
          fcmProjectId: 'test',
        ),
      );
      final id = await sync.createFilter(_rule(from: 'paypal.com'));
      expect(id, 'gid-existing');
      expect(client.seen.length, 2, reason: 'POST then GET');
      expect(client.seen[0].path, contains('/filters'));
      expect(client.seen[1].path, contains('/filters'));
    });

    test(
        'POST 400 with non-"already exists" message → still throws '
        '(no spurious recovery on unrelated Gmail 400s)',
        () async {
      // Gmail returns 400 for other reasons too (invalid action,
      // bad criteria, etc.). The recovery path must not swallow them —
      // the user needs to know their rule didn't mirror.
      final client = _CannedClient(
        400,
        jsonEncode({
          'error': {
            'code': 400,
            'message': 'Invalid criteria: unsupported field',
          },
        }),
      );
      final sync = GmailFilterSync(
        accessToken: 't',
        client: client,
        config: ServerConfig(
          gcpProject: 'test',
          pubsubTopic: 't',
          webClientId: 'w',
          webClientSecret: 's',
          pubsubAudience: 'a',
          apiTokenSecret: 'unit-test-secret',
          tokenEncryptionKey:
              '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
          gmailTestMode: false,
          oauthTestMode: true,
          fcmDryRun: true,
          fcmProjectId: 'test',
        ),
      );
      expect(
        () => sync.createFilter(_rule(from: 'paypal.com')),
        throwsStateError,
      );
    });
  });

  group('GmailLabelManager', () {
    test('ensurePocketLabelId: returns existing label id when present',
        () async {
      final client = _CannedClient(
        200,
        jsonEncode({
          'labels': [
            {'id': 'Label_other', 'name': 'Other'},
            {'id': 'Label_pocket', 'name': 'Pocket/Keep'},
          ],
        }),
      );
      final mgr = GmailLabelManager(
        accessToken: 't',
        client: client,
        config: _prodLikeConfig,
      );
      final id = await mgr.ensurePocketLabelId();
      expect(id, 'Label_pocket');
      // No second call to createLabel — idempotent.
      expect(client.seen.length, 1);
    });

    test('ensurePocketLabelId: creates when missing', () async {
      final seq = _SequenceClient([
        (200, jsonEncode({'labels': []})),
        (200, jsonEncode({'id': 'Label_new_pocket', 'name': 'Pocket/Keep'})),
      ]);
      final mgr = GmailLabelManager(
        accessToken: 't',
        client: seq,
        config: _prodLikeConfig,
      );
      final id = await mgr.ensurePocketLabelId();
      expect(id, 'Label_new_pocket');
      expect(seq.seen.length, 2);
    });

    test('gmailTestMode: returns fake id without hitting Gmail', () async {
      final client = _CannedClient(200, '');
      final mgr = GmailLabelManager(
        accessToken: 't',
        client: client,
        config: _config, // gmailTestMode: true
      );
      final id = await mgr.ensurePocketLabelId();
      expect(id, startsWith('test-label-'));
      // No real call to Gmail.
      expect(client.seen, isEmpty);
    });
  });
}

/// Canned http.Client that captures the JSON body sent to Gmail so
/// tests can assert shape (criteria + action). Used by the
/// createFilter-body test above.
class _BodyCapturingClient extends http.BaseClient {
  String? lastBody;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastBody = request is http.Request ? request.body : null;
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'id': 'gid-new'}))),
      200,
      headers: {'content-length': '15'},
    );
  }
}

/// Minimal http.Client that returns a canned response. Records the
/// URLs it sees so tests can assert the request was actually sent.
/// Only `send` is implemented because that's all
/// `listExistingFilterIds` uses (it calls `_http.get`, which goes
/// through `send`). Lives at file scope so the group tests can
/// reference it without Dart's lexical-scope surprise.
class _CannedClient extends http.BaseClient {
  _CannedClient(this.statusCode, this.body);
  final int statusCode;
  final String body;
  final List<Uri> seen = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      statusCode,
      headers: {'content-length': body.length.toString()},
    );
  }
}

/// Returns a different canned response per call. Used when the unit
/// under test makes sequential requests (e.g. list → create).
class _SequenceClient extends http.BaseClient {
  _SequenceClient(this.responses);
  final List<(int statusCode, String body)> responses;
  final List<Uri> seen = [];
  int _i = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request.url);
    final (status, body) =
        _i < responses.length ? responses[_i++] : responses.last;
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
      headers: {'content-length': body.length.toString()},
    );
  }
}

/// Same fields as _config but with gmailTestMode: false — exercises
/// the real HTTP path in [GmailLabelManager].
const _prodLikeConfig = ServerConfig(
  gcpProject: 'test',
  pubsubTopic: 't',
  webClientId: 'w',
  webClientSecret: 's',
  pubsubAudience: 'a',
  apiTokenSecret: 'unit-test-secret',
  tokenEncryptionKey:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  gmailTestMode: false,
  oauthTestMode: true,
  fcmDryRun: true,
  fcmProjectId: 'test',
);
