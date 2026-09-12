import 'package:pocket_server/auth.dart';
import 'package:pocket_server/envelope_delete.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:pocket_server/config.dart';
import 'package:shelf/shelf.dart';
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

class _FakeStore implements EnvelopeStore {
  _FakeStore({this.envelope});
  final Map<String, dynamic>? envelope;
  int deleteCalls = 0;
  int getCalls = 0;

  @override
  Future<void> init() async {}

  @override
  Future<Map<String, dynamic>?> get(String messageId) async {
    getCalls++;
    return envelope;
  }

  @override
  Future<void> delete(String messageId) async {
    deleteCalls++;
  }

  @override
  Future<void> put(
    String messageId,
    Map<String, String> envelope, {
    required String sub,
    required DateTime date,
    Duration ttl = const Duration(hours: 24),
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> listSince(DateTime since) async => const [];
}

Request _bearer(String token, {String? messageId}) {
  final uri = Uri.parse('http://test/envelope${messageId != null ? '?messageId=$messageId' : ''}');
  return Request('DELETE', uri, headers: {'authorization': 'Bearer $token'});
}

void main() {
  final auth = TokenAuth(apiTokenSecret: _config.apiTokenSecret);
  final ownerToken =
      auth.signApiToken(sub: 'owner-sub', ttl: const Duration(hours: 1));
  final otherToken =
      auth.signApiToken(sub: 'other-sub', ttl: const Duration(hours: 1));

  test('returns 401 without bearer', () async {
    final h = envelopeDeleteHandler(_config, auth, _FakeStore());
    final r = await h(Request('DELETE', Uri.parse('http://test/envelope?messageId=x')));
    expect(r.statusCode, 401);
  });

  test('returns 400 when messageId missing', () async {
    final h = envelopeDeleteHandler(_config, auth, _FakeStore());
    final r = await h(_bearer(ownerToken));
    expect(r.statusCode, 400);
  });

  test('returns 200 + deletes when caller owns the envelope', () async {
    final store = _FakeStore(envelope: {
      'messageId': 'm1',
      'sub': 'owner-sub',
      'from': '', 'subject': '', 'text': '', 'date': '2026-09-07T00:00:00Z',
    });
    final h = envelopeDeleteHandler(_config, auth, store);
    final r = await h(_bearer(ownerToken, messageId: 'm1'));
    expect(r.statusCode, 200);
    expect(store.deleteCalls, 1);
  });

  test('returns 403 when caller does not own the envelope', () async {
    final store = _FakeStore(envelope: {
      'messageId': 'm1',
      'sub': 'owner-sub',
      'from': '', 'subject': '', 'text': '', 'date': '2026-09-07T00:00:00Z',
    });
    final h = envelopeDeleteHandler(_config, auth, store);
    final r = await h(_bearer(otherToken, messageId: 'm1'));
    expect(r.statusCode, 403);
    expect(store.deleteCalls, 0);
  });

  test('returns 200 already-gone when envelope is null (TTL cleared it)', () async {
    final store = _FakeStore(envelope: null);
    final h = envelopeDeleteHandler(_config, auth, store);
    final r = await h(_bearer(ownerToken, messageId: 'm1'));
    expect(r.statusCode, 200);
    expect(await r.readAsString(), 'already-gone');
    expect(store.deleteCalls, 0);
  });
}
