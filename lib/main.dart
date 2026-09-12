import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'core/config.dart';
import 'core/theme/app_theme.dart';
import 'data/database/database_helper.dart';
import 'data/models/parsed_transaction.dart';
import 'data/models/raw_notification.dart';
import 'data/models/transaction.dart';
import 'data/repositories/ai_log_store.dart';
import 'data/repositories/budget_repository.dart';
import 'data/repositories/transaction_repository.dart';
import 'data/services/accounts_api.dart';
import 'data/services/ai_key_store.dart';
import 'data/services/budget_alerter.dart';
import 'data/services/gmail_filter_rules.dart';
import 'data/services/gmail_auth.dart';
import 'data/services/notification_service.dart';
import 'data/services/parser_router.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/shell/main_shell.dart';
import 'providers/onboarding_provider.dart';
import 'providers/providers.dart';
import 'providers/theme_provider.dart';

/// Top-level background-message handler. Runs in a fresh isolate
/// spawned by the FCM SDK — no Riverpod container, no instance
/// state. Must be top-level + @pragma('vm:entry-point') so the
/// native SDK can capture a CallbackHandle, and registered BEFORE
/// runApp() so the entry-point lookup succeeds on first launch.
///
/// This path fires when the app is killed or in the background —
/// exactly the moment a Gmail push is supposed to be useful. We
/// build a tiny self-contained pipeline (parse + DB insert +
/// capture notification) so the transaction lands in SQLite AND
/// the user sees a "Captured from Gmail" heads-up even if they
/// never open the app.
@pragma('vm:entry-point')
Future<void> _onBackgroundEntry(RemoteMessage message) async {
  // The FCM background isolate starts without Flutter's plugin
  // bindings initialized — without this call FlutterSecureStorage
  // silently returns null when read, which made the truncated
  // fallback path drop every oversized email. The call is idempotent.
  WidgetsFlutterBinding.ensureInitialized();

  // ignore: avoid_print
  print('[fcm] background message: '
      'id=${message.messageId} '
      'data=${jsonEncode(message.data)}');

  final data = message.data;
  if (data.isNotEmpty && data['type'] == 'backup_trigger') {
    // Cloud Scheduler fired the daily backup — wake the SQLite writer
    // and POST the snapshot to /backup/upload. We can't reuse
    // BackupService directly (it depends on providers), so the
    // background path uses a self-contained version that reads the
    // apiToken from secure storage and Dio-writes the upload itself.
    await _backgroundBackup();
    return;
  }

  final messageId = data['messageId'] as String?;
  if (messageId == null) return;

  String from;
  String subject;
  String body;
  DateTime postedAt;

  if (data['truncated'] == 'true') {
    // Server fell back to Firestore because the email was >4 KB.
    // FCM only carries {messageId, truncated:'true'}; pull the full
    // envelope via /sync?messageId=<id> using the cached apiToken.
    // Foreground path (fcm_bridge.dart) does the same via Riverpod;
    // here we're in a background isolate with no Riverpod container,
    // so we read the token from secure storage and call Dio directly.
    final fetched = await _fetchEnvelopeDirect(messageId);
    if (fetched == null) {
      debugPrint('[fcm] background: envelope fetch failed for $messageId');
      return;
    }
    from = fetched.from;
    subject = fetched.subject;
    body = fetched.body;
    postedAt = fetched.postedAt;
  } else {
    from = data['emailFrom'] as String? ?? data['from'] as String? ?? '';
    subject = data['subject'] as String? ?? '';
    body = data['text'] as String? ?? '';
    final dateStr = data['date'] as String?;
    final parsed = dateStr != null ? DateTime.tryParse(dateStr) : null;
    if (parsed == null) {
      // Background isolate can't reach Riverpod; if the date field
      // is missing or malformed we fall back to now so the user
      // sees a reasonable (if not email-accurate) timestamp rather
      // than 1970. adb logcat -s flutter will show this.
      debugPrint('[fcm] background: date parse FALLBACK for '
          '$messageId: dateStr=$dateStr');
      postedAt = DateTime.now();
    } else {
      postedAt = parsed.toLocal();
    }
  }

  final raw = RawNotification(
    notificationKey: 'gmail:$messageId',
    packageName: 'com.google.android.gm',
    title: from,
    text: '$subject\n$body'.trim(),
    postedAt: postedAt,
  );

  // Apply user filter rules in the background isolate too — without
  // this, a push that the user explicitly wants to ignore still
  // triggers a parser round-trip + ai_log row + notification. Riverpod
  // isn't available here, so we read the rules straight from
  // shared_preferences (same key the foreground FilterRuleStore uses).
  final rules = await _readFilterRules();
  if (!rules.allows(from: from, subject: subject, body: body)) {
    debugPrint('[fcm] background: filter rule rejected messageId=$messageId');
    await AiLogStore.record(
      package: 'com.google.android.gm',
      sourceText: jsonEncode({
        'messageId': messageId,
        'from': from,
        'subject': subject,
        'bodyPreview': body.substring(0, body.length.clamp(0, 200)),
      }),
      decision: 'dropped',
      reason: 'filter rule rejected (Gmail capture filter)',
    );
    return;
  }

  try {
    final store = await AiKeyStore.open();
    final router = ParserRouter(store: store);
    final parsed = await router.parse(raw);
    if (parsed == null) {
      debugPrint('[fcm] background: parser returned null, skipping');
      return;
    }
    final txRepo = TransactionRepository(DatabaseHelper.instance);
    final result = await txRepo.insertIfNew(_toTx(parsed, raw));
    debugPrint('[fcm] background: inserted=${result.inserted} '
        'merchant=${parsed.merchant} amount=${parsed.amount}');
    if (result.inserted) {
      // Build the budget context the same way the foreground
      // pipeline does, so the background-isolate notification body
      // matches what the user sees from a foreground capture.
      // Without this, FCM-triggered notifications would show the
      // truncated "$X.XX · merchant" body and skip the indicator +
      // budget name + spent / remaining / per-day lines — the
      // very reason the user complained the new format "isn't there".
      BudgetAlertContent? budgetContext;
      try {
        final budgetRepo = BudgetRepository(DatabaseHelper.instance);
        final snap = await BudgetAlerter.activeBudgetSnapshot(
          txRepo,
          budgetRepo,
        );
        if (snap != null) {
          budgetContext = BudgetAlerter.buildContent(
            budget: snap.budget,
            trigger: result.row,
            spent: snap.spent,
            periodEnd: snap.periodEnd,
          );
        }
      } on Object catch (e) {
        // Never let a budget lookup kill the capture notification.
        debugPrint('[fcm] background: budget snapshot failed: $e');
      }

      // NotificationService is a static singleton; the background
      // isolate has its own static memory so _initialized is false
      // here — init() re-runs the platform setup. show() swallows
      // its own platform errors so a missing Activity context won't
      // crash the capture pipeline.
      await NotificationService.instance.showTransactionCaptured(
        merchant: parsed.merchant,
        amount: parsed.amount,
        source: parsed.source,
        emailFrom: from.isEmpty ? null : from,
        subject: subject.isEmpty ? null : subject,
        reason: parsed.reason,
        occurredAt: raw.postedAt,
        budgetContext: budgetContext,
      );
    }
  } on Object catch (e, st) {
    debugPrint('[fcm] background: pipeline error: $e\n$st');
  }

  // Tell the server to drop the now-consumed envelope so the
  // pull-fallback buffer doesn't grow forever. Non-fatal: 24h TTL is
  // the safety net if this fails.
  await _deleteEnvelopeDirect(messageId);
}

