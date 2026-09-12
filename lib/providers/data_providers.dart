import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/ai_log_entry.dart';
import '../data/models/budget.dart';
import '../data/models/transaction.dart';
import '../data/repositories/ai_log_store.dart';
import '../data/services/backup_service.dart';
import 'backup_provider.dart';
import 'budget_preferences_provider.dart';
import 'providers.dart';

/// The single active budget, or null. Drives the dashboard.
final activeBudgetProvider = FutureProvider<Budget?>((ref) async {
  final repo = ref.watch(budgetRepoProvider);
  return repo.firstActive();
});

/// All budgets (active and inactive). Drives the Budgets tab list.
final budgetsProvider = FutureProvider<List<Budget>>((ref) async {
  final repo = ref.watch(budgetRepoProvider);
  return repo.all();
});

/// Async list of all transactions, newest first. Drives the global
/// Transactions tab.
final transactionsProvider = FutureProvider<List<Transaction>>((ref) async {
  final repo = ref.watch(transactionRepoProvider);
  return repo.recent();
});

/// Transactions inside the active budget's current period window.
/// Drives the BudgetDetailScreen.
final budgetTransactionsProvider =
    FutureProvider.family<List<Transaction>, Budget>((ref, budget) async {
      final repo = ref.watch(transactionRepoProvider);
      final now = DateTime.now();
      final range = budget.period.range(
        now,
        customRange: (start: budget.startDate, end: budget.endDate),
      );
      final start = budget.startDate.isAfter(range.start)
          ? budget.startDate
          : range.start;
      final end = budget.endDate.isBefore(range.end)
          ? budget.endDate
          : range.end;
      return repo.inRange(start, end);
    });

/// Newest-first list of the last 30 AI parse attempts (kept or
/// dropped). Drives the Activity log screen. The parser / pipeline
/// write to the underlying [AiLogStore] directly and call
/// [invalidateAiLogProvider] so the list refreshes.
final aiLogProvider = FutureProvider<List<AiLogEntry>>((ref) async {
  return AiLogStore.list();
});

/// Bumps the data providers + the AI activity log — used after a
/// notification insert so the dashboard / transactions / log screens
/// all refresh.
void invalidateDataProviders(WidgetRef ref) {
  ref.invalidate(activeBudgetProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(aiLogProvider);
}

/// Bumps only the AI activity log — used by the parser / pipeline
/// after a log row is inserted.
void invalidateAiLogProvider(WidgetRef ref) {
  ref.invalidate(aiLogProvider);
}

/// Fire-and-forget Gmail envelope pull. Used from the app-resume
/// hook so the phone catches up on envelopes that piled up in
/// Firestore while the device was offline (FCM can't deliver without
/// a live push channel, but the Firestore envelope queue is durable
/// — see `pubsub_handler.dart`). Idempotent: if the server has
/// nothing new, the high-water mark advances and the call returns 0
/// without touching SQLite. Errors are swallowed because the resume
/// path can't surface a UI; the user can always retry manually via
/// "Sync Gmail now" in Connected Accounts.
void syncGmailOnResume(WidgetRef ref) {
  // ignore: discarded_futures
  ref.read(gmailSyncProvider).fetchNew().catchError((_) => 0);
}

/// Pulls the user's cloud backup into local SQLite after a fresh
/// sign-in so the phone matches the authoritative snapshot. Used by
/// every place that calls `GmailAuth.signIn()` (settings, onboarding,
/// agent) so the post-sign-in experience is identical regardless of
/// the entry point.
///
/// Why this lives at the UI level instead of a Riverpod hook:
/// `backupServiceProvider` watches `gmailAuthProvider`, so the natural
/// "auto-restore on sign-in" provider setup would form a cycle. The
/// try-once retry inside `GmailAuth.signIn()` is the only thing
/// depending on this service, and since the sign-in call site already
/// holds a `WidgetRef`, doing the restore there keeps Riverpod's
/// dependency graph acyclic and mirrors the manual "Restore from
/// cloud" path byte-for-byte.
///
/// On success the dashboard / budgets / activity-log providers are
/// invalidated so any already-mounted screen re-fetches. On a 404
/// (no backup yet — first-time sign-in) or any other failure the
/// error is returned and the caller decides whether to show it.
Future<BackupResult> autoRestoreAfterSignIn(WidgetRef ref) async {
  // Build the service with the same GmailAuth singleton the providers
  // use, but skip the provider so we don't touch its dependency graph.
  final auth = ref.read(gmailAuthProvider);
  // Self-heal the per-user Cloud Scheduler job (re-create it if a
  // server-side wipe or deploy migration removed it) BEFORE pulling
  // the SQLite snapshot. Best-effort — failures are logged, never
  // thrown. The Backup / Filter screens read prefs from the cloud on
  // first paint, so we invalidate them here too so the very first
  // render after this call reflects the just-hydrated state.
  await ref.read(accountHydratorProvider).hydrate();
  ref.invalidate(backupPreferencesProvider);
  ref.invalidate(gmailFilterRulesProvider);
  // Refresh the budget-prefs toggle from the freshly-hydrated
  // record so a future toggle-the-auto-off-from-another-device
  // change is reflected on this device without a manual pull.
  ref.invalidate(budgetPreferencesProvider);
  // Pull the cloud snapshot first — this opens a SQLite transaction
  // that wipes + re-inserts budgets/transactions. The auto-create
  // hydrator MUST run AFTER this completes, otherwise its insert
  // races with the restore's wipe: a row minted server-side + mirrored
  // locally would be deleted by the restore's `delete('budgets')`
  // before the user ever sees it. Awaiting it sequentially kills the
  // race; the hydrator's own (name, startDate) dedupe still applies,
  // so re-runs are still no-ops.
  final result = await BackupService(auth: auth).restore();
  await ref.read(budgetHydratorProvider).ensureCurrentMonth();
  if (result.success) {
    invalidateDataProviders(ref);
  }
  return result;
}