import 'dart:convert';

import 'package:pocket_server/auth.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/crypto.dart';
import 'package:pocket_server/fcm.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:pocket_server/gmail_fetch.dart';
import 'package:pocket_server/gmail_filter_rules.dart';
import 'package:pocket_server/gmail_watch.dart';
import 'package:pocket_server/mime.dart';
import 'package:pocket_server/pubsub_handler.dart';
import 'package:pocket_server/token_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// In-memory envelope store. Mirrors the fake in sync_test.dart; we
/// keep the two independent because the implementations will drift
/// (e.g. listSince ordering differs between tests) and it's clearer
/// to read each in isolation.
class _FakeEnvelopeStore implements EnvelopeStore {
  _FakeEnvelopeStore();

  final Map<String, Map<String, dynamic>> _envelopes = {};
  final List<({String messageId, Map<String, String> env, DateTime date})>
      putCalls = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> put(
    String messageId,
    Map<String, String> envelope, {
    required String sub,
    required DateTime date,
    Duration ttl = const Duration(hours: 24),
  }) async {
    putCalls.add((messageId: messageId, env: Map.of(envelope), date: date));
    _envelopes[messageId] = {
      'messageId': messageId,
      'sub': sub,
      'from': envelope['from'] ?? '',
      'subject': envelope['subject'] ?? '',
      'text': envelope['text'] ?? '',
      'date': date.toUtc().toIso8601String(),
    };
  }

  @override
  Future<Map<String, dynamic>?> get(String messageId) async =>
      _envelopes[messageId];

  @override
  Future<void> delete(String messageId) async {
    _envelopes.remove(messageId);
  }

  @override
  Future<List<Map<String, dynamic>>> listSince(DateTime since) async =>
      _envelopes.values.toList(growable: false);
}

/// Fakes the Gmail API without touching the network. Subclass so
/// we inherit `config` and avoid re-implementing the surface area
/// the handler uses (withAccessToken / messagesSince / fetchEnvelope).
class _FakeGmailFetcher extends GmailFetcher {
  _FakeGmailFetcher(
    super.config, {
    required this.envelopes,
  }) : _messageIds = null;

  final List<EmailEnvelope> envelopes;
  final List<String>? _messageIds;

  @override
  Future<T> withAccessToken<T>(String token, Future<T> Function() body) =>
      body();

  @override
  Future<List<String>> messagesSince(String startHistoryId) async =>
      _messageIds ?? envelopes.map((e) => e.messageId).toList();

  @override
  Future<EmailEnvelope> fetchEnvelope(String messageId) async =>
      envelopes.firstWhere((e) => e.messageId == messageId);
}

/// Records every FCM publish instead of calling Google. Stands in
/// for FcmPublisher because the real one talks to FCM v1 in init()
/// and publishToTokens(), which we can't reach from unit tests.
class _FakeFcm extends FcmPublisher {
  _FakeFcm({required super.config});
  final List<({String sub, List<String> tokens, Map<String, String> data})> publishes = [];

  @override
  Future<void> publishToTokens({
    required String sub,
    required Iterable<String> tokens,
    required Map<String, String> data,
  }) async {
    publishes.add((sub: sub, tokens: tokens.toList(), data: Map.of(data)));
  }
}

/// Records watch re-registrations. Lets tests assert the self-heal
/// path actually calls users.watch with the newly-created label id.
class _FakeWatchRegistrar extends GmailWatchRegistrar {
  _FakeWatchRegistrar({required super.config, required super.tokens});
  final List<({String sub, String? pocketLabelId, String refreshToken})>
      refreshes = [];

  @override
  Future<void> refresh(
    String sub,
    String refreshTokenPlain, {
    String? pocketLabelId,
  }) async {
    refreshes.add((
      sub: sub,
      pocketLabelId: pocketLabelId,
      refreshToken: refreshTokenPlain,
    ));
  }
}