Transaction _toTx(ParsedTransaction p, RawNotification raw) => Transaction(
      id: null,
      notificationKey: raw.notificationKey,
      source: p.source,
      amount: p.amount,
      merchant: p.merchant,
      reason: p.reason,
      occurredAt: raw.postedAt,
    );

/// Tiny DTO for the truncated-payload fallback path.
class _EnvelopeFetch {
  const _EnvelopeFetch({
    required this.from,
    required this.subject,
    required this.body,
    required this.postedAt,
  });
  final String from;
  final String subject;
  final String body;
  final DateTime postedAt;
}

/// Background-isolate equivalent of GmailSync.deleteEnvelope. Tells
/// the server to drop the now-consumed envelope. Non-fatal: failures
/// are logged at debug level only — the Firestore 24h TTL is the
/// safety net.
Future<void> _deleteEnvelopeDirect(String messageId) async {
  try {
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final apiToken = await secure.read(key: 'gmail_api_token');
    if (apiToken == null || apiToken.isEmpty) return;
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 5),
      headers: {'authorization': 'Bearer $apiToken'},
    ));
    await dio.delete(
      '$kServerUrl/envelope',
      queryParameters: {'messageId': messageId},
      options: Options(validateStatus: (_) => true),
    );
  } catch (e) {
    debugPrint('[fcm] background: envelope delete error: $e');
  }
}

