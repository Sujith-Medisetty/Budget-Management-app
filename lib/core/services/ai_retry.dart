import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Wraps a single AI call attempt with retry + exponential backoff. Used
/// by both [CloudAiParser] (transaction extraction) and [AgentService]
/// (chat). The point is to guarantee the caller never sees "no JSON" or
/// a transient transport error — either we hand back a valid JSON
/// object, or a fallback we control.
///
/// Behavior:
///   - Up to [maxAttempts] attempts (default 3).
///   - On a null body, a [DioException], or any other thrown error,
///     wait `backoff * attemptIndex` and try again.
///   - On a body that doesn't parse as a JSON object (prose, fences,
///     thinking artifacts, anything non-JSON), retry with the same
///     backoff — we have no way to ask the model to fix it inside the
///     attempt function, so we just re-call.
///   - On persistent failure (every attempt was null / threw), return
///     null so the caller can decide whether to surface "AI unreachable"
///     or stay silent.
///   - On persistent non-JSON (the model kept replying prose), return
///     a guaranteed-valid [fallbackJson]. This is what gets the caller
///     into the same parsing path as a normal reply — never a "no JSON
///     in AI response" rejection.
typedef JsonExtractor = Map<String, Object?>? Function(String body);

/// Retries [attempt] until its body parses as a JSON object. See the
/// file-level doc for the full behavior matrix.
Future<String?> retryUntilJson({
  required Future<String?> Function() attempt,
  JsonExtractor? extractJson,
  int maxAttempts = 3,
  Duration backoff = const Duration(milliseconds: 400),
  String fallbackJson = '{"skip": true, "error": "ai_no_json_after_retry"}',
}) async {
  final parse = extractJson ?? defaultExtractJson;
  for (int i = 1; i <= maxAttempts; i++) {
    String? body;
    try {
      body = await attempt();
    } on DioException catch (e) {
      if (kDebugMode) {
        debugPrint('[ai-retry] transport error attempt $i/$maxAttempts: ${e.message}');
      }
      if (i < maxAttempts) {
        await Future.delayed(backoff * i);
        continue;
      }
      return null;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ai-retry] error attempt $i/$maxAttempts: $e');
      }
      if (i < maxAttempts) {
        await Future.delayed(backoff * i);
        continue;
      }
      return null;
    }
    if (body == null) {
      if (kDebugMode) {
        debugPrint('[ai-retry] null body attempt $i/$maxAttempts');
      }
      if (i < maxAttempts) {
        await Future.delayed(backoff * i);
        continue;
      }
      return null;
    }
    final json = parse(body);
    if (json != null) return body;
    if (kDebugMode) {
      final preview = body.length > 80 ? '${body.substring(0, 80)}…' : body;
      debugPrint(
        '[ai-retry] no JSON attempt $i/$maxAttempts, body="$preview"',
      );
    }
    if (i < maxAttempts) {
      await Future.delayed(backoff * i);
      continue;
    }
    if (kDebugMode) {
      debugPrint('[ai-retry] giving up after $maxAttempts — returning fallback');
    }
    return fallbackJson;
  }
  return null;
}

/// Best-effort JSON-object extractor. Tries strict parse, then
/// ```json fences, then the first {...} block. Mirrors what
/// [CloudAiParser._extractJson] used to do inline.
Map<String, Object?>? defaultExtractJson(String body) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return null;
  try {
    final v = jsonDecode(trimmed);
    if (v is Map<String, Object?>) return v;
  } catch (_) {}
  final fence = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
  final m = fence.firstMatch(trimmed);
  if (m != null) {
    try {
      final v = jsonDecode(m.group(1)!);
      if (v is Map<String, Object?>) return v;
    } catch (_) {}
  }
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      final v = jsonDecode(trimmed.substring(start, end + 1));
      if (v is Map<String, Object?>) return v;
    } catch (_) {}
  }
  return null;
}