const _config = ServerConfig(
  gcpProject: 'test-project',
  pubsubTopic: 'gmail-history',
  webClientId: 'web',
  webClientSecret: 'web',
  pubsubAudience: 'https://test/pubsub/push',
  apiTokenSecret: 'unit-test-secret-do-not-use-in-prod',
  tokenEncryptionKey:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  // gmailTestMode=true: canned JWT verify bypass (`test-...` prefix),
  // fetchEnvelope reads canned-history.json (we use _FakeGmailFetcher
  // instead). The flag is required for the JWT skip path so we don't
  // touch googleapis.com for certs.
  gmailTestMode: true,
  oauthTestMode: true,
  fcmDryRun: true,
  fcmProjectId: 'test-project',
);

const _cipherKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Future<({InMemoryTokenStore tokens, TokenCipher cipher, String sub})>
    _seedAccount() async {
  final cipher = TokenCipher(_cipherKey);
  final tokens = InMemoryTokenStore();
  const sub = '1234567890';
  await tokens.put(
    sub,
    AccountRecord(
      sub: sub,
      refreshToken: await cipher.seal('test-refresh-token'),
      email: 'medisujith@gmail.com',
      lastWatchAt: DateTime.utc(2026, 9, 5),
      lastHistoryId: '1',
      // FCM token registered by a fake client — without this, the
      // token-based publisher skips every push (empty-list warning).
      fcmTokens: {'test-fcm-token-1'},
    ),
  );
  return (tokens: tokens, cipher: cipher, sub: sub);
}

Request _pubsubPush({
  required String email,
  required String historyId,
  String jwt = 'test-jwt',
}) {
  // Real Pub/Sub encodes its data field as base64(json(payload)).
  // Mirror that here so the handler's base64-decode path is exercised.
  final data = base64.encode(
      utf8.encode(jsonEncode({'emailAddress': email, 'historyId': historyId})));
  final body = jsonEncode({'message': {'data': data}});
  return Request(
    'POST',
    Uri.parse('http://test/pubsub/push'),
    headers: {
      'authorization': 'Bearer $jwt',
      'content-type': 'application/json',
    },
    body: body,
  );
}

EmailEnvelope _env(String messageId, String text) => EmailEnvelope(
      messageId: messageId,
      from: 'service@paypal.com',
      subject: 'You spent money',
      date: DateTime.utc(2026, 9, 5, 12),
      text: text,
    );

/// In-memory [FilterRuleStore] for handler tests. Lets each test pin
/// the user's filter rules without spinning up Firestore.
class _FakeRuleStore implements FilterRuleStore {
  FilterRuleSet _set = FilterRuleSet.defaults;

  @override
  Future<void> init() async {}

  @override
  Future<FilterRuleSet?> get(String sub) async => _set;

  @override
  Future<void> put(String sub, FilterRuleSet set) async {
    _set = set;
  }

  @override
  Future<void> remove(String sub) async {
    _set = FilterRuleSet.defaults;
  }
}

