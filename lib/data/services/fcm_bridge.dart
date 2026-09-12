import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/raw_notification.dart';
import '../repositories/ai_log_store.dart';
import 'accounts_repo.dart';
import 'backup_service.dart';
import 'gmail_auth.dart';
import 'gmail_filter_rules.dart';
import 'gmail_sync.dart';
import 'notification_pipeline.dart';

/// Receives FCM data messages from the Pocket VM backend and feeds
/// them into the existing notification pipeline.
///
/// Wire shape (server → device):
///   {
///     "messageId": "18d4a...",
///     "emailFrom": "service@paypal.com",
///     "subject":   "You sent $29.99 to Amazon",
///     "date":      "2026-09-05T10:00:00.000Z",
///     "text":      "You sent $29.99 USD to Amazon. Available ...",
///   }
///
/// (`from` is a reserved FCM data key — we use `emailFrom` instead.)
///
/// Or, when the email body is too big for a single FCM payload:
///   { "messageId": "18d4a...", "truncated": "true" }
/// In that case we pull the full envelope via /sync?messageId=...
/// before constructing the RawNotification.
class FcmBridge {
  FcmBridge({
    this._pipeline,
    this._gmailSync,
    this._rules,
    this._auth,
    this._backup,
    this._accounts,
  });
  // Using the explicit field assignments to keep the constructor
  // signature stable for callers that override individual services
  // (e.g. the background isolate passes a pre-built BackupService).
  // The initializing-formal `this._pipeline` form would force every
  // field to be required-by-name.

  final NotificationPipeline? _pipeline;
  final GmailSync? _gmailSync;
  final FilterRuleSet? _rules;
  final GmailAuth? _auth;
  final BackupService? _backup;
  final AccountsRepo? _accounts;

  static const _kFcmToken = 'fcm_token';

  /// Pulls the cached FCM token, or requests a new one from Firebase.
  /// Returns null if FCM isn't available (e.g. emulator without GMS).
  Future<String?> currentToken() async {
    final cached = await _readCachedToken();
    if (cached != null) return cached;
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _writeCachedToken(token);
    return token;
  }

