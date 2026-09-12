import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/database/database_helper.dart';
import '../data/models/ai_config.dart';
import '../data/repositories/budget_repository.dart';
import '../data/repositories/transaction_repository.dart';
import '../data/services/account_hydrator.dart';
import '../data/services/account_service.dart';
import '../data/services/accounts_repo.dart';
import '../data/services/ai_key_store.dart';
import '../data/services/backup_service.dart';
import '../data/services/budget_alerter.dart';
import '../data/services/budget_hydrator.dart';
import '../data/services/budgets_api.dart';
import '../data/services/fcm_bridge.dart';
import '../data/services/gmail_auth.dart';
import '../data/services/gmail_filter_rules.dart';
import '../data/services/gmail_sync.dart';
import '../data/services/notification_pipeline.dart';
import '../data/services/notification_service.dart';
import '../data/services/parser_router.dart';
import '../data/services/rule_sync_service.dart';

/// Singleton DB handle.
final databaseHelperProvider = Provider<DatabaseHelper>(
  (ref) => DatabaseHelper.instance,
);

final transactionRepoProvider = Provider<TransactionRepository>(
  (ref) => TransactionRepository(ref.watch(databaseHelperProvider)),
);

final budgetRepoProvider = Provider<BudgetRepository>(
  (ref) => BudgetRepository(ref.watch(databaseHelperProvider)),
);

/// REST client for the per-user account record. Reads / writes
/// `accounts/{sub}` via `GET` / `PATCH /accounts/<sub>` on the VM
/// using the apiToken Bearer (no Firebase Auth dependency). Same
/// shape as the old Firestore SDK wrapper — `fetch`,
/// `updateBackupPrefs`, `updateFilterRules`, `setLastSyncAt` —
/// callers didn't need to change after the GCP → Oracle VM migration.
final accountsRepoProvider = Provider<AccountsRepo>(
  (ref) => AccountsRepo(auth: ref.watch(gmailAuthProvider)),
);

/// Called once after a successful OAuth exchange. Validates the cloud
/// record exists; the per-user Cloud Scheduler job is kept in lockstep
/// with `backupPrefs` by an Eventarc trigger, so no client-side POST
/// is needed. Everything else hydrates lazily on first read via the
/// per-screen fetch.
final accountHydratorProvider = Provider<AccountHydrator>(
  (ref) => AccountHydrator(repo: ref.watch(accountsRepoProvider)),
);

/// REST client for the server-side `budgets` table. Powers the
/// budget hydrator's `GET /budgets/ensure-current` call on sign-in.
/// Same Dio + GmailAuth scaffolding as `accountsRepoProvider`.
final budgetsApiProvider = Provider<BudgetsApi>(
  (ref) => BudgetsApi(auth: ref.watch(gmailAuthProvider)),
);

/// Bridge from the server-side auto-create flow to local SQLite.
/// After a successful sign-in, runs `ensureCurrentMonthLocally`
/// which fires `GET /budgets/ensure-current` and mirrors any
/// server-minted row into the device's `budgets` table. Idempotent
/// — calling on every sign-in only ever produces one row per
/// (name, start_date) combination. Best-effort: any network or
/// decode error is swallowed so the sign-in flow is never blocked.
final budgetHydratorProvider = Provider<BudgetHydrator>(
  (ref) => BudgetHydrator(
    api: ref.watch(budgetsApiProvider),
    repo: ref.watch(budgetRepoProvider),
  ),
);

final budgetAlerterProvider = Provider<BudgetAlerter>(
  (ref) => BudgetAlerter(
    ref.watch(transactionRepoProvider),
    ref.watch(budgetRepoProvider),
  ),
);

/// Async handle to the AI config + key store. Opens shared prefs once
/// then reuses the same instance for the rest of the app's life.
final aiKeyStoreProvider = FutureProvider<AiKeyStore>(
  (ref) => AiKeyStore.open(),
);

/// The most recent AI config snapshot. Read by both the AI settings
/// screen and the parser router.
final aiConfigProvider = FutureProvider<AiConfig>((ref) async {
  final store = await ref.watch(aiKeyStoreProvider.future);
  return store.read();
});

/// Single entry point for parsing — always AI-only. Reads the latest
/// config + key from [aiKeyStoreProvider] on every call so changes
/// take effect on the next message without a rebuild.
final parserRouterProvider = Provider<ParserRouter>((ref) {
  return ParserRouter(
    store: ref.watch(aiKeyStoreProvider).requireValue,
  );
});

final notificationPipelineProvider = Provider<NotificationPipeline>(
  (ref) => NotificationPipeline(
    ref.watch(parserRouterProvider),
    ref.watch(transactionRepoProvider),
    ref.watch(budgetAlerterProvider),
    notifier: ref.watch(notificationServiceProvider),
  ),
);