/// Background-isolate equivalent of GmailSync.fetchEnvelope. Reads
/// the apiToken from secure storage and hits `/sync?messageId=<id>`
/// directly via Dio — no Riverpod, no parsed envelope, no parser.
/// Returns null on any failure (no network, no token, 404, etc) so
/// the caller can drop the message rather than crash the isolate.
Future<_EnvelopeFetch?> _fetchEnvelopeDirect(String messageId) async {
  try {
    // Match the AndroidOptions GmailAuth uses on the foreground side
    // (`aOptions: AndroidOptions(encryptedSharedPreferences: true)`).
    // The default options would point at a different backing store
    // and return null even when a token IS saved — every truncated
    // fallback would silently drop.
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final apiToken = await secure.read(key: 'gmail_api_token');
    if (apiToken == null || apiToken.isEmpty) return null;
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 10),
      headers: {'authorization': 'Bearer $apiToken'},
    ));
    final res = await dio.get<Map<String, dynamic>>(
      '$kServerUrl/sync',
      queryParameters: {'messageId': messageId},
    );
    final data = res.data;
    if (data == null) return null;
    final env = data['envelope'] as Map<String, dynamic>?;
    if (env == null) return null;
    final dateStr = env['date'] as String?;
    final parsed = dateStr != null ? DateTime.tryParse(dateStr) : null;
    DateTime postedAt;
    if (parsed == null) {
      debugPrint('[fcm] background: envelope date parse FALLBACK for '
          '$messageId: dateStr=$dateStr');
      postedAt = DateTime.now();
    } else {
      postedAt = parsed.toLocal();
    }
    return _EnvelopeFetch(
      from: env['from'] as String? ?? '',
      subject: env['subject'] as String? ?? '',
      body: env['text'] as String? ?? '',
      postedAt: postedAt,
    );
  } catch (e) {
    debugPrint('[fcm] background: envelope fetch error: $e');
    return null;
  }
}

/// Background-isolate equivalent of FilterRuleStore.read(). Pulls the
/// filter rules from the cloud via `GET /accounts/<sub>` — same source
/// the foreground controller reads from, so a rule the user just
/// edited takes effect on the very next push (or stays in force after
/// a kill-restart). Falls back to defaults if the API call fails —
/// better to over-process than to silently drop.
///
/// Background isolate can't use the Firestore SDK (no Firebase Auth
/// session crosses the isolate boundary), so this path stays on the
/// apiToken Bearer route the pre-refactor client used.
Future<FilterRuleSet> _readFilterRules() async {
  try {
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final apiToken = await secure.read(key: 'gmail_api_token');
    if (apiToken == null || apiToken.isEmpty) {
      return FilterRuleSet.defaults;
    }
    final sub = GmailAuth.subFromApiToken(apiToken);
    if (sub == null) {
      return FilterRuleSet.defaults;
    }
    final api = AccountsApi(auth: GmailAuth());
    final record = await api.get(sub, apiToken: apiToken);
    final raw = record?.filterRulesJson;
    if (raw == null) return FilterRuleSet.defaults;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return FilterRuleSet.defaults;
    return FilterRuleSet.fromJson(decoded.cast<String, Object?>());
  } catch (e) {
    debugPrint('[fcm] background: filter read FALLBACK: $e');
    return FilterRuleSet.defaults;
  }
}

