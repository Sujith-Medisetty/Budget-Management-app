import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pocket/data/services/gmail_auth.dart';
import 'package:pocket/data/services/gmail_filter_rules.dart';
import 'package:pocket/data/services/rule_sync_service.dart';

/// Captures requests and returns a canned response. Lets tests assert
/// what the service POSTed without a real network.
class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.responder);
  final ResponseBody Function(RequestOptions options, _CannedAdapter self)
      responder;
  Duration delay = Duration.zero;

  final List<RequestOptions> sent = [];
  int callCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    sent.add(options);
    callCount++;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return responder(options, this);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok(Map<String, dynamic> json) => ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );

/// Implements the GmailAuth surface but only really uses tryRestore().
class _FakeAuth implements GmailAuth {
  @override
  Future<String?> tryRestore() async => 'test-token';
  @override
  Future<String?> apiToken() async => 'test-token';
  @override
  Future<void> bootstrapDevice() async {}
  @override
  Future<String?> signIn() async => null;
  @override
  Future<void> signOut() async {}
  @override
  Future<String?> signedInEmail() async => null;
  @override
  Future<void> wipeAndReset() async {}
  @override
  Future<void> registerDevice(String apiToken) async {}
  @override
  Future<void> bootstrapFirebaseAuth() async {}
}

FilterRuleSet _buildSet({String? gmailId, String sender = 'paypal'}) {
  return FilterRuleSet(
    enabled: true,
    logic: Logic.or,
    rules: [
      FilterRule(
        id: gmailId,
        sender: RuleField(value: sender, matchType: MatchType.contains),
      ),
    ],
  );
}

