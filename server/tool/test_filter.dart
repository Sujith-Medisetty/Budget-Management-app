import 'package:pocket_server/gmail_filter_rules.dart';

void main() {
  final rules = FilterRuleSet(
    enabled: true,
    logic: Logic.or,
    rules: [
      FilterRule(
        sender: const RuleField(value: 'p', matchType: MatchType.contains),
        subject: const RuleField(
            value: 'Credit card transaction exceeds alert limit you set',
            matchType: MatchType.contains),
      ),
    ],
  );
  const from = 'service@paypal.com';
  const subject = 'You sent \$29.99 to Amazon';
  const body = 'You sent \$29.99 USD to Amazon.';
  final allow = rules.allows(from: from, subject: subject, body: body);
  print('allows: $allow (expect false → message should be dropped)');
}