// Extracted so the dart analyzer can resolve the gmailAuth ↔
// backupService cycle without flagging top_level_cycle. The auto-
// restore lives at the sign-in call sites (settings / onboarding /
// agent) via `autoRestoreAfterSignIn` — keeping it there avoids the
// captured-ref cycle that bites when a provider closure tries to
// read another provider that depends back on it.
GmailAuth _buildGmailAuth(Ref ref) => GmailAuth();

final gmailAuthProvider = Provider<GmailAuth>(_buildGmailAuth);

final gmailSyncProvider = Provider<GmailSync>(
  (ref) => GmailSync(
    ref.watch(gmailAuthProvider),
    ref.watch(notificationPipelineProvider),
    ref.watch(gmailFilterRulesProvider),
    ref.watch(accountsRepoProvider),
  ),
);

/// User-facing "delete my account" — fires the server-side wipe,
/// then drops local SQLite + SecureStorage. Lives here next to
/// `gmailSyncProvider` so the Settings screen can reach it via the
/// same `ref.read` pattern used elsewhere.
final accountServiceProvider = Provider<AccountService>(
  (ref) => AccountService(auth: ref.watch(gmailAuthProvider)),
);

/// Cloud backup of transactions + budgets. Stateless wrapper — the
/// provider just owns the instance and lets both the manual Settings
/// buttons and the FCM `type: backup_trigger` handler share the same
/// upload pipeline (so neither path can drift on auth or row shape).
final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(
    auth: ref.watch(gmailAuthProvider),
  );
});

/// Bridge that turns FCM data messages into [NotificationPipeline]
/// calls. Side-effect on first read: subscribes to the FCM topic for
/// the connected account (best-effort), wires foreground/background
/// handlers, and eagerly fetches the FCM token.
final fcmBridgeProvider = Provider<FcmBridge>((ref) {
  final bridge = FcmBridge();
  // Fire-and-forget: the bridge's attach() pulls the FCM token,
  // wires listeners, and subscribes to the topic. All best-effort —
  // the user still gets FCM via the Google Account topic even if
  // this crashes.
  Future.microtask(() async {
    // The FirebaseAuth session is re-established in `main()` BEFORE
    // runApp() so providers that fire Firestore SDK reads at
    // construction (filter rules, backup prefs, etc.) always see a
    // signed-in FirebaseAuth. No need to bootstrap here.

    // parserRouterProvider calls .requireValue on aiKeyStore, which
    // throws while the store is still opening from SharedPreferences.
    // Wait for it to settle before reading anything downstream.
    await ref.read(aiKeyStoreProvider.future).catchError((_) =>
        // If the store can't open (corrupt prefs, etc.) the bridge
        // still attaches without a pipeline — FCM messages will log
        // but not auto-parse. Better than crashing the app.
        throw StateError('ai store unavailable'));
    final pipeline = ref.read(notificationPipelineProvider);
    final sync = ref.read(gmailSyncProvider);
    final rules = ref.read(gmailFilterRulesProvider);
    final auth = ref.read(gmailAuthProvider);
    final backup = ref.read(backupServiceProvider);
    final accounts = ref.read(accountsRepoProvider);
    final token = await auth.apiToken();
    await bridge.attach(
      pipeline: pipeline,
      gmailSync: sync,
      rules: rules,
      auth: auth,
      backup: backup,
      accounts: accounts,
    );
    if (token != null) {
      final sub = GmailAuth.subFromApiToken(token);
      if (sub != null) {
        debugPrint('[fcm] signed in: sub=$sub (server publishes to '
            'this device\'s FCM token directly — no topic subs)');
      } else {
        debugPrint('[fcm] apiToken sub unavailable — not signed in?');
      }
    } else {
      debugPrint('[fcm] no apiToken — Gmail capture disabled until sign-in');
    }

    // Filter rules are NOT auto-synced to the server on every state
    // change. Earlier this listener pushed a debounced sync on every
    // keystroke — but the server treats each POST as the user's final
    // intent: rules missing from the incoming set are deleted from
    // Gmail. Keystroke-level syncs therefore caused intermediate
    // states (a half-deleted rule, a new rule with one character
    // typed) to hit Gmail and trigger spurious deletes/recreates,
    // producing the "app shows N filters, server has M" divergence.
    // The Email filters screen's Save button calls RuleSyncService
    // .saveNow() directly, and the agent widget's filter actions do
    // the same after their update() — both paths bypass this
    // listener. Local-only writes (the in-memory controller state
    // and the FilterRuleStore cache) still happen on every keystroke
    // for crash safety.
  });
  return bridge;
});