  /// Wires the foreground message handler. The background handler
  /// (`_onBackgroundEntry`) is registered in `main.dart` before
  /// `runApp()` — registering it here instead crashes debug builds
  /// because `PluginUtilities.getCallbackHandle` returns null when
  /// called post-`runApp`.
  ///
  /// [pipeline] / [gmailSync] / [rules] / [auth] are optional overrides
  /// so the background isolate (which can't pull from a Riverpod
  /// container directly) can hand the bridge pre-built dependencies.
  Future<void> attach({
    NotificationPipeline? pipeline,
    GmailSync? gmailSync,
    FilterRuleSet? rules,
    GmailAuth? auth,
    BackupService? backup,
    AccountsRepo? accounts,
  }) async {
    FirebaseMessaging.onMessage.listen((msg) {
      _handleForeground(
        msg,
        pipeline ?? _pipeline,
        gmailSync ?? _gmailSync,
        rules ?? _rules,
        backup ?? _backup,
        accounts ?? _accounts,
      );
    });
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: false,
      sound: false,
    );
    // Eagerly fetch the FCM token so the server has something to push
    // to as soon as it's deployed. Token is cached in shared_preferences
    // after first fetch.
    final token = await currentToken();
    if (kDebugMode && token != null) {
      debugPrint('[fcm] token: $token');
    }
    // Firebase rotates FCM tokens periodically (typically every ~6
    // months). Without this listener, the server keeps publishing to
    // the old (now-invalid) token and pushes silently stop until the
    // user re-signs in. Re-register via /devices/register so the
    // server's fcmTokens set stays current.
    final auth0 = auth ?? _auth;
    if (auth0 != null) {
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final apiToken = await auth0.apiToken();
        if (apiToken == null || apiToken.isEmpty) return;
        try {
          await auth0.registerDevice(apiToken);
          debugPrint('[fcm] token rotated, re-registered with server');
        } catch (e) {
          debugPrint('[fcm] token rotation re-register FAILED: $e');
        }
      });
    }
  }

  /// Subscribe this device to the FCM topic for a given Google
  /// account `sub`. Called after GmailAuth.signIn so push deliveries
  /// route to this specific install.
  ///
  /// Deprecated: server now publishes directly to the FCM tokens it
  /// has on file (registered via /devices/register), so topic
  /// subscriptions are no-ops. Kept for one release as a no-op
  /// shim so any older caller doesn't break; remove next refactor.
  Future<void> subscribeToAccountTopic(String sub) async {
    // no-op — kept for back-compat with any external caller.
  }

  Future<void> unsubscribeFromAccountTopic(String sub) async {
    // no-op — kept for back-compat with any external caller.
  }

  Future<void> _handleForeground(
    RemoteMessage message,
    NotificationPipeline? pipeline,
    GmailSync? gmailSync,
    FilterRuleSet? rules,
    BackupService? backup,
    AccountsRepo? accounts,
  ) async {
    if (kDebugMode) {
      debugPrint('[fcm] foreground message: '
          'id=${message.messageId} '
          'data=${jsonEncode(message.data)}');
    }
    final data = message.data;
    if (data.isEmpty) return;

    // Backup triggers carry `type: backup_trigger` and no `messageId`.
    // They originate from the per-user Cloud Scheduler job (`pocket-
    // backup-{sub}`) — the server publishes to this device's FCM
    // token when *its* user's job fires. The device's job is to
    // upload its SQLite snapshot and confirm with a local
    // notification. The server-side gate means the trigger only
    // arrives for users with backup enabled — no client-side enabled
    // check needed.
    final type = data['type'] as String?;
    if (type == 'backup_trigger') {
      final backup0 = backup ?? _backup;
      if (backup0 == null) return;
      final accounts0 = accounts ?? _accounts;
      // Read the per-user notify flags from the cloud record.
      // Defaults are OFF — the user opts into the success / failure
      // banners via the Backup screen. Defaulting on meant a fresh
      // install got a notification for every cloud-scheduled fire.
      final record = accounts0 != null
          ? await accounts0.fetch()
          : null;
      final result = await backup0.upload();
      if (result.success) {
        if (record?.backupNotifyComplete ?? false) {
          await backup0.notifySuccess(
            transactions: result.transactions,
            budgets: result.budgets,
          );
        }
      } else {
        if (record?.backupNotifyFailed ?? false) {
          await backup0.notifyFailure(result.reason ?? 'Unknown error');
        }
      }
      return;
    }

    if (pipeline == null) return;
    final messageId = data['messageId'] as String?;
    if (messageId == null) return;

    RawNotification? raw;
    final isTruncated = (data['truncated'] as String?) == 'true';
    if (isTruncated) {
      raw = await gmailSync?.fetchEnvelope(messageId);
    } else {
      raw = _buildRawFromData(messageId, data, rules);
    }
    if (raw == null) {
      if (kDebugMode) {
        debugPrint('[fcm] filter rule rejected messageId=$messageId');
      }
      unawaited(
        AiLogStore.record(
          package: 'com.google.android.gm',
          sourceText: jsonEncode(data),
          decision: 'dropped',
          reason: 'filter rule rejected (Gmail capture filter)',
        ),
      );
      return;
    }
    if (kDebugMode) {
      debugPrint(
        '[fcm] -> pipeline: messageId=$messageId '
        'from="${raw.title}" '
        'bodyLen=${raw.text.length}',
      );
    }
    await pipeline.handle(raw);
    // Tell the server to drop the now-consumed envelope so the
    // pull-fallback buffer doesn't grow forever. We do this for both
    // truncated and inline paths — the server persists to Firestore
    // on every message. Non-fatal: 24h TTL is the safety net.
    unawaited(gmailSync?.deleteEnvelope(messageId) ?? Future.value());
  }

  RawNotification? _buildRawFromData(
    String messageId,
    Map<String, dynamic> data,
    FilterRuleSet? rules,
  ) {
    // Server uses `emailFrom` because `from` is a reserved FCM data
    // key (the notification sender field). Accept both for
    // back-compat with any older payloads already on devices.
    final from = data['emailFrom'] as String? ?? data['from'] as String? ?? '';
    final subject = data['subject'] as String? ?? '';
    final body = data['text'] as String? ?? '';
    final dateStr = data['date'] as String?;
    final parsed = _parsePostedAt(dateStr);
    final postedAt = parsed.value;
    if (parsed.usedFallback) {
      // If we hit this in the wild we want to know — without it the
      // user sees the time of receipt (now) instead of the email's
      // Date header, which is the "wrong time" bug we'd otherwise
      // diagnose by reading code. adb logcat -s flutter will surface
      // it.
      if (kDebugMode) {
        debugPrint(
          '[fcm] date parse FALLBACK for messageId=$messageId: '
          'dateStr=$dateStr -> using DateTime.now()',
        );
      }
    }

    if (rules != null && !rules.allows(from: from, subject: subject, body: body)) {
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

  Future<String?> _readCachedToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kFcmToken);
  }

  Future<void> _writeCachedToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFcmToken, token);
  }

  /// Returns the local-time DateTime for an FCM `date` field plus a
  /// flag for whether the fallback to [DateTime.now] was used.
  ///
  /// The server always sends ISO 8601 with a `Z` suffix (e.g.
  /// `2026-09-05T20:53:48.000Z`), which Dart's [DateTime.tryParse]
  /// handles correctly. The fallback exists for older payloads,
  /// partial `truncated:true` fetches where the date field is
  /// missing, and any future schema drift.
  ({DateTime value, bool usedFallback}) _parsePostedAt(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) {
      return (value: DateTime.now(), usedFallback: true);
    }
    final direct = DateTime.tryParse(dateStr);
    if (direct != null) {
      return (value: direct.toLocal(), usedFallback: false);
    }
    return (value: DateTime.now(), usedFallback: true);
  }
}