import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../models/raw_notification.dart';
import '../repositories/ai_log_store.dart';
import 'accounts_repo.dart';
import 'gmail_auth.dart';
import 'gmail_filter_rules.dart';
import 'notification_pipeline.dart';

/// High-water mark for /sync queries. Server returns rows strictly
/// greater than `since`, so we always advance to the newest envelope
/// we processed (not "now") to avoid missing messages that arrive in
/// the gap between the request and the response. Lives in Postgres
/// `accounts.lastSyncAt` (no local SQLite mirror) so the value
/// survives sign-out / sign-in and stays consistent across devices.
class _SyncState {
  static Future<DateTime> read(AccountsRepo repo) async {
    final record = await repo.fetch();
    return record?.lastSyncAt ??
        DateTime.now().subtract(const Duration(days: 7));
  }

  static Future<void> write(
    AccountsRepo repo,
    DateTime ts,
  ) async {
    await repo.setLastSyncAt(ts.millisecondsSinceEpoch);
  }
}

/// Pulls new envelopes from the Pocket backend (`GET /sync?since=...`)
/// and feeds them into [NotificationPipeline] so the rule parser and
/// budget alerter run unchanged. The server has already done the
/// Pub/Sub → Gmail history → MIME extraction; the phone just gets the
/// clean envelope and decides whether to surface it (filter rules).
///
/// The pipeline dedups by `notificationKey = 'gmail:<messageId>'`, so
/// reprocessing the same envelope is a no-op even if both FCM and
/// pull sync race on the same message.
class GmailSync {
  GmailSync(
    this._auth,
    this._pipeline,
    this._rules,
    this._repo, {
    Dio? http,
  }) : _http = http ?? Dio();

  final GmailAuth _auth;
  final NotificationPipeline _pipeline;
  final FilterRuleSet _rules;
  final AccountsRepo _repo;
  final Dio _http;

  /// Pulls all envelopes newer than [since], runs them through the
  /// pipeline, then advances the high-water mark. Returns the number
  /// of new rows stored (after dedup).
  Future<int> fetchNew({DateTime? since}) async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) return 0;

    final start = since ?? await _SyncState.read(_repo);
    final res = await _http.get<dynamic>(
      '$kServerUrl/sync',
      queryParameters: {'since': start.millisecondsSinceEpoch.toString()},
      options: Options(
        headers: {'authorization': 'Bearer $apiToken'},
        validateStatus: (_) => true,
      ),
    );
    if (res.statusCode == 401) {
      // Server revoked us — GmailAuth.tryRestore already clears the
      // token on 401, but a race between two callers means we should
      // still bail without crashing the caller.
      return 0;
    }
    if (res.statusCode != 200 || res.data == null) {
      throw StateError('/sync failed: ${res.statusCode}');
    }

    final body = res.data;
    final List<dynamic> envelopes;
    if (body is Map<String, dynamic>) {
      envelopes = (body['envelopes'] as List?) ?? const [];
    } else if (body is List) {
      envelopes = body;
    } else {
      envelopes = const [];
    }
    if (envelopes.isEmpty) {
      await _SyncState.write(_repo, DateTime.now());
      return 0;
    }

    var stored = 0;
    var newest = start;
    for (final raw in envelopes) {
      if (raw is! Map) continue;
      try {
        final rawMap = raw.cast<String, dynamic>();
        final raw2 = _buildRaw(rawMap);
        if (raw2 == null) continue;
        final inserted = await _pipeline.handle(raw2);
        if (inserted != null) stored++;
        if (raw2.postedAt.isAfter(newest)) newest = raw2.postedAt;
        // Tell the server to drop the now-consumed envelope so the
        // pull-fallback buffer doesn't grow forever. Non-fatal — the
        // Firestore 24h TTL is the safety net.
        final messageId = rawMap['messageId'] as String?;
        if (messageId != null) {
          await deleteEnvelope(messageId);
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[gmail] envelope parse failed: $e');
        }
        AiLogStore.record(
          package: 'com.google.android.gm',
          sourceText: raw.toString(),
          decision: 'dropped',
          reason: 'envelope parse failed: $e',
        );
      }
    }
    await _SyncState.write(_repo, newest);
    return stored;
  }

  /// Fetches a single envelope by id. Used by FcmBridge when the
  /// server publishes a truncated payload (`{messageId, truncated}`)
  /// because the FCM data-message size cap (4 KB) was too small for
  /// the full email body.
  Future<RawNotification?> fetchEnvelope(String messageId) async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) return null;
    final res = await _http.get<dynamic>(
      '$kServerUrl/sync',
      queryParameters: {'messageId': messageId},
      options: Options(
        headers: {'authorization': 'Bearer $apiToken'},
        validateStatus: (_) => true,
      ),
    );
    if (res.statusCode != 200 || res.data == null) return null;
    final body = res.data;
    final Map<String, dynamic> env;
    if (body is Map<String, dynamic>) {
      // Single envelope comes back either as the object itself or as
      // an `envelope` field — accept both.
      env = (body['envelope'] as Map?)?.cast<String, dynamic>() ?? body;
    } else {
      return null;
    }
    return _buildRaw(env);
  }

  /// Tells the server to drop the envelope for [messageId]. Called
  /// after [fetchEnvelope] or after each successful [fetchNew] so
  /// the server's pull-fallback buffer doesn't grow unbounded. The
  /// Firestore 24h TTL is the safety net if this call fails.
  /// Non-fatal: we never throw — the next sync can retry naturally.
  Future<void> deleteEnvelope(String messageId) async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) return;
    try {
      final res = await _http.delete<dynamic>(
        '$kServerUrl/envelope',
        queryParameters: {'messageId': messageId},
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 && res.statusCode != 404) {
        if (kDebugMode) {
          debugPrint('[gmail] envelope delete($messageId) -> ${res.statusCode}');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[gmail] envelope delete($messageId) failed: $e');
      }
    }
  }

  RawNotification? _buildRaw(Map<String, dynamic> env) {
    final messageId = env['messageId'] as String?;
    if (messageId == null) return null;
    final from = env['from'] as String? ?? '';
    final subject = env['subject'] as String? ?? '';
    final body = env['text'] as String? ?? '';
    final dateStr = env['date'] as String?;
    final postedAt = dateStr != null
        ? DateTime.tryParse(dateStr)?.toLocal() ?? DateTime.now()
        : DateTime.now();

    // User-defined filter is the only gate. Disabled rules / empty
    // rule list = process everything.
    if (!_rules.allows(from: from, subject: subject, body: body)) {
      // Mirror the foreground FCM path: surface the rejection in the
      // Activity log so the user can see what got dropped (and why)
      // even when the trigger came from pull-to-refresh instead of push.
      unawaited(
        AiLogStore.record(
          package: 'com.google.android.gm',
          sourceText: jsonEncode({
            'messageId': messageId,
            'from': from,
            'subject': subject,
            'bodyPreview': body.substring(0, body.length.clamp(0, 200)),
          }),
          decision: 'dropped',
          reason: 'filter rule rejected (Gmail capture filter)',
        ),
      );
      return null;
    }

    return RawNotification(
      notificationKey: 'gmail:$messageId',
      packageName: 'com.google.android.gm',
      title: from,
      text: '$subject\n$body'.trim(),
      postedAt: postedAt,
    );
  }
}