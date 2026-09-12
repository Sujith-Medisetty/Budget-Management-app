/// Parser output. Mirrors the fields the DB stores. Sign convention:
/// positive = money out, negative = money in.
class ParsedTransaction {
  ParsedTransaction({
    required this.amount,
    required this.merchant,
    this.reason,
    required this.source,
    required this.confidence,
  });

  final double amount;
  final String merchant;
  final String? reason;
  final String source; // 'paypal' | 'google_pay'
  final double confidence;
}