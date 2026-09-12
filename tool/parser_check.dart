// Standalone test: runs RuleParser against a matrix of realistic
// PayPal / Google Pay notification bodies and reports which the
// regex patterns successfully parse vs. silently drop.
//
// Run: dart run tool/parser_check.dart
//
// This is a one-off diagnostic, not part of the app build. It
// intentionally re-implements the parser's regexes so the test
// stays a pure-Dart program (no flutter imports needed).

class ParsedTx {
  ParsedTx(this.amount, this.merchant, this.reason);
  final double amount;
  final String merchant;
  final String? reason;
}

bool _isPositive = true;
final _paypalSent = RegExp(
  r'you\s+sent\s+\$\s*([\d,]+(?:\.\d{1,2})?)\s*(?:USD\s+)?to\s+([^.\n]+?)(?:\.|$)',
  caseSensitive: false,
);
final _paypalReceived = RegExp(
  r'you\s+received\s+\$\s*([\d,]+(?:\.\d{1,2})?)\s*(?:USD\s+)?from\s+([^.\n]+?)(?:\.|$)',
  caseSensitive: false,
);
final _gpayPaid = RegExp(
  r'you\s+paid\s+(.+?)\s+\$\s*([\d,]+(?:\.\d{1,2})?)\s+with\s+google\s+pay',
  caseSensitive: false,
);
final _gpaySentYou = RegExp(
  r'(.+?)\s+sent\s+you\s+\$\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);
final _paypalFor = RegExp(r'\s+for\s+([^.\n]+?)(?:\.|$)', caseSensitive: false);

ParsedTx? parse(String body) {
  body = body.trim();
  final sent = _paypalSent.firstMatch(body);
  if (sent != null) {
    final amount = double.parse(sent.group(1)!.replaceAll(',', ''));
    final reason = _paypalFor.firstMatch(body)?.group(1)?.trim();
    return ParsedTx(amount, sent.group(2)!.trim(),
        (reason == null || reason.isEmpty) ? null : reason);
  }
  final recv = _paypalReceived.firstMatch(body);
  if (recv != null) {
    final amount = double.parse(recv.group(1)!.replaceAll(',', ''));
    return ParsedTx(-amount, recv.group(2)!.trim(), null);
  }
  final paid = _gpayPaid.firstMatch(body);
  if (paid != null) {
    return ParsedTx(double.parse(paid.group(2)!.replaceAll(',', '')),
        paid.group(1)!.trim(), null);
  }
  final sentYou = _gpaySentYou.firstMatch(body);
  if (sentYou != null) {
    return ParsedTx(-double.parse(sentYou.group(2)!.replaceAll(',', '')),
        sentYou.group(1)!.trim(), null);
  }
  return null;
}

class Case {
  Case(this.label, this.text);
  final String label;
  final String text;
}

void main() {
  final cases = <Case>[
    // PayPal — sent (the documented format)
    Case('PayPal sent (documented)',
        'You sent \$14.99 USD to Starbucks.'),
    Case('PayPal sent with commas',
        'You sent \$1,234.56 USD to Whole Foods Market.'),
    Case('PayPal sent no USD',
        'You sent \$4.50 to Coffee shop'),
    Case('PayPal sent with reason',
        'You sent \$25.00 USD to Mom for groceries.'),

    // PayPal — received
    Case('PayPal received',
        'You received \$200.00 USD from Alice Johnson.'),
    Case('PayPal received no USD',
        'You received \$50 from John'),

    // Google Pay — paid (the documented format)
    Case('Google Pay paid (documented)',
        'You paid Whole Foods Market \$42.10 with Google Pay'),
    Case('Google Pay paid short',
        'You paid Swiggy \$28.50 with Google Pay'),

    // Google Pay — sent you
    Case('Google Pay sent you',
        'John Smith sent you \$50.00'),

    // Real-world variants PayPal/GPay might use (unverified)
    Case('PayPal "Payment sent" wording',
        'Payment sent to Starbucks — \$14.99'),
    Case('PayPal without "You" prefix',
        'Sent \$4.50 to Coffee shop'),
    Case('PayPal euro currency',
        'You sent €10.00 EUR to Coffee Shop'),
    Case('GPay "Paid" without "You"',
        'Paid \$4.50 to Coffee Shop'),
    Case('GPay with "for" suffix',
        'You paid \$25.00 to Whole Foods with Google Pay for groceries.'),
    Case('Mixed-case PayPal',
        'YOU SENT \$10.00 USD TO TEST'),
    Case('PayPal with bank transfer wording',
        'You sent \$100.00 USD from your bank to John Doe.'),
    Case('GPay INR',
        'You paid Swiggy ₹250.00 with Google Pay'),
    Case('GPay "spaced"',
        'You  paid  Coffee   Shop  \$4.50   with   Google   Pay'),

    // Should NOT match (control cases)
    Case('Random chat message',
        'Hey did you see the news today?'),
    Case('Empty string', ''),
    Case('Just amount', '\$10.00'),
    Case('Just "You sent"',
        'You sent money to somewhere'),
  ];

  int passed = 0, dropped = 0, unexpected = 0;
  print('CASE                                                  RESULT');
  print('─' * 90);
  for (final c in cases) {
    final r = parse(c.text);
    if (r == null) {
      print('  ❌ DROPPED  ${c.label.padRight(36)}  "${c.text}"');
      dropped++;
    } else {
      print('  ✅ PARSED   ${c.label.padRight(36)}  → '
          '\$${r.amount.toStringAsFixed(2)} • ${r.merchant}'
          '${r.reason != null ? " • for ${r.reason}" : ""}');
      passed++;
    }
  }
  print('─' * 90);
  print('SUMMARY: $passed parsed, $dropped dropped '
      '(${(passed / cases.length * 100).toStringAsFixed(0)}% parse rate)');
}
