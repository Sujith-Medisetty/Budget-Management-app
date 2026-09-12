import '../../data/models/budget.dart';
import '../../data/repositories/budget_repository.dart';

/// Names a default budget after the current month — "September Expenses",
/// "October Expenses", etc. Used during onboarding to seed the table so
/// the dashboard is alive the first time the user opens it.
String defaultBudgetNameFor(DateTime reference) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  return '${months[reference.month - 1]} Expenses';
}

/// Creates a default monthly budget via [repo] if the budgets table is
/// empty. No-op when at least one budget already exists — safe to call
/// every cold start (idempotent via the table-empty guard).
///
/// Returns the inserted budget, or null if a budget already existed.
/// The repo is passed in (rather than obtained via Riverpod) so this
/// function is trivially testable without a `ProviderContainer`.
Future<Budget?> ensureDefaultBudget(BudgetRepository repo) async {
  final existing = await repo.all();
  if (existing.isNotEmpty) return null;

  final now = DateTime.now();
  final range = BudgetPeriod.monthly.range(now);
  final draft = Budget(
    id: null,
    name: defaultBudgetNameFor(now),
    amount: 500,
    period: BudgetPeriod.monthly,
    startDate: range.start,
    endDate: range.end,
    alertEvery: false,
    alertThresholds: const [80, 100],
    active: true,
    createdAt: now,
  );
  final inserted = await repo.insert(draft);
  if (inserted != null) {
    // Activate explicitly so the single-active invariant is set even
    // when this is the very first row (insert defaults `active=1`).
    await repo.activate(inserted);
  }
  return inserted;
}