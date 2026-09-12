/// Simple keyword lists per category. Used as a fallback when AI is
/// not configured — the picker can still surface the most likely
/// transaction sources without spending API credits.
///
/// Deliberately small: only the well-known brand names that 99%+ of
/// US users will have. Missing some long-tail apps (regional banks,
/// niche payment apps) is fine — the user can still pick them from
/// "All apps". We don't want false positives (e.g. a banking keyword
/// matching a stock-tracking app), so each hint is anchored as a
/// standalone word/phrase.
const Map<String, List<String>> _categoryKeywords = {
  'payment': [
    'paypal',
    'venmo',
    'cash app',
    'cashapp',
    'zelle',
    'google pay',
    'google wallet',
    'samsung wallet',
    'samsung pay',
    'phonepe',
    'paytm',
    'alipay',
    'wechat pay',
    'wise',
    'revolut',
    'apple pay', // not on Android usually but harmless
  ],
  'banking': [
    'chase',
    'bank of america',
    'bofa',
    'wells fargo',
    'citi',
    'citibank',
    'capital one',
    'discover',
    'usaa',
    'pnc',
    'td bank',
    'hsbc',
    'barclays',
    'ally',
    'fidelity', // bank + brokerage
    'marcus',
  ],
  'finance': [
    'robinhood',
    'coinbase',
    'binance',
    'metamask',
    'etrade',
    'schwab',
    'mint',
    'ynab',
    'sofi',
  ],
  'shopping': [
    'amazon',
    'ebay',
    'etsy',
    'target',
    'walmart',
    'best buy',
    'shopify',
    'aliexpress',
  ],
};

/// Flat map of `keyword → category` for fast lookup. Built once at
/// first use.
final Map<String, String> _keywordToCategory = () {
  final out = <String, String>{};
  for (final entry in _categoryKeywords.entries) {
    for (final kw in entry.value) {
      out[kw] = entry.key;
    }
  }
  return out;
}();

/// Returns the category ("payment", "banking", "finance", "shopping")
/// of [label] if any keyword matches as a standalone word/phrase.
/// Returns null otherwise.
///
/// Uses the same word-boundary rule as the email detector so "boa"
/// doesn't match a generic "Boarding pass" word etc.
String? matchCategoryHint(String label) {
  final text = label.toLowerCase();
  for (final entry in _keywordToCategory.entries) {
    if (_isWordMatch(text, entry.key)) return entry.value;
  }
  return null;
}

bool _isWordMatch(String text, String pattern) {
  if (pattern.isEmpty) return false;
  var from = 0;
  while (true) {
    final idx = text.indexOf(pattern, from);
    if (idx < 0) return false;
    final beforeOk =
        idx == 0 || !_isWordChar(text.codeUnitAt(idx - 1));
    final afterIdx = idx + pattern.length;
    final afterOk = afterIdx >= text.length ||
        !_isWordChar(text.codeUnitAt(afterIdx));
    if (beforeOk && afterOk) return true;
    from = idx + 1;
  }
}

bool _isWordChar(int code) {
  return (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5A) ||
      (code >= 0x61 && code <= 0x7A) ||
      code == 0x5F;
}
