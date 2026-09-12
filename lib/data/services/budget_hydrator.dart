import 'package:flutter/foundation.dart';

import '../models/budget.dart';
import '../repositories/budget_repository.dart';
import 'budgets_api.dart';

/// Bridges the server's auto-create flow into the local SQLite
/// `budgets` table. After sign-in, the server decides whether to mint a
/// new row; this hydrator mirrors the outcome onto the device. Idempotent
/// + best-effort — any network/decoding error is logged but never thrown.
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

      // Match on (name, startDate) — server UUID and device autoincrement
      // live in different id spaces, so neither side can cross-reference.
      final existing = await repo.all();
      final matches = existing.where((b) =>
          b.name == payload.name &&
          _ymd(b.startDate) == _ymd(payload.startDate));
      if (matches.isNotEmpty) {
        final local = matches.first;
        final serverEvery = payload.alertEvery;
        final serverThresholds = payload.alertThresholds == null
            ? null
            : Budget.parseThresholds(payload.alertThresholds);
        final everyChanged = serverEvery != null &&
            serverEvery != local.alertEvery;
        final thresholdsChanged = serverThresholds != null &&
            !listEquals(serverThresholds, local.alertThresholds);
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

      // (name, startDate) guard above rules out INSERT conflict, so inserted is non-null.
      final inserted = (await repo
          .insert(payload.toMobileBudget().copyWith(id: null)))!;
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

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