/// Resolves to the signed-in Gmail address, or null when not connected.
/// Used by the onboarding step + settings tile to render the right
/// state ("Connected as foo@bar" vs "Sign in with Google").
final gmailConnectedProvider = FutureProvider<String?>(
  (ref) => ref.watch(gmailAuthProvider).signedInEmail(),
);

final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

/// Eagerly initializes flutter_local_notifications on boot so budget
/// threshold alerts have a ready channel. Call from a root widget.
final initializeNotificationsProvider = Provider<void>((ref) {
  final notifier = ref.watch(notificationServiceProvider);
  // Schedule init for after the first frame to avoid blocking startup.
  Future.microtask(() async {
    await notifier.init();
  });
});

/// Async handle to shared_preferences — single instance for the app's
/// life. We expose it as a FutureProvider so consumers don't have to
/// race on the first read.
final sharedPrefsProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

/// User-configurable Gmail filter rules as an allowlist. Defaults to
/// disabled + empty rules list, which means "capture every Gmail
/// message" — matching the pre-feature behavior. Once the master
/// switch is on, only matching emails turn into transactions.
///
/// Local edits (every keystroke, every delete) write to a
/// SharedPreferences mirror so a half-typed rule survives an app
/// restart, but they do NOT touch Firestore. The Save flow commits
/// the in-memory cache to Firestore + posts to /filters/sync — that
/// ordering is what keeps the server's existing-rules snapshot
/// consistent with the user's last Saved state, so Gmail-side
/// creates / deletes still see the rule's gmail-id and the diff
/// loop has something to compare against.
class GmailFilterRulesController extends StateNotifier<FilterRuleSet> {
  GmailFilterRulesController(this._store, FilterRuleSet initial)
      : super(initial);
  final FilterRuleStore _store;

  Future<void> update(FilterRuleSet next) async {
    await _store.write(next);
    state = next;
  }

  /// Replaces [state] with the server-merged set after a successful
  /// `/filters/sync`. Skips the local write because [RuleSyncService]
  /// has already persisted it. Sets state directly so the
  /// `gmailFilterRulesProvider` listener fires — but `_lastSyncedJson`
  /// in RuleSyncService matches the same JSON, so the listener
  /// short-circuits and no extra sync is scheduled.
  ///
  /// Without this path, every subsequent sync tells the server "no
  /// Gmail-ids on any rule" and the server delete+recreates every
  /// Gmail filter on every save.
  void replaceFromSync(FilterRuleSet merged) {
    state = merged;
  }
}

final gmailFilterRulesProvider =
    StateNotifierProvider<GmailFilterRulesController, FilterRuleSet>((ref) {
  // The store reads from Firestore via the SDK — no Cloud Run
  // round-trip. Defaults are returned until the cache is primed; the
  // controller's state is replaced when either the local mirror or
  // the cloud copy resolves so the UI sees the right rules without
  // flickering through defaults.
  final store = FilterRuleStore(ref.watch(accountsRepoProvider));
  final controller = GmailFilterRulesController(
    store,
    FilterRuleSet.defaults,
  );
  Future.microtask(() async {
    // Local mirror first — the user might have started editing a rule
    // and the app died before they hit Save. Showing the cloud copy
    // would discard their in-progress edits and feel like the app
    // "forgot" what they typed. The cloud fetch comes next and
    // replaces it once the network round-trip lands.
    final local = await store.readLocalMirror();
    if (local != null) {
      controller.replaceFromSync(local);
    }
    final loaded = await store.loadFromDisk();
    controller.replaceFromSync(loaded);
  });
  return controller;
});

/// Pushes the user's [FilterRuleSet] to the server so it can mirror
/// to the user's Gmail account via the Gmail filters API. Used by
/// the Email filters Save button and the agent widget's filter
/// actions — both call [RuleSyncService.saveNow] directly. Earlier
/// versions also ran a debounced auto-sync from
/// [fcmBridgeProvider]'s listener, but that produced spurious
/// delete/recreate churn when intermediate states hit the server.
final ruleSyncServiceProvider = Provider<RuleSyncService>((ref) {
  // Wire the post-sync callback so the merged set (with Gmail-ids)
  // flows back into the controller state — otherwise the next save
  // churns through delete+recreate on the server. The shared
  // FilterRuleStore writes the merged set back to the cloud so the
  // next save can find Gmail ids.
  return RuleSyncService(
    auth: ref.watch(gmailAuthProvider),
    filterStore: FilterRuleStore(ref.watch(accountsRepoProvider)),
    onSynced: (merged) {
      ref.read(gmailFilterRulesProvider.notifier).replaceFromSync(merged);
    },
  );
});

/// The email address allowed to reach admin-only surfaces (the
/// bundled architecture doc tile in Settings). Hard-coded here rather
/// than in shared_prefs because exposing it as a setting would defeat
/// the gate.
const String kInfraAdminEmail = 'medisujith@gmail.com';
