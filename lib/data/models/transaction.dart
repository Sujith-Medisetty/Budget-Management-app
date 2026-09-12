/// One captured payment from PayPal or Google Pay.
///
/// Sign convention: positive = money out, negative = money in (matches
/// what the rule parser produces and what the budget math expects).
///
/// [ignored] = user-marked as not part of their spend. Still listed
/// (struck through) for transparency, but excluded from every spend
/// aggregation (`spentBetween`, day totals, budget alerts). Default
/// false so auto-captured transactions participate in budgets unless
/// the user explicitly opts out.
class Transaction {
  Transaction({
    required this.id,
    required this.notificationKey,
    required this.source,
    required this.amount,
    required this.merchant,
    this.reason,
    required this.occurredAt,
    this.ignored = false,
  });

  final int? id;
  final String notificationKey;
  final String source; // 'paypal' | 'google_pay' | 'gmail' | 'manual'
  final double amount;
  final String merchant;
  final String? reason;
  final DateTime occurredAt;
  final bool ignored;

  Transaction copyWith({
    int? id,
    String? notificationKey,
    String? source,
    double? amount,
    String? merchant,
    String? reason,
    DateTime? occurredAt,
    bool? ignored,
  }) {
    return Transaction(
      id: id ?? this.id,
      notificationKey: notificationKey ?? this.notificationKey,
      source: source ?? this.source,
      amount: amount ?? this.amount,
      merchant: merchant ?? this.merchant,
      reason: reason ?? this.reason,
      occurredAt: occurredAt ?? this.occurredAt,
      ignored: ignored ?? this.ignored,
    );
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'notification_key': notificationKey,
    'source': source,
    'amount': amount,
    'merchant': merchant,
    'reason': reason,
    'occurred_at': occurredAt.millisecondsSinceEpoch,
    'ignored': ignored ? 1 : 0,
  };

  factory Transaction.fromMap(Map<String, Object?> m) => Transaction(
    id: m['id'] as int?,
    notificationKey: m['notification_key'] as String,
    source: m['source'] as String,
    amount: (m['amount'] as num).toDouble(),
    merchant: m['merchant'] as String,
    reason: m['reason'] as String?,
    occurredAt: DateTime.fromMillisecondsSinceEpoch(m['occurred_at'] as int),
    ignored: ((m['ignored'] as int?) ?? 0) != 0,
  );

  /// Display name for a [source] value. Centralized so the row in
  /// the dashboard, the row in the transactions list, and the
  /// "Captured" notification all show the same label.
  static String labelFor(String source) {
    switch (source) {
      case 'paypal':
        return 'PayPal';
      case 'gmail':
        return 'Gmail';
      case 'manual':
        return 'Manual';
      case 'google_pay':
      default:
        return 'Google Pay';
    }
  }
}