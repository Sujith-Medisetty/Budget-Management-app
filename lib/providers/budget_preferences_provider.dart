import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/account_record.dart';
import '../data/services/accounts_repo.dart';
import 'providers.dart';

/// Budget-related user preferences. Currently a single toggle —
/// `autoMonthlyBudget` — that controls whether the server mints a
/// fresh `"&lt;MonthName&gt; Expenses"` row on the 1st of every
/// month and on sign-in. Mirrors the same explicit-save UX as
/// `BackupPreferences`: setters stage in memory, Save flushes via
/// `PATCH /accounts/&lt;sub&gt;`. Auto-save semantics would make
/// sense for a single boolean, but matching the Backup screen's
/// Save button keeps the Settings surface visually consistent and
/// gives the user a single undo path (cancel = Back) for every
/// per-user pref change.
///
/// Default is OFF — auto-create is opt-in. Flipping the toggle ON
/// from the Settings screen is a one-tap "make me a budget for this
/// month" affordance: the server's PATCH handler detects the
/// false→true transition and runs `ensureCurrentMonthBudget` as a
/// side-effect, returning the minted row in the response so the
/// mobile can mirror it locally. Toggling OFF is intentionally
/// non-destructive — existing budgets are never deleted or modified.
///
/// Storage: `accounts.budget_prefs` JSONB column on the server
/// (default `{ "autoMonthlyBudget": false }`). The Settings screen
/// reads via `GET /accounts/<sub>` on open and writes via
/// `PATCH /accounts/<sub>` on Save. There is no local SQLite mirror
/// — keeping the cloud round-trip read-only on this field means a
/// sign-in on a second device picks up the same toggle state.
class BudgetPreferences {
  const BudgetPreferences({
    required this.autoMonthlyBudget,
    required this.loaded,
    this.lastSavedAt,
    this.loadError,
  });

  /// Whether the server should auto-create a `"&lt;MonthName&gt;
  /// Expenses"` budget on the 1st of every month and on sign-in.
  /// Default false — auto-create is opt-in. Flipping the toggle
  /// ON runs the side-effect mint on the server; flipping OFF does
  /// not delete or modify any existing budgets.
  final bool autoMonthlyBudget;

  final DateTime? lastSavedAt;

  /// True after the first `GET /accounts/<sub>` completed (success or
  /// failure). UI uses this to render a loading state on cold start
  /// — before this flips, the toggle is the default value (`true`)
  /// and would lie to a user who has toggled it OFF on the server.
  final bool loaded;

  final String? loadError;

  BudgetPreferences copyWith({
    bool? autoMonthlyBudget,
    DateTime? lastSavedAt,
    bool? loaded,
    String? loadError,
    bool clearLoadError = false,
  }) {
    return BudgetPreferences(
      autoMonthlyBudget: autoMonthlyBudget ?? this.autoMonthlyBudget,
      lastSavedAt: lastSavedAt ?? this.lastSavedAt,
      loaded: loaded ?? this.loaded,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
    );
  }

  static const defaults = BudgetPreferences(
    autoMonthlyBudget: false,
    loaded: false,
  );
}

class BudgetPreferencesController extends StateNotifier<BudgetPreferences> {
  BudgetPreferencesController({
    required AccountsRepo repo,
  })  : _repo = repo,
        super(BudgetPreferences.defaults) {
    _load();
  }

  final AccountsRepo _repo;

  bool _dirty = false;
  bool get isDirty => _dirty;

  Future<void> _load() async {
    if (kDebugMode) {
      debugPrint('[budget-prefs] _load() start');
    }
    try {
      final record = await _repo.fetch();
      if (record != null) {
        _applyRecord(record);
      } else {
        if (kDebugMode) {
          debugPrint('[budget-prefs] _load: no record — keeping defaults');
        }
        state = state.copyWith(loaded: true, clearLoadError: true);
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[budget-prefs] _load failed: $e\n$st');
      }
      state = state.copyWith(loaded: true, loadError: e.toString());
    }
  }

  void _applyRecord(AccountRecord r) {
    state = BudgetPreferences(
      autoMonthlyBudget: r.budgetAutoMonthlyBudget,
      loaded: true,
    );
    _dirty = false;
  }

  /// Re-fetches from the server. Exposed so the settings screen can
  /// refresh when the user navigates back from another flow that
  /// might have changed the cloud state (currently nothing else
  /// does — but the Backup screen's pattern is "always re-read on
  /// open", and this stays symmetric).
  Future<void> refresh() => _load();

  // -- Stage-only setters ------------------------------------------------
  // Same pattern as BackupPreferences: stage in memory, _dirty flips,
  // save() flushes via single PATCH.

  void setAutoMonthlyBudget(bool v) {
    state = state.copyWith(autoMonthlyBudget: v);
    _dirty = true;
  }

  // -- Cloud flush -------------------------------------------------------

  /// Flush staged state to the server. No-op when nothing has changed
  /// since the last save (or initial load).
  Future<BudgetSaveResult> save() async {
    if (!_dirty) return BudgetSaveResult.success();

    try {
      await _repo.updateBudgetPrefs({
        'autoMonthlyBudget': state.autoMonthlyBudget,
      });
    } catch (e) {
      return BudgetSaveResult.failure(
          'cloud save failed: ${e.toString()}');
    }

    state = state.copyWith(lastSavedAt: DateTime.now());
    _dirty = false;
    return BudgetSaveResult.success();
  }
}

class BudgetSaveResult {
  const BudgetSaveResult._({required this.success, this.reason});
  factory BudgetSaveResult.success() =>
      const BudgetSaveResult._(success: true);
  factory BudgetSaveResult.failure(String reason) =>
      BudgetSaveResult._(success: false, reason: reason);

  final bool success;
  final String? reason;
}

/// `budgetPreferencesProvider` — read by the Settings screen.
/// Watches `accountsRepoProvider` so a token refresh / rehydrate in
/// the parent's `GmailAuth` listener naturally re-fires the
/// controller's `_load()` on rebuild.
final budgetPreferencesProvider =
    StateNotifierProvider<BudgetPreferencesController, BudgetPreferences>(
  (ref) {
    final repo = ref.watch(accountsRepoProvider);
    return BudgetPreferencesController(repo: repo);
  },
);