void main() {
  group('pubsubHandler size check', () {
    test('small envelope publishes inline data, no Firestore write',
        () async {
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-small', 'A short receipt for \$5.00')],
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);

      // Fast path: one inline publish AND one Firestore write — every
      // envelope is persisted now so the phone has a pull fallback
      // when FCM topic delivery drops a message.
      expect(envelopes.putCalls.length, 1);
      expect(envelopes.putCalls.first.messageId, 'msg-small');
      expect(fcm.publishes.length, 1);
      expect(fcm.publishes.first.tokens, ['test-fcm-token-1']);
      expect(fcm.publishes.first.data, {
        'messageId': 'msg-small',
        'emailFrom': 'service@paypal.com',
        'subject': 'You spent money',
        'date': '2026-09-05T12:00:00.000Z',
        'text': 'A short receipt for \$5.00',
      });
      expect(fcm.publishes.first.data.containsKey('truncated'), isFalse);
    });

    test('oversized envelope writes to Firestore + publishes truncated marker',
        () async {
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      // 6 KB of text — well past the 3500-byte FCM data limit once
      // JSON wrapping, topic name, and field names are added.
      final huge = 'X' * 6000;
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-big', huge)],
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);

      // Slow path: Firestore gets the full body, FCM gets a marker.
      expect(envelopes.putCalls.length, 1);
      expect(envelopes.putCalls.first.messageId, 'msg-big');
      expect(envelopes.putCalls.first.env['text'], huge);
      expect(envelopes.putCalls.first.env['from'], 'service@paypal.com');
      expect(envelopes.putCalls.first.env['subject'], 'You spent money');

      expect(fcm.publishes.length, 1);
      expect(fcm.publishes.first.tokens, ['test-fcm-token-1']);
      expect(fcm.publishes.first.data, {
        'messageId': 'msg-big',
        'truncated': 'true',
      });
    });

    test('mixed batch: small envelopes publish inline, big ones fallback',
        () async {
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [
          _env('msg-small-1', 'tiny receipt'),
          _env('msg-big-1', 'Y' * 6000),
          _env('msg-small-2', 'another tiny receipt'),
        ],
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);

      // Two inline publishes (small) + one truncated marker (big).
      // Every envelope is persisted to Firestore — two small + one big
      // = three writes — so the phone can pull via /sync?since=...
      // if any FCM topic message gets dropped.
      expect(envelopes.putCalls.length, 3);
      expect(
        envelopes.putCalls.map((c) => c.messageId).toList()..sort(),
        ['msg-big-1', 'msg-small-1', 'msg-small-2'],
      );
      expect(fcm.publishes.length, 3);
      expect(
        fcm.publishes
            .where((p) => p.data.containsKey('truncated'))
            .map((p) => p.data['messageId']),
        ['msg-big-1'],
      );
      expect(
        fcm.publishes
            .where((p) => !p.data.containsKey('truncated'))
            .map((p) => p.data['messageId'])
            .toList(),
        ['msg-small-1', 'msg-small-2'],
      );
    });

    test('Firestore write failure still publishes truncated marker',
        () async {
      final seed = await _seedAccount();
      final envelopes = _ThrowingEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-big', 'Z' * 6000)],
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      // Handler returns 200 even when Firestore write fails — we
      // still publish the truncated marker so the user sees
      // something rather than nothing.
      expect(r.statusCode, 200);
      expect(fcm.publishes.length, 1);
      expect(fcm.publishes.first.data, {
        'messageId': 'msg-big',
        'truncated': 'true',
      });
    });
  });

  group('pubsubHandler server-side filter enforcement', () {
    test(
        'filter enabled, rule matches subject → envelope published '
        '(happy path)',
        () async {
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [
          EmailEnvelope(
            messageId: 'msg-abc',
            from: 'service@paypal.com',
            subject: 'abc receipt',
            date: DateTime.utc(2026, 9, 5, 12),
            text: 'You spent \$10',
          ),
        ],
      );
      final rules = _FakeRuleStore();
      await rules.put(
        seed.sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: const [
            FilterRule(
              subject: RuleField(value: 'abc', matchType: MatchType.contains),
            ),
          ],
        ),
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        rules: rules,
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);
      // "abc receipt" matches → published.
      expect(fcm.publishes, hasLength(1));
      expect(fcm.publishes.first.data['subject'], 'abc receipt');
      expect(envelopes.putCalls, hasLength(1));
    });

    test(
        'filter enabled, no rule matches → envelope DROPPED, no FCM, '
        'no Firestore write',
        () async {
      // Regression guard for "testuf" reaching the app while the
      // filter was set to "abc". Before this fix, the handler
      // ignored the rule set and pushed every Gmail change to the
      // phone — the filter did nothing visible.
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [
          EmailEnvelope(
            messageId: 'msg-testuf',
            from: 'random@friend.com',
            subject: 'testuf',
            date: DateTime.utc(2026, 9, 5, 12),
            text: 'hi how are you',
          ),
        ],
      );
      final ruleStore = _FakeRuleStore();
      await ruleStore.put(
        seed.sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: const [
            FilterRule(
              subject: RuleField(value: 'abc', matchType: MatchType.contains),
            ),
          ],
        ),
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        rules: ruleStore,
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);
      // "testuf" doesn't match "abc" → silently dropped.
      expect(fcm.publishes, isEmpty);
      expect(envelopes.putCalls, isEmpty);
    });

    test('filter disabled → defaults to "capture everything"',
        () async {
      // enabled=false is the documented "process every Gmail
        // message" default for users who haven't touched Email filters.
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-anything', 'hi')],
      );
      final ruleStore = _FakeRuleStore();
      await ruleStore.put(seed.sub, FilterRuleSet.defaults);

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        rules: ruleStore,
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);
      expect(fcm.publishes, hasLength(1));
    });

    test('mix of matching + non-matching: each handled independently',
        () async {
      final seed = await _seedAccount();
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [
          EmailEnvelope(
            messageId: 'msg-abc-1',
            from: 'x@y.com',
            subject: 'abc one',
            date: DateTime.utc(2026, 9, 5, 12),
            text: 'first',
          ),
          EmailEnvelope(
            messageId: 'msg-other',
            from: 'x@y.com',
            subject: 'unrelated',
            date: DateTime.utc(2026, 9, 5, 13),
            text: 'second',
          ),
          EmailEnvelope(
            messageId: 'msg-abc-2',
            from: 'x@y.com',
            subject: 'abc two',
            date: DateTime.utc(2026, 9, 5, 14),
            text: 'third',
          ),
        ],
      );
      final ruleStore = _FakeRuleStore();
      await ruleStore.put(
        seed.sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: const [
            FilterRule(
              subject: RuleField(value: 'abc', matchType: MatchType.contains),
            ),
          ],
        ),
      );

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        rules: ruleStore,
      );

      await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));

      // Only the two "abc" messages reach the phone; the unrelated
      // one is dropped silently.
      final subjects = fcm.publishes.map((p) => p.data['subject']).toList();
      expect(subjects, ['abc one', 'abc two']);
      expect(envelopes.putCalls.length, 2);
    });
  });

  group('pubsubHandler self-heal: legacy accounts get Pocket label', () {
    test(
        'account with pocketLabelId=null → label created, message '
        'still processed, watch reconciled to INBOX (no Gmail filters yet)',
        () async {
      // Regression guard: accounts that signed in before the label
      // scheme shipped have pocketLabelId=null. We MUST create the
      // label on the first push after deploy so future /filters/sync
      // calls can use it as a filter action. The watch mode is
      // derived from rule state — with no Gmail-mirrored rules yet
      // (test seeds with empty rule set), the watch stays on INBOX
      // so every email flows through and server-side allows()
      // decides. Once the user saves a /filters/sync with mirrored
      // rules, the next push flips watch to Pocket-label mode.
      final seed = await _seedAccount();
      // Manually null out the label id to simulate a legacy account.
      final legacy = await seed.tokens.get(seed.sub);
      expect(legacy!.pocketLabelId, isNull,
          reason: 'test seed should mimic a legacy account');
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-1', 'matched email body')],
      );
      final watch = _FakeWatchRegistrar(config: _config, tokens: seed.tokens);

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        watch: watch,
      );

      final r = await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      expect(r.statusCode, 200);
      // Message processed normally.
      expect(fcm.publishes, hasLength(1));
      // Watch reconciled — but to INBOX (no Gmail-mirrored rules).
      expect(watch.refreshes, hasLength(1));
      expect(watch.refreshes.single.sub, seed.sub);
      expect(watch.refreshes.single.pocketLabelId, isNull);
      // Account updated with the new label id so the next push
      // skips the heal path.
      final updated = await seed.tokens.get(seed.sub);
      expect(updated!.pocketLabelId, isNotNull);
    });

    test('account with pocketLabelId set, no rules → watch reconciled to INBOX',
        () async {
      final seed = await _seedAccount();
      // Pretend the account already has a label id.
      final cur = await seed.tokens.get(seed.sub);
      await seed.tokens.put(
        seed.sub,
        cur!.copyWith(pocketLabelId: 'Label_existing'),
      );
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-1', 'body')],
      );
      final watch = _FakeWatchRegistrar(config: _config, tokens: seed.tokens);

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        watch: watch,
      );

      await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      // Watch IS touched (reconciliation runs on every push), but
      // the mode is INBOX because no Gmail-mirrored rules exist.
      expect(watch.refreshes, hasLength(1));
      expect(watch.refreshes.single.pocketLabelId, isNull);
      // Label id on account is unchanged — we don't null it out,
      // we just don't pass it to watch when in INBOX mode.
      final after = await seed.tokens.get(seed.sub);
      expect(after!.pocketLabelId, 'Label_existing');
    });

    test(
        'account with pocketLabelId + Gmail-mirrored rules → watch '
        'reconciled to label mode',
        () async {
      // Regression guard: the architectural promise is "Pub/Sub
      // only fires for matching emails when the user has Gmail-side
      // filters." This test verifies that when the rule store has
      // rules with non-null ids (i.e. mirrored to Gmail filters),
      // the watch switches to Pocket-label mode.
      final seed = await _seedAccount();
      final cur = await seed.tokens.get(seed.sub);
      await seed.tokens.put(
        seed.sub,
        cur!.copyWith(pocketLabelId: 'Label_existing'),
      );
      final rules = _FakeRuleStore();
      await rules.put(
        seed.sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            FilterRule(
              id: 'gid-paypal',
              sender: const RuleField(
                  value: 'paypal.com', matchType: MatchType.contains),
            ),
          ],
        ),
      );
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-1', 'body')],
      );
      final watch = _FakeWatchRegistrar(config: _config, tokens: seed.tokens);

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        watch: watch,
        rules: rules,
      );

      await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      // Watch mode flipped to label — that's the optimization that
      // makes Pub/Sub only fire for matching emails.
      expect(watch.refreshes, hasLength(1));
      expect(watch.refreshes.single.pocketLabelId, 'Label_existing');
    });

    test(
        'account with mix of mirrored + regex rules → watch stays '
        'on INBOX (regex needs server-side filter)',
        () async {
      // Regression guard: regex rules can't be translated to Gmail
      // criteria, so Gmail-side filtering would miss them. INBOX
      // mode lets the server's allows() catch regex matches. If we
      // flipped to label mode here, the regex rule's matching emails
      // would never fire Pub/Sub and the user would silently miss
      // them.
      final seed = await _seedAccount();
      final cur = await seed.tokens.get(seed.sub);
      await seed.tokens.put(
        seed.sub,
        cur!.copyWith(pocketLabelId: 'Label_existing'),
      );
      final rules = _FakeRuleStore();
      await rules.put(
        seed.sub,
        FilterRuleSet(
          enabled: true,
          logic: Logic.or,
          rules: [
            // Mirrored: has Gmail id.
            FilterRule(
              id: 'gid-paypal',
              sender: const RuleField(
                  value: 'paypal.com', matchType: MatchType.contains),
            ),
            // Regex: cannot be mirrored → id stays null.
            FilterRule(
              sender: const RuleField(
                  value: r'.*@stripe\.com', matchType: MatchType.regex),
            ),
          ],
        ),
      );
      final envelopes = _FakeEnvelopeStore();
      final fcm = _FakeFcm(config: _config);
      final fetcher = _FakeGmailFetcher(
        _config,
        envelopes: [_env('msg-1', 'body')],
      );
      final watch = _FakeWatchRegistrar(config: _config, tokens: seed.tokens);

      final h = pubsubHandler(
        _config,
        seed.tokens,
        const MimeExtractor(),
        TokenAuth(apiTokenSecret: _config.apiTokenSecret),
        seed.cipher,
        fcm,
        fetcher,
        envelopes,
        mintAccessToken: (_) async => 'fake-access-token',
        watch: watch,
        rules: rules,
      );

      await h(_pubsubPush(
          email: 'medisujith@gmail.com', historyId: '42'));
      // Watch stays on INBOX because not all rules are mirrored.
      expect(watch.refreshes, hasLength(1));
      expect(watch.refreshes.single.pocketLabelId, isNull);
    });
  });
}

/// Variant of _FakeEnvelopeStore that throws on put — used to verify
/// the handler's "Firestore failed → still publish marker" guard.
class _ThrowingEnvelopeStore implements EnvelopeStore {
  _ThrowingEnvelopeStore();

  @override
  Future<void> init() async {}

  @override
  Future<void> put(
    String messageId,
    Map<String, String> envelope, {
    required String sub,
    required DateTime date,
    Duration ttl = const Duration(hours: 24),
  }) async {
    throw StateError('firestore down');
  }

  @override
  Future<Map<String, dynamic>?> get(String messageId) async => null;

  @override
  Future<void> delete(String messageId) async {}

  @override
  Future<List<Map<String, dynamic>>> listSince(DateTime since) async => const [];
}