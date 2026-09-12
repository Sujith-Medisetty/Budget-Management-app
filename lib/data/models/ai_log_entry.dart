/// One row of the AI parse log. Written by the parser, the pipeline,
/// and the Gmail capture paths so the user can see exactly what
/// arrived, what the model said, and why a row was kept or dropped.
///
/// Kept rows: `decision == 'kept'`, `parsedAmount/Merchant/Source`
/// populated, `reason == null`.
/// Dropped rows: `decision == 'dropped'`, `reason` explains why
/// (e.g. 'AI: skip=true (P2P incoming)', 'amount missing',
/// 'duplicate', 'filter rule rejected').
class AiLogEntry {
  AiLogEntry({
    required this.id,
    required this.ts,
    required this.package,
    required this.sourceText,
    required this.aiResponse,
    required this.decision,
    required this.reason,
    required this.parsedAmount,
    required this.parsedMerchant,
    required this.parsedSource,
  });

  final int? id;
  final DateTime ts;
  final String package;
  final String sourceText;
  final String? aiResponse;
  final String decision; // 'kept' | 'dropped'
  final String? reason;
  final double? parsedAmount;
  final String? parsedMerchant;
  final String? parsedSource;

  bool get isKept => decision == 'kept';

  Map<String, Object?> toMap() => {
    'id': id,
    'ts': ts.millisecondsSinceEpoch,
    'package': package,
    'source_text': sourceText,
    'ai_response': aiResponse,
    'decision': decision,
    'reason': reason,
    'parsed_amount': parsedAmount,
    'parsed_merchant': parsedMerchant,
    'parsed_source': parsedSource,
  };

  factory AiLogEntry.fromMap(Map<String, Object?> m) => AiLogEntry(
    id: m['id'] as int?,
    ts: DateTime.fromMillisecondsSinceEpoch(m['ts'] as int),
    package: m['package'] as String,
    sourceText: m['source_text'] as String,
    aiResponse: m['ai_response'] as String?,
    decision: m['decision'] as String,
    reason: m['reason'] as String?,
    parsedAmount: (m['parsed_amount'] as num?)?.toDouble(),
    parsedMerchant: m['parsed_merchant'] as String?,
    parsedSource: m['parsed_source'] as String?,
  );
}