/// Background-isolate equivalent of `BackupService.upload`. Reads the
/// apiToken from secure storage, dumps every transaction + budget row
/// from SQLite, POSTs the snapshot, then fires a local notification so
/// the user sees confirmation even when the app is killed.
///
/// Why not just call `BackupService.upload`: the service depends on
/// Riverpod providers, which don't exist in this isolate. Building a
/// standalone copy is the smallest delta and keeps the foreground +
/// background code paths independent — a crash in one can't take down
/// the other.
///
/// Server-side gate: the per-user Cloud Scheduler job
/// (`pocket-backup-{sub}`) only exists for users with backup enabled,
/// so the `backup_trigger` FCM message only arrives for those users.
/// No client-side `enabled` check needed — and no ±60 min window: the
/// server cron fires at the user's chosen local hour, so the trigger
/// arrives at the right moment without the device guessing.
Future<void> _backgroundBackup() async {
  try {
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final apiToken = await secure.read(key: 'gmail_api_token');
    if (apiToken == null || apiToken.isEmpty) {
      debugPrint('[backup] background: no apiToken, skipping upload');
      return;
    }

    // Pull every row from the helper directly — the foreground
    // `BackupService.upload` does the same, but we can't reuse it
    // here because the background isolate has no Riverpod container.
    final db = await DatabaseHelper.instance.database;
    final txns = await db.query('transactions');
    final budgets = await db.query('budgets');
    final body = jsonEncode({
      'transactions': txns,
      'budgets': budgets,
    });
    debugPrint('[backup] background: uploading ${txns.length} txns, '
        '${budgets.length} budgets (${body.length} bytes)');

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 15),
      headers: {
        'authorization': 'Bearer $apiToken',
        'content-type': Headers.jsonContentType,
      },
    ));
    final res = await dio.post<Map<String, dynamic>>(
      '$kServerUrl/backup/upload',
      data: body,
      options: Options(validateStatus: (_) => true),
    );

    // Pull the per-user notify flags from the cloud record. Defaults
    // are OFF — the user opts into the success / failure banners via
    // the Backup screen. Best-effort: a network blip here shouldn't
    // fail the upload we already completed, and falling back to "off"
    // on a missed fetch is the right call (quiet > noisy).
    //
    // Background isolate stays on the apiToken Bearer path — Firebase
    // Auth sessions don't cross isolate boundaries, so the Firestore
    // SDK isn't available here.
    bool notifyComplete = false;
    bool notifyFailed = false;
    try {
      final sub = GmailAuth.subFromApiToken(apiToken);
      if (sub != null) {
        final api = AccountsApi(auth: GmailAuth());
        final record = await api.get(sub, apiToken: apiToken);
        if (record != null) {
          notifyComplete = record.backupNotifyComplete;
          notifyFailed = record.backupNotifyFailed;
        }
      }
    } catch (e) {
      debugPrint('[backup] background: notify flags fetch FALLBACK: $e');
    }

    if (res.statusCode == 200) {
      if (notifyComplete) {
        await NotificationService.instance.showRaw(
          title: 'Backup complete',
          body:
              '${txns.length} transactions · ${budgets.length} budgets saved',
        );
      }
    } else {
      debugPrint('[backup] background: upload failed: ${res.statusCode}');
      if (notifyFailed) {
        await NotificationService.instance.showRaw(
          title: 'Backup failed',
          body: 'Server returned ${res.statusCode}',
        );
      }
    }
  } catch (e, st) {
    debugPrint('[backup] background: upload error: $e\n$st');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Print the resolved SERVER_URL on every cold start so a sign-in
  // timeout can be diagnosed from `adb logcat -s flutter` alone — the
  // most common cause of "connection timeout" is the URL being the
  // emulator default (http://10.0.2.2:8080) on a real device, which
  // resolves to nothing and times out silently.
  debugPrint('[pocket] boot: SERVER_URL=$kServerUrl');
  // We previously called Firebase.initializeApp() + bootstrapFirebaseAuth()
  // here to set up the Firestore SDK session used by
  // `FirestoreAccounts`. The Firestore project was deleted during
  // the GCP → Oracle VM migration — the same per-user account data
  // now lives in Postgres and is served by `accountsRepo` over the
  // VM REST API. FCM still needs firebase_messaging, but that SDK
  // initializes itself on first use (token fetch, listener attach).
  // The bootstrap call is kept as a no-op shim so a downgrade to a
  // pre-migration server doesn't brick sign-in.
  await GmailAuth().bootstrapFirebaseAuth();
  // Self-heal the FCM token registration on every cold start. Catches
  // the case where the user signed in before FCM was healthy (e.g. the
  // FIS API key was missing, or Firebase APIs were disabled) — the
  // server has nothing to push to until this fires successfully.
  await GmailAuth().bootstrapDevice();
  // Register the background handler at cold start. firebase_messaging
  // calls PluginUtilities.getCallbackHandle on this function and uses
  // the result to spin up the background isolate; if the registration
  // happens post-runApp the callback handle comes back null on debug
  // builds and the app crashes at startup.
  FirebaseMessaging.onBackgroundMessage(_onBackgroundEntry);
  runApp(const ProviderScope(child: PocketApp()));
}

class PocketApp extends ConsumerWidget {
  const PocketApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Eagerly wire the notification pipeline once the tree exists.
    ref.watch(initializeNotificationsProvider);
    // Wire the FCM bridge so onMessage handlers are attached and
    // the per-account topic subscription is in place before any
    // push arrives. Read-only access — the provider's microtask
    // does the actual setup.
    ref.watch(fcmBridgeProvider);

    final themeMode = ref.watch(themeProvider);
    final onboarding = ref.watch(onboardingCompletedProvider);

    return MaterialApp(
      title: 'Pocket',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: onboarding.when(
        // Brief splash while the prefs read resolves. Avoids flashing
        // the dashboard before we know whether to show onboarding.
        loading: () => const _BootSplash(),
        error: (e, _) => _BootError(message: e.toString()),
        data: (completed) => completed
            ? const MainShell()
            : const OnboardingScreen(),
      ),
    );
  }
}

class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            color: scheme.primary,
            strokeWidth: 2.4,
          ),
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            "Couldn't start Pocket:\n$message",
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}