Map<String, dynamic> _serverResponse(FilterRuleSet merged) => {
      'rules': jsonEncode(merged.toJson()),
    };

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('RuleSyncService.saveNow', () {
    test('on success, calls onSynced with server-merged set including Gmail-ids',
        () async {
      final cannedMerged = _buildSet(gmailId: 'gid-abc');
      final adapter =
          _CannedAdapter((_, _) => _ok(_serverResponse(cannedMerged)));
      final dio = Dio()..httpClientAdapter = adapter;
      FilterRuleSet? receivedMerged;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        onSynced: (m) => receivedMerged = m,
      );
      final ok = await svc.saveNow(_buildSet());
      expect(ok, isTrue);
      expect(adapter.callCount, 1);
      expect(receivedMerged, isNotNull);
      expect(receivedMerged!.rules.single.id, 'gid-abc');
    });

    test('Save always hits the API even when payload matches what was '
        'last synced (no silent short-circuit)', () async {
      // Save is an explicit user gesture. The user expects every
      // click to commit to the server — if the rules happen to
      // match what was last sent, that's not a reason to no-op.
      // A silent skip leaves the user wondering whether the save
      // actually persisted (especially after editing on the web),
      // and was the source of the "save is not happening properly"
      // bug reports.
      final adapter =
          _CannedAdapter((_, _) => _ok(_serverResponse(_buildSet())));
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = RuleSyncService(auth: _FakeAuth(), http: dio);
      final first = await svc.saveNow(_buildSet());
      expect(first, isTrue);
      expect(adapter.callCount, 1);
      final second = await svc.saveNow(_buildSet());
      expect(second, isTrue);
      expect(adapter.callCount, 2,
          reason: 'matching payload must NOT short-circuit — Save is '
              'an explicit user gesture, always commit');
    });

    test('server returning 500 -> saveNow returns false, no onSynced fire',
        () async {
      final adapter = _CannedAdapter((_, _) => ResponseBody.fromString(
            'oops',
            500,
            headers: const {
              'content-type': ['text/plain'],
            },
          ));
      final dio = Dio()..httpClientAdapter = adapter;
      var synced = false;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        onSynced: (_) => synced = true,
      );
      final ok = await svc.saveNow(_buildSet());
      expect(ok, isFalse);
      expect(synced, isFalse);
    });

    test('saveNow while another sync is in flight waits and returns true',
        () async {
      final adapter = _CannedAdapter((_, self) {
        self.delay = const Duration(milliseconds: 200);
        return _ok(_serverResponse(_buildSet(gmailId: 'gid-first')));
      });
      final dio = Dio()..httpClientAdapter = adapter;
      var syncedCount = 0;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        onSynced: (_) => syncedCount++,
      );
      final first = svc.saveNow(_buildSet());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = svc.saveNow(_buildSet(sender: 'amazon'));
      final results = await Future.wait([first, second]);
      expect(results, [true, true],
          reason: 'first runs, second waits then runs to completion');
      expect(syncedCount, greaterThanOrEqualTo(1));
    });

    test('saveNow during in-flight sync: if in-flight FAILS, '
        'saveNow returns false (no false success)', () async {
      // First sync will fail (500). Second sync runs after the first
      // drains; the second's rules differ so it also runs and we
      // expect THAT one to succeed. But the FIRST saveNow()'s return
      // value must reflect the first sync's actual failure — not
      // claim success because the second sync was queued.
      var calls = 0;
      final adapter = _CannedAdapter((_, _) {
        calls++;
        // First call (in-flight): server error → fail
        // Second call (after drain): success
        if (calls == 1) {
          return ResponseBody.fromString(
            'oops',
            500,
            headers: const {'content-type': ['text/plain']},
          );
        }
        return _ok(_serverResponse(_buildSet(gmailId: 'gid-second')));
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = RuleSyncService(auth: _FakeAuth(), http: dio);
      final firstResult = svc.saveNow(_buildSet());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final secondResult = svc.saveNow(_buildSet(sender: 'amazon'));
      final results = await Future.wait([firstResult, secondResult]);
      expect(results[0], isFalse,
          reason: 'first saveNow must reflect the 500, not silent success');
      expect(results[1], isTrue,
          reason: 'second saveNow runs after drain with its own rules');
    });

    test('saveNow during in-flight sync that succeeds: new rules '
        'still get sent (no stale-snapshot bug)', () async {
      // In-flight sync saves rules with sender=paypal, takes 200ms.
      // Mid-flight, the user changes their mind and saves sender=amazon.
      // After the in-flight completes, saveNow should resync with
      // amazon — not skip because _lastSyncedJson already matches
      // a stale rules snapshot.
      final adapter = _CannedAdapter((_, self) {
        self.delay = const Duration(milliseconds: 200);
        // Echo back whatever rules were sent, with a stable gmailId.
        return _ok(_serverResponse(_buildSet(gmailId: 'gid-echo')));
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = RuleSyncService(auth: _FakeAuth(), http: dio);
      final first = svc.saveNow(_buildSet(sender: 'paypal'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final second = svc.saveNow(_buildSet(sender: 'amazon'));
      final results = await Future.wait([first, second]);
      expect(results, [true, true]);
      // Two distinct POSTs — both rules reached the server.
      expect(adapter.callCount, 2);
      final firstSent = adapter.sent[0].data as Map;
      final secondSent = adapter.sent[1].data as Map;
      expect((firstSent['rules'] as String), contains('paypal'));
      expect((secondSent['rules'] as String), contains('amazon'));
    });

    test('saveNow during a fast in-flight sync waits and then runs '
        '(no timeout when in-flight finishes in time)', () async {
      final adapter = _CannedAdapter((_, self) {
        self.delay = const Duration(milliseconds: 50);
        return _ok(_serverResponse(_buildSet(gmailId: 'gid-fast')));
      });
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        waitForInFlightTimeout: const Duration(seconds: 5),
      );
      final first = svc.saveNow(_buildSet());
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final second = svc.saveNow(_buildSet(sender: 'amazon'));
      final results = await Future.wait([first, second]);
      expect(results, [true, true]);
      expect(adapter.callCount, 2);
    });
  });

  group('RuleSyncService.refresh', () {
    test('on success, calls onSynced with the server-cleaned set',
        () async {
      final cannedCleaned = _buildSet(gmailId: 'gid-abc');
      final adapter =
          _CannedAdapter((_, _) => _ok(_serverResponse(cannedCleaned)));
      final dio = Dio()..httpClientAdapter = adapter;
      FilterRuleSet? received;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        onSynced: (m) => received = m,
      );
      final ok = await svc.refresh();
      expect(ok, isTrue);
      expect(adapter.callCount, 1, reason: 'one GET request');
      expect(adapter.sent.single.method, 'GET');
      expect(received?.rules.single.id, 'gid-abc');
    });

    test('user not signed in → false without a network call', () async {
      final adapter = _CannedAdapter((_, _) => _ok(_serverResponse(_buildSet())));
      final dio = Dio()..httpClientAdapter = adapter;
      final svc = RuleSyncService(
        auth: _NoTokenAuth(),
        http: dio,
      );
      final ok = await svc.refresh();
      expect(ok, isFalse);
      expect(adapter.callCount, 0);
    });

    test('server returning 502 → refresh returns false, no onSynced fire',
        () async {
      final adapter = _CannedAdapter((_, _) => ResponseBody.fromString(
            'gmail down',
            502,
            headers: const {'content-type': ['text/plain']},
          ));
      final dio = Dio()..httpClientAdapter = adapter;
      var synced = false;
      final svc = RuleSyncService(
        auth: _FakeAuth(),
        http: dio,
        onSynced: (_) => synced = true,
      );
      final ok = await svc.refresh();
      expect(ok, isFalse);
      expect(synced, isFalse);
    });
  });
}

class _NoTokenAuth implements GmailAuth {
  @override
  Future<String?> tryRestore() async => null;
  @override
  Future<String?> apiToken() async => null;
  @override
  Future<void> bootstrapDevice() async {}
  @override
  Future<String?> signIn() async => null;
  @override
  Future<void> signOut() async {}
  @override
  Future<String?> signedInEmail() async => null;
  @override
  Future<void> wipeAndReset() async {}
  @override
  Future<void> registerDevice(String apiToken) async {}
  @override
  Future<void> bootstrapFirebaseAuth() async {}
}
