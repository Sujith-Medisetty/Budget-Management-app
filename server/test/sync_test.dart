import 'dart:convert';

import 'package:pocket_server/auth.dart';
import 'package:pocket_server/config.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:pocket_server/sync.dart';
import 'package:pocket_server/token_store.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

/// In-memory envelope store for tests. Implements the abstract
/// EnvelopeStore interface so we can swap it in without spinning up
/// Postgres.
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
  Future<List<Map<String, dynamic>>> listSince(DateTime since) async {
    final out = <Map<String, dynamic>>[];
    for (final e in _envelopes.values) {
      if (DateTime.parse(e['date'] as String).isAfter(since)) {
        out.add(e);
      }
    }
    out.sort((a, b) => (a['date'] as String).compareTo(b['date'] as String));
    return out;
  }

  @override
  Future<void> delete(String messageId) async {
    _envelopes.remove(messageId);
  }
}

const _testConfig = ServerConfig(
  gcpProject: 'test-project',
  pubsubTopic: 'gmail-history',
  webClientId: 'web-client-id',
  webClientSecret: 'web-client-secret',
  pubsubAudience: 'https://test.example.com/pubsub/push',
  apiTokenSecret: 'unit-test-secret-do-not-use-in-prod',
  tokenEncryptionKey:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  // gmailTestMode=false forces the handler onto the real (fake-store)
  // path. Canned mode short-circuits everything for local dev.
  gmailTestMode: false,
  oauthTestMode: true,
  fcmDryRun: true,
  fcmProjectId: 'test-project',
);

const _apiSecret = 'unit-test-secret-do-not-use-in-prod';

class _Seed {
  _Seed({required this.apiToken, required this.tokens, required this.auth});
  final String apiToken;
  final InMemoryTokenStore tokens;
  final TokenAuth auth;
}

Future<_Seed> _seedAccount() async {
  final tokens = InMemoryTokenStore();
  final auth = TokenAuth(apiTokenSecret: _apiSecret);
  await tokens.put(
    '1234567890',
    AccountRecord(
      sub: '1234567890',
      refreshToken: 'refresh-token',
      email: 'medisujith@gmail.com',
      lastWatchAt: DateTime.utc(2026, 9, 5),
      lastHistoryId: '1',
    ),
  );
  final apiToken = auth.signApiToken(
    sub: '1234567890',
    ttl: const Duration(days: 1),
  );
  return _Seed(apiToken: apiToken, tokens: tokens, auth: auth);
}

Request _authedRequest(
  String path, {
  required String apiToken,
}) {
  return Request(
    'GET',
    Uri.parse('http://test/sync$path'),
    headers: {'authorization': 'Bearer $apiToken'},
  );
}

Future<Map<String, dynamic>> _decodeBody(Response r) async =>
    jsonDecode(await r.readAsString()) as Map<String, dynamic>;

void main() {
  group('syncSince', () {
    test('returns 401 without bearer token', () async {
      final s = _FakeEnvelopeStore();
      final h = syncSince(
        _testConfig,
        InMemoryTokenStore(),
        TokenAuth(apiTokenSecret: _apiSecret),
        s,
      );
      final r = await h(Request('GET', Uri.parse('http://test/sync')));
      expect(r.statusCode, 401);
    });

    test('returns 401 for unknown account', () async {
      final s = _FakeEnvelopeStore();
      final auth = TokenAuth(apiTokenSecret: _apiSecret);
      final apiToken = auth.signApiToken(
        sub: 'no-such-sub',
        ttl: const Duration(days: 1),
      );
      final h = syncSince(_testConfig, InMemoryTokenStore(), auth, s);
      final r = await h(_authedRequest('', apiToken: apiToken));
      expect(r.statusCode, 401);
    });

    test('GET /sync?messageId=<id> returns the envelope', () async {
      final s = _FakeEnvelopeStore();
      final seed = await _seedAccount();
      final date = DateTime.utc(2026, 9, 5, 20, 30);
      await s.put(
        'msg-abc',
        {
          'from': 'service@paypal.com',
          'subject': 'You spent \$29.99',
          'text': 'You spent \$29.99 USD at Amazon.'
        },
        sub: '1234567890',
        date: date,
      );
      final h = syncSince(_testConfig, seed.tokens, seed.auth, s);
      final r = await h(_authedRequest(
        '?messageId=msg-abc',
        apiToken: seed.apiToken,
      ));
      expect(r.statusCode, 200);
      final body = await _decodeBody(r);
      expect(body['envelope'], isA<Map>());
      final env = body['envelope'] as Map<String, dynamic>;
      expect(env['messageId'], 'msg-abc');
      expect(env['from'], 'service@paypal.com');
      expect(env['subject'], contains('29.99'));
      expect(env['text'], contains('29.99'));
    });

    test('GET /sync?messageId=<missing> returns 404', () async {
      final s = _FakeEnvelopeStore();
      final seed = await _seedAccount();
      final h = syncSince(_testConfig, seed.tokens, seed.auth, s);
      final r = await h(_authedRequest(
        '?messageId=does-not-exist',
        apiToken: seed.apiToken,
      ));
      expect(r.statusCode, 404);
    });

    test('GET /sync?since=<ms> returns envelopes with date > since, oldest first',
        () async {
      final s = _FakeEnvelopeStore();
      final seed = await _seedAccount();
      final base = DateTime.utc(2026, 9, 5);
      await s.put('m1', {'from': 'a@x', 'subject': 's1', 'text': 't1'},
          sub: '1234567890', date: base);
      await s.put('m2', {'from': 'b@x', 'subject': 's2', 'text': 't2'},
          sub: '1234567890', date: base.add(const Duration(hours: 1)));
      await s.put('m3', {'from': 'c@x', 'subject': 's3', 'text': 't3'},
          sub: '1234567890', date: base.add(const Duration(hours: 2)));
      final h = syncSince(_testConfig, seed.tokens, seed.auth, s);

      final since = base.add(const Duration(minutes: 30)).millisecondsSinceEpoch;
      final r = await h(_authedRequest(
        '?since=$since',
        apiToken: seed.apiToken,
      ));
      expect(r.statusCode, 200);
      final body = await _decodeBody(r);
      final envelopes =
          (body['envelopes'] as List).cast<Map<String, dynamic>>();
      expect(envelopes.map((e) => e['messageId']).toList(), ['m2', 'm3']);
    });

    test('GET /sync without query params returns all envelopes (since=0)',
        () async {
      final s = _FakeEnvelopeStore();
      final seed = await _seedAccount();
      await s.put('m1', {'from': '', 'subject': '', 'text': ''},
          sub: '1234567890', date: DateTime.utc(2026, 1, 1));
      await s.put('m2', {'from': '', 'subject': '', 'text': ''},
          sub: '1234567890', date: DateTime.utc(2026, 2, 1));
      final h = syncSince(_testConfig, seed.tokens, seed.auth, s);
      final r = await h(_authedRequest('', apiToken: seed.apiToken));
      expect(r.statusCode, 200);
      final body = await _decodeBody(r);
      final envelopes =
          (body['envelopes'] as List).cast<Map<String, dynamic>>();
      expect(envelopes.length, 2);
    });
  });
}
