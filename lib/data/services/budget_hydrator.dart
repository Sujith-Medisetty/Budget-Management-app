import 'package:flutter/foundation.dart';

import '../models/budget.dart';
import '../repositories/budget_repository.dart';
import 'budgets_api.dart';

/// Bridges the server's auto-create flow into the local SQLite
/// `budgets` table. After a successful sign-in, the server's
/// `GET /budgets/ensure-current` handler decides whether to mint
/// a new `"&lt;MonthName&gt; Expenses"` row based on the user's
/// stored `budgetPrefs.autoMonthlyBudget`. This hydrator mirrors
/// the server's outcome onto the device:
///
///   - `alreadyExisted` — the server already had a row. If the
///     device doesn't yet have a matching row (matched on
///     (name, startDate) since the server's UUID id and the
///     device's autoincrement id don't share a space), insert it.
///   - `createdNow` — the server minted a fresh row. Same
///     (name, startDate) match-then-insert path so re-runs are
///     idempotent.
///   - `userOptedOut` — the user has the auto-create toggle off
///     on the server. Do nothing on the device; the user can
///     still create budgets manually via the Budgets screen.
///
/// Idempotent + best-effort (any network/decoding error is logged
/// but never thrown — the sign-in flow can't be blocked by an
/// off-budget cross-system call).
class BudgetHydrator {
  BudgetHydrator({required this.api, required this.repo});

  final BudgetsApi api;
  final BudgetRepository repo;

  Future<void> ensureCurrentMonth() async {
    try {
      final outcome = await api.ensureCurrentMonth();
      if (kDebugMode) {
        debugPrint(
            '[budget-hydrator] server result=${outcome.result.name} '
            'name=${outcome.budget?.name}');
      }
      final payload = outcome.budget;
      if (payload == null) return;

      // Match on (name, startDate) since the server's UUID and the
      // device's autoincrement never collide. YYYY-MM-DD comparing
      // strings is safe because both come from a month-rollover
      // helper that produces the same canonical form.
      final existing = await repo.all();
      final matches = existing.where((b) =>
          b.name == payload.name &&
          _ymd(b.startDate) == _ymd(payload.startDate));
      if (matches.isNotEmpty) {
        // The device already has this budget. The server's row is
        // the cross-device source of truth for alert prefs (mobile
        // syncs via `BudgetsApi.patchAlertPrefs` on every edit), so
        // mirror any change onto the local row here. Without this
        // step, the user's notify mode would revert to whatever
        // R2-backup-or-defaults held at restore time — even after a
        // fresh edit on another device had been pushed to the
        // server. We only update fields the server explicitly
        // carries (alertEvery / alertThresholds); name / amount /
        // period are device-local.
        final local = matches.first;
        final serverEvery = payload.alertEvery;
        final serverThresholds = payload.alertThresholds == null
            ? null
            : Budget.parseThresholds(payload.alertThresholds);
        final everyChanged = serverEvery != null &&
            serverEvery != local.alertEvery;
        final thresholdsChanged = serverThresholds != null &&
            !_listEq(serverThresholds, local.alertThresholds);
        if (everyChanged || thresholdsChanged) {
          final updated = local.copyWith(
            alertEvery: serverEvery ?? local.alertEvery,
            alertThresholds: serverThresholds ?? local.alertThresholds,
          );
          await repo.update(updated);
          if (kDebugMode) {
            debugPrint('[budget-hydrator] refreshed alert prefs on '
                '${payload.name}: alertEvery '
                '${local.alertEvery}→${updated.alertEvery}, '
                'thresholds '
                '${local.alertThresholds}→${updated.alertThresholds}');
          }
        } else if (kDebugMode) {
          debugPrint('[budget-hydrator] device already has '
              '${payload.name} for ${_ymd(payload.startDate)} '
              'with current alert prefs; no update');
        }
        return;
      }

      // Insert with id=null so SQLite mints a fresh autoincrement.
      // Active is whatever the server decided; the device's local
      // activate() helper enforces the at-most-one invariant on
      // next read. `inserted` is non-null in practice — the repo's
      // `insert` only returns null on an INSERT conflict, which the
      // (name, startDate) guard above already rules out — but the
      // static type lets through a `Budget?` so the `!` is needed.
      final inserted =
          await repo.insert(payload.toMobileBudget().copyWith(id: null));
      if (inserted == null) return;
      if (payload.active) {
        await repo.activate(inserted);
      }
      if (kDebugMode) {
        debugPrint('[budget-hydrator] inserted ${payload.name} '
            '(id=${inserted.id}, active=${inserted.active})');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[budget-hydrator] ensureCurrentMonth failed: $e');
      }
    }
  }

  static bool _listEq(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
