import 'package:logging/logging.dart';

import 'budgets_repo.dart';
import 'token_store.dart';

/// Month-name helper for auto-created budget labels. Returns the
/// English month name for the given 1..12 — short of just doing a
/// local-side `DateFormat.MMMM()` round-trip (and pulling intl as a
/// server dep). The phone renders the same string format with
/// `DateFormat.MMMM()`, which is "October" / "September" etc., so this
/// matches exactly.
const _monthNames = <String>[
  '', // 1-indexed; placeholder so [1] = 'January'.
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String monthName(int month) {
  if (month < 1 || month > 12) {
    throw ArgumentError('month must be 1..12, got $month');
  }
  return _monthNames[month];
}

/// First day of the given calendar month in UTC. Used to compute
/// `start_date` (and the matching `end_date = next-month - 1 day`)
/// for an auto-created row.
///
/// `now` defaults to `DateTime.now().toUtc()` so callers in
/// non-UTC environments (the cron, which sees UTC; the handler,
/// which sees anything) both land on the same wall-clock month.
DateTime firstOfMonth({required int year, required int month}) =>
    DateTime.utc(year, month, 1);

/// Last day of the given calendar month in UTC. Computed by
/// subtracting 1 day from the first of the next month — Postgres
/// also supports this directly via `(date_trunc('month', $ts) +
/// interval '1 month - 1 day')::date` but doing it in Dart means
/// the same logic runs in tests with a mocked BudgetsRepo.
DateTime lastOfMonth({required int year, required int month}) {
  final nextMonth = month == 12 ? DateTime.utc(year + 1, 1, 1)
                                  : DateTime.utc(year, month + 1, 1);
  return nextMonth.subtract(const Duration(days: 1));
}

/// Result of [ensureCurrentMonthBudget]. Lets callers (sign-in
/// endpoint, cron) log what was done without the helper having to
/// know about HTTP responses.
enum EnsureResult { alreadyExisted, createdNow, userOptedOut }

/// Ensure a budget exists for the given sub + month.
///
/// Behavior:
///   - If `prefs.autoMonthlyBudget` is false → do NOT mint a new row.
///     Return whatever already exists for the month, or null when
///     none exists. Caller is expected to handle the null case
///     (typically: silently skip and let the user create one on the
///     device). [EnsureResult] reports whether we respected the opt-out.
///   - If a budget already exists for that month → return it
///     unchanged. (`EnsureResult.alreadyExisted`)
///   - If no budget exists for the month → mint one with:
///       name      = `<MonthName> Expenses` (e.g. "October Expenses")
///       amount    = the previous auto-created budget's amount, or 0
///                   for first-timers
///       active    = true iff no active budget currently exists for
///                   the sub
///       source    = 'auto'
///     [EnsureResult.createdNow].
///
/// `now` defaults to `DateTime.now().toUtc()` so the helper picks
/// the right month in UTC regardless of where the cron runs.
Future<({Budget? budget, EnsureResult result})> ensureCurrentMonthBudget({
  required String sub,
  required BudgetPrefs prefs,
  required BudgetsRepo budgets,
  DateTime? now,
}) async {
  final log = Logger('budget-rollover');
  final t = (now ?? DateTime.now()).toUtc();
  final monthStart = firstOfMonth(year: t.year, month: t.month);
  final monthEnd = lastOfMonth(year: t.year, month: t.month);

  // 1. Already present? Return as-is. This is the steady-state path
  //    for the sign-in endpoint and the cron's "second run of the
  //    month" case — both should be O(1).
  final existing = await budgets.listForSubInMonth(sub, monthStart);
  if (existing.isNotEmpty) {
    return (budget: existing.first, result: EnsureResult.alreadyExisted);
  }

  // 2. User has explicitly opted out of the auto-create flow. Don't
  //    mint; just let the caller handle the null.
  if (!prefs.autoMonthlyBudget) {
    log.info('sub=$sub opted out of autoMonthlyBudget for '
        '${t.year}-${t.month.toString().padLeft(2, "0")}; skipping mint');
    return (budget: null, result: EnsureResult.userOptedOut);
  }

  // 3. Mint a fresh row. Copy the cap from the latest auto row so
  //    users keep seeing the same monthly amount band; first-timers
  //    start at 0 (the device will offer a quick-edit affordance).
  final previous = await budgets.latestAuto(sub);
  final amount = previous?.amount ?? 0.0;

  // Auto-activate iff no active budget currently exists — that's the
  // first-budget-auto-activates invariant from the device side
  // mirrored here on the server. Once the user has picked one, we
  // don't override their choice on month rollover; they can flip
  // it themselves on the device.
  final hasActive = (await budgets.activeFor(sub)) != null;
  final shouldActivate = !hasActive;

  final fresh = await budgets.insert(
    sub: sub,
    name: '${monthName(t.month)} Expenses',
    amount: amount,
    period: 'monthly',
    startDate: monthStart,
    endDate: monthEnd,
    active: shouldActivate,
    source: 'auto',
  );
  if (shouldActivate) {
    await budgets.activate(sub, fresh.id);
  }
  log.info('minted ${fresh.name} (\$${fresh.amount.toStringAsFixed(2)}) '
      'for sub=$sub, month=${t.year}-${t.month.toString().padLeft(2, "0")}, '
      'active=$shouldActivate');
  return (budget: fresh, result: EnsureResult.createdNow);
}
