import '../models/budget.dart';
import '../models/transaction.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import 'notification_service.dart';

/// Evaluates the (single) active budget against a new transaction and
/// fires a local notification when:
///   - the budget has [Budget.alertEvery] = true (every transaction fires), or
///   - the spent% crosses a percentage in [Budget.alertThresholds] for the
///     first time this period.
///
/// "Every" mode is intentionally not deduped — the user opted into noise.
/// Threshold alerts are idempotent across (budget, threshold, period) via
/// [BudgetRepository.hasFiredAlert].
class BudgetAlerter {
  BudgetAlerter(this._txRepo, this._budgetRepo)
    : _notifier = NotificationService.instance;

  BudgetAlerter.withNotifier(
    this._txRepo,
    this._budgetRepo,
    NotificationService notifier,
  ) : _notifier = notifier;

  final TransactionRepository _txRepo;
  final BudgetRepository _budgetRepo;
  final NotificationService _notifier;

  /// Public read-only access to the budget repository so the capture
  /// pipeline can compute the same active-budget snapshot without
  /// duplicating the date math. The pipeline can't call
  /// `activeBudgetSnapshot()` directly because it's a static that
  /// needs both repos; passing them in here keeps the wiring local
  /// to this file.
  BudgetRepository get budgetRepo => _budgetRepo;

  Future<void> evaluate(Transaction t) async {
    final b = await _budgetRepo.firstActive();
    if (b == null || b.id == null) return;

    final now = DateTime.now();
    final range = b.period.range(
      now,
      customRange: (start: b.startDate, end: b.endDate),
    );
    final start = b.startDate.isAfter(range.start) ? b.startDate : range.start;
    final end = b.endDate.isBefore(range.end) ? b.endDate : range.end;

    final spent = await _txRepo.spentBetween(start, end);
    if (spent <= 0 && b.alertEvery) {
      if (b.alertEvery) await _fireEvery(b, t, spent);
      return;
    }
    if (spent <= 0) return;

    if (b.alertEvery) {
      await _fireEvery(b, t, spent);
      // Don't return — also fire threshold alerts so milestones still
      // land in the shade-of-noisy feed.
    }

    final pct = (spent / b.amount) * 100;
    final thresholds = b.alertThresholds.isEmpty
        ? const [80, 100]
        : b.alertThresholds;
    for (final threshold in thresholds) {
      final crossed = threshold >= 100
          ? spent > b.amount
          : pct >= threshold;
      if (!crossed) continue;
      if (await _budgetRepo.hasFiredAlert(
        budgetId: b.id!,
        threshold: threshold,
        periodStart: range.start,
      )) {
        continue;
      }
      await _budgetRepo.recordAlert(
        budgetId: b.id!,
        threshold: threshold,
        periodStart: range.start,
      );
      await _fireThreshold(b, t, spent, end, threshold);
    }
  }

  Future<void> _fireEvery(
    Budget b,
    Transaction t,
    double spent,
  ) async {
    final now = DateTime.now();
    final range = b.period.range(
      now,
      customRange: (start: b.startDate, end: b.endDate),
    );
    final end = b.endDate.isBefore(range.end) ? b.endDate : range.end;
    await _notifier.showBudgetAlert(
      tone: 'milestone',
      // No threshold header on the always-on path — fires one per
      // transaction, so the threshold-crossed header would be
      // redundant noise.
      content: _buildContent(
        budget: b,
        trigger: t,
        spent: spent,
        periodEnd: end,
      ),
      // Unique id per fire so back-to-back transactions don't replace
      // each other. Multiply by 1000 to leave room below for the
      // threshold-alert id range (b.id * 100 + threshold ≤ b.id * 199).
      id: ((b.id ?? 0) + 1) * 100000 +
          DateTime.now().millisecondsSinceEpoch.remainder(100000),
    );
  }

  Future<void> _fireThreshold(
    Budget b,
    Transaction trigger,
    double spent,
    DateTime periodEnd,
    int threshold,
  ) async {
    final tone = switch (threshold) {
      >= 101 => 'over',
      100 => 'full',
      _ => 'milestone',
    };
    await _notifier.showBudgetAlert(
      tone: tone,
      // Threshold parameter makes the body prepend "Budget crossed
      // X% threshold" so the user can tell threshold alerts apart
      // from always-on pings in the shade.
      threshold: threshold,
      content: _buildContent(
        budget: b,
        trigger: trigger,
        spent: spent,
        periodEnd: periodEnd,
      ),
      id: (b.id ?? 0) * 100 + threshold,
    );
  }

  /// Build the [BudgetAlertContent] payload. Pulls together everything
  /// the notification renderer needs:
  ///   - the trigger transaction (merchant + amount) for the headline
  ///   - spent / budget / remaining / percent used
  ///   - per-day allowance for the remainder of the budget window
  ///
  /// Exposed as a static so the capture-pipeline path can build the
  /// same content for the "captured" notification without round-
  /// tripping through the alerter's threshold/recordAlert side effects.
  static BudgetAlertContent buildContent({
    required Budget budget,
    required Transaction trigger,
    required double spent,
    required DateTime periodEnd,
  }) {
    final remaining = budget.amount - spent;
    final percentUsed = ((spent / budget.amount) * 100).round().clamp(0, 999);

    final today = DateTime.now();
    final startOfPeriodEnd = DateTime(
      periodEnd.year,
      periodEnd.month,
      periodEnd.day,
    );
    final startOfToday = DateTime(today.year, today.month, today.day);
    final daysLeft =
        startOfPeriodEnd.difference(startOfToday).inDays;
    // Inclusive of today: if period ends tomorrow, that's 1 day left
    // (today + tomorrow).
    final effectiveDaysLeft = daysLeft + 1;
    final perDay = effectiveDaysLeft > 0 && remaining > 0
        ? remaining / effectiveDaysLeft
        : 0.0;

    return BudgetAlertContent(
      budgetName: budget.name,
      recentExpenseMerchant: trigger.merchant,
      recentExpenseAmount: trigger.amount.abs(),
      recentExpenseAt: trigger.occurredAt,
      spent: spent,
      budgetAmount: budget.amount,
      remaining: remaining,
      perDayLeft: perDay,
      percentUsed: percentUsed,
      periodEnd: periodEnd,
    );
  }

  BudgetAlertContent _buildContent({
    required Budget budget,
    required Transaction trigger,
    required double spent,
    required DateTime periodEnd,
  }) =>
      buildContent(
        budget: budget,
        trigger: trigger,
        spent: spent,
        periodEnd: periodEnd,
      );

  /// Compute the (budget, period-end, spent-tuple) for an active
  /// budget against a reference [now]. Returns null when there's no
  /// active budget — callers handle that as "no budget context".
  /// Public so the capture pipeline can build the same content
  /// without duplicating the date math.
  static Future<({Budget budget, DateTime periodEnd, double spent})?>
      activeBudgetSnapshot(
    TransactionRepository txRepo,
    BudgetRepository budgetRepo, {
    DateTime? now,
  }) async {
    final b = await budgetRepo.firstActive();
    if (b == null || b.id == null) return null;
    final ref = now ?? DateTime.now();
    final range = b.period.range(
      ref,
      customRange: (start: b.startDate, end: b.endDate),
    );
    final start = b.startDate.isAfter(range.start) ? b.startDate : range.start;
    final end = b.endDate.isBefore(range.end) ? b.endDate : range.end;
    final spent = await txRepo.spentBetween(start, end);
    return (budget: b, periodEnd: end, spent: spent);
  }
}