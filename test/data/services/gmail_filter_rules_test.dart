import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/data/services/gmail_filter_rules.dart';

void main() {
  group('FilterRuleSet.allows — empty rule handling (allowlist)', () {
    const from = 'paypal.com';
    const subject = 'You sent \$25.00';
    const body = 'You sent \$25.00 USD to acme@example.com';

    test('disabled + rules present → captures everything', () {
      const s = FilterRuleSet(
        enabled: false,
        logic: Logic.or,
        rules: [
          FilterRule(sender: RuleField(value: 'amazon', matchType: MatchType.contains)),
        ],
      );
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
    });

    test('enabled + zero rules → captures everything', () {
      const s = FilterRuleSet(enabled: true, logic: Logic.or, rules: []);
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
    });

    test('enabled + only empty rules → captures everything', () {
      // OR logic, filters on, but every rule has all fields null.
      // Empty rules are no-ops, so the allowlist is effectively empty
      // and every email passes.
      const s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [FilterRule(), FilterRule()],
      );
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
    });

    test('enabled + AND logic + only empty rules → captures everything', () {
      const s = FilterRuleSet(
        enabled: true,
        logic: Logic.and,
        rules: [FilterRule(), FilterRule()],
      );
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
    });

    test('enabled + OR + one real rule + one empty rule → OR applies to real only', () {
      const s = FilterRuleSet(
        enabled: true,
        logic: Logic.or,
        rules: [
          FilterRule(),
          FilterRule(sender: RuleField(value: 'paypal', matchType: MatchType.contains)),
        ],
      );
      // PayPal sender matches the rule → capture.
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
      // Amazon doesn't match → drop.
      expect(
        s.allows(from: 'amazon.com', subject: subject, body: body),
        isFalse,
      );
    });

    test('enabled + AND + one real rule + one empty rule → AND applies to real only', () {
      // With AND + an empty rule, only the non-empty rule gates the
      // match. With a single real rule, AND collapses to that rule
      // alone — match → capture, no-match → drop.
      const s = FilterRuleSet(
        enabled: true,
        logic: Logic.and,
        rules: [
          FilterRule(),
          FilterRule(sender: RuleField(value: 'paypal', matchType: MatchType.contains)),
        ],
      );
      // PayPal sender matches the single real rule → capture.
      expect(s.allows(from: from, subject: subject, body: body), isTrue);
      // Amazon doesn't match → drop.
      expect(
        s.allows(from: 'amazon.com', subject: subject, body: body),
        isFalse,
      );
    });
  });

  group('RuleField.matches', () {
    test('contains is case-insensitive substring', () {
      const f = RuleField(value: 'PayPal', matchType: MatchType.contains);
      expect(f.matches('noreply@paypal.com'), isTrue);
      expect(f.matches('amazon.com'), isFalse);
    });

    test('invalid regex → matches nothing, does not throw', () {
      const f = RuleField(value: '[unclosed', matchType: MatchType.regex);
      expect(f.matches('anything'), isFalse);
    });
  });
}