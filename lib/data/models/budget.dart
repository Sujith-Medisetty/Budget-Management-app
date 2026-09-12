/// A user-defined spending budget. Period is inclusive on both ends —
/// the pipeline sums transactions whose [Transaction.occurredAt] falls
/// in [startDate, endDate] when evaluating alerts.
///
/// Alert preferences come in two flavors that are mutually exclusive:
///   - [alertEvery] = true  → notify on every transaction against the budget.
///   - [alertEvery] = false → notify only when spent% crosses one of the
///                             percentages in [alertThresholds] (e.g. [50, 80, 100]).
class Budget {
  Budget({
    required this.id,
    required this.name,
    required this.amount,
    required this.period,
    required this.startDate,
    required this.endDate,
    required this.alertEvery,
    required this.alertThresholds,
    required this.active,
    required this.createdAt,
  });

  final int? id;
  final String name;
  final double amount;
  final BudgetPeriod period;
  final DateTime startDate;
  final DateTime endDate;
  final bool alertEvery;
  final List<int> alertThresholds;
  final bool active;
  final DateTime createdAt;

  Budget copyWith({
    int? id,
    String? name,
    double? amount,
    BudgetPeriod? period,
    DateTime? startDate,
    DateTime? endDate,
    bool? alertEvery,
    List<int>? alertThresholds,
    bool? active,
    DateTime? createdAt,
  }) {
    return Budget(
      id: id ?? this.id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      period: period ?? this.period,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      alertEvery: alertEvery ?? this.alertEvery,
      alertThresholds: alertThresholds ?? this.alertThresholds,
      active: active ?? this.active,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'amount': amount,
    'period': period.name,
    'start_date': _ymd(startDate),
    'end_date': _ymd(endDate),
    'alert_every': alertEvery ? 1 : 0,
    'alert_thresholds': alertThresholds.join(','),
    'active': active ? 1 : 0,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory Budget.fromMap(Map<String, Object?> m) => Budget(
    id: m['id'] as int?,
    name: m['name'] as String,
    amount: (m['amount'] as num).toDouble(),
    period: BudgetPeriod.values.firstWhere(
      (p) => p.name == m['period'],
      orElse: () => BudgetPeriod.monthly,
    ),
    startDate: DateTime.parse(m['start_date'] as String),
    endDate: DateTime.parse(m['end_date'] as String),
    alertEvery: (m['alert_every'] as int? ?? 0) == 1,
    alertThresholds: parseThresholds(m['alert_thresholds'] as String?),
    active: (m['active'] as int? ?? 0) == 1,
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
  );

  /// Public version of the threshold parser — used by both
  /// [Budget.fromMap] (read path) and `BackupService` (restore path)
  /// so the two never drift on what's a valid threshold.
  static List<int> parseThresholds(String? raw) {
    if (raw == null || raw.isEmpty) return const [80, 100];
    return raw
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .where((t) => t > 0 && t <= 200)
        .toList(growable: false);
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

enum BudgetPeriod { weekly, monthly, custom }

extension BudgetPeriodLabel on BudgetPeriod {
  String get label => switch (this) {
    BudgetPeriod.weekly => 'Weekly',
    BudgetPeriod.monthly => 'Monthly',
    BudgetPeriod.custom => 'Custom',
  };

  /// Date range covering [reference] for this period.
  /// Weekly = Mon–Sun containing the reference. Monthly = 1st–last day.
  /// Custom = the budget's own [Budget.startDate, Budget.endDate]
  /// passed via [customRange]; if null, returns a single-day window
  /// around [reference] as a safe fallback.
  ({DateTime start, DateTime end}) range(
    DateTime reference, {
    ({DateTime start, DateTime end})? customRange,
  }) {
    switch (this) {
      case BudgetPeriod.weekly:
        final start = reference.subtract(Duration(days: reference.weekday - 1));
        final end = DateTime(
          start.year,
          start.month,
          start.day + 6,
        );
        return (start: DateTime(start.year, start.month, start.day), end: end);
      case BudgetPeriod.monthly:
        final start = DateTime(reference.year, reference.month, 1);
        final end0 = DateTime(reference.year, reference.month + 1, 1);
        final end = end0.subtract(const Duration(days: 1));
        return (start: start, end: end);
      case BudgetPeriod.custom:
        return customRange ??
            (
              start: DateTime(reference.year, reference.month, reference.day),
              end: DateTime(reference.year, reference.month, reference.day),
            );
    }
  }
}

/// The threshold options we surface in the form's multi-select chips.
/// The integer value is the percentage (101 = "Over budget" — alerts
/// fire whenever spent strictly exceeds budget amount).
const budgetAlertThresholdChoices = <int>[50, 80, 100, 101];

String budgetAlertThresholdLabel(int t) => switch (t) {
  101 => 'Over',
  _ => '$t%',
};