import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/core/services/ai_retry.dart';

void main() {
  group('retryUntilJson', () {
    test('returns the body on first try when it parses as JSON', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          return '{"amount": 5, "merchant": "Amazon"}';
        },
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"amount": 5, "merchant": "Amazon"}');
      expect(calls, 1);
    });

    test('retries when the body is prose, then succeeds', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          if (calls < 2) return 'Here is your answer: nope.';
          return '{"ok": true}';
        },
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"ok": true}');
      expect(calls, 2);
    });

    test('retries when body is null, then succeeds', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          if (calls < 3) return null;
          return '{"ok": true}';
        },
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"ok": true}');
      expect(calls, 3);
    });

    test('retries on DioException, then succeeds', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          if (calls < 2) {
            throw DioException(
              requestOptions: RequestOptions(path: '/x'),
              message: 'transient',
            );
          }
          return '{"ok": true}';
        },
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"ok": true}');
      expect(calls, 2);
    });

    test('retries on generic exception, then succeeds', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          if (calls < 2) {
            throw StateError('socket reset');
          }
          return '{"ok": true}';
        },
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"ok": true}');
      expect(calls, 2);
    });

    test('returns null when every attempt is null', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          return null;
        },
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, isNull);
      expect(calls, 3);
    });

    test('returns null when every attempt throws', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          throw DioException(
            requestOptions: RequestOptions(path: '/x'),
            message: 'persistent',
          );
        },
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, isNull);
      expect(calls, 3);
    });

    test('returns fallback JSON when every attempt is prose', () async {
      var calls = 0;
      final body = await retryUntilJson(
        attempt: () async {
          calls++;
          return 'Sorry, I cannot help with that.';
        },
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, '{"skip": true, "error": "ai_no_json_after_retry"}');
      expect(calls, 3);
    });

    test('parses JSON wrapped in ```json fences', () async {
      final body = await retryUntilJson(
        attempt: () async =>
            '```json\n{"amount": 5, "merchant": "Amazon"}\n```',
        backoff: const Duration(milliseconds: 1),
      );
      expect(body, contains('"merchant": "Amazon"'));
    });

    test('parses JSON inside think-tag blocks (defensive)', () async {
      final body = await retryUntilJson(
        attempt: () async => '<think>reasoning</think>{"ok": true}',
        backoff: const Duration(milliseconds: 1),
      );
      // <think> tags contain "{" / "}" so the first-{ regex picks up
      // just the trailing object — which is still valid JSON.
      expect(body, contains('"ok": true'));
    });

    test('uses custom fallback JSON when supplied', () async {
      final body = await retryUntilJson(
        attempt: () async => 'not json',
        maxAttempts: 2,
        backoff: const Duration(milliseconds: 1),
        fallbackJson: '{"kind": "answer", "text": "fallback"}',
      );
      expect(body, '{"kind": "answer", "text": "fallback"}');
    });

    test('honors maxAttempts', () async {
      var calls = 0;
      await retryUntilJson(
        attempt: () async {
          calls++;
          return null;
        },
        maxAttempts: 5,
        backoff: const Duration(milliseconds: 1),
      );
      expect(calls, 5);
    });

    test('uses exponential backoff (1x, 2x, 3x of base)', () async {
      var calls = 0;
      final timestamps = <DateTime>[];
      await retryUntilJson(
        attempt: () async {
          calls++;
          timestamps.add(DateTime.now());
          return null;
        },
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 30),
      );
      expect(calls, 3);
      // Gap between attempt 1 and 2 should be ≥30ms (1x backoff).
      // Gap between attempt 2 and 3 should be ≥60ms (2x backoff).
      final gap1 = timestamps[1].difference(timestamps[0]).inMilliseconds;
      final gap2 = timestamps[2].difference(timestamps[1]).inMilliseconds;
      expect(gap1, greaterThanOrEqualTo(25));
      expect(gap2, greaterThanOrEqualTo(50));
    });
  });

  group('defaultExtractJson', () {
    test('parses plain object', () {
      expect(defaultExtractJson('{"a": 1}'), {'a': 1});
    });

    test('parses fences', () {
      expect(defaultExtractJson('```json\n{"a": 1}\n```'), {'a': 1});
    });

    test('parses leading prose then object', () {
      expect(defaultExtractJson('Here you go: {"a": 1} cheers'), {'a': 1});
    });

    test('returns null for pure prose', () {
      expect(defaultExtractJson('no json here'), isNull);
    });

    test('returns null for empty string', () {
      expect(defaultExtractJson(''), isNull);
    });

    test('returns null for whitespace only', () {
      expect(defaultExtractJson('   \n  '), isNull);
    });

    test('returns null for invalid JSON', () {
      expect(defaultExtractJson('{not json}'), isNull);
    });

    test('returns null when JSON is an array, not an object', () {
      expect(defaultExtractJson('[1, 2, 3]'), isNull);
    });
  });
}
