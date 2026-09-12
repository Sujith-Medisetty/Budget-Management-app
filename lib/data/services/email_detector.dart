/// Heuristic: does this installed app look like an email client?
///
/// Email brands are distinctive enough (Gmail, Outlook, Yahoo Mail, …)
/// that we can confidently auto-list them — the substring-collision
/// problems we had with payment/bank ("boa" → Gboard) don't apply
/// here. Used to populate the Email section of the Capture-from
/// screen so the user doesn't have to dig through the picker for
/// Gmail / Outlook.
const _emailHints = <String>[
  'gmail',
  'outlook',
  'hotmail',
  'live.com',
  'yahoo mail',
  'ymail',
  'proton mail',
  'protonmail',
  'fastmail',
  'spark',
  'inbox',
  'tutanota',
  'fairmail',
  'k-9 mail',
  'k9mail',
  'bluemail',
  'blue mail',
  'mail.com',
  'mail.ru',
  'hey',
  'aol',
];

bool isEmailApp({required String packageName, required String label}) {
  final combined = '${label.toLowerCase()} ${packageName.toLowerCase()}';
  for (final hint in _emailHints) {
    if (_isWordMatch(combined, hint)) return true;
  }
  return false;
}

/// Same word-boundary rule as the earlier hint matcher — pattern must
/// be bounded by non-alphanumeric characters (or string edges). Keeps
/// "aol" from matching generic "pat-aol" nonsense, etc.
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