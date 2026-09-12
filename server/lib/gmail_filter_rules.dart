
/// One field match condition. Empty [value] means "skip this field" —
/// the caller treats unset fields as "matches anything".
enum MatchType { contains, regex }

/// How multiple rules combine when evaluated against a single email.
enum Logic { and, or }

/// A user-defined filter rule. Each rule has up to three optional
/// fields; within a single rule, multiple set fields are implicit AND.
/// Across rules, [FilterRuleSet.logic] decides.
class FilterRule {
  const FilterRule({this.id, this.sender, this.subject, this.body});

  /// Server-assigned UUID for the Gmail-side filter that mirrors
  /// this rule. Null until the first sync to the server; once set,
  /// used to PATCH / DELETE the matching Gmail filter when the rule
  /// changes or is removed. Pure metadata — never participates in
  /// matching or `isEmpty`.
  final String? id;
  final RuleField? sender;
  final RuleField? subject;
  final RuleField? body;

  bool get isEmpty =>
      sender == null && subject == null && body == null;

  FilterRule copyWith({
    String? id,
    RuleField? sender,
    RuleField? subject,
    RuleField? body,
    bool clearSender = false,
    bool clearSubject = false,
    bool clearBody = false,
  }) {
    return FilterRule(
      id: id ?? this.id,
      sender: clearSender ? null : (sender ?? this.sender),
      subject: clearSubject ? null : (subject ?? this.subject),
      body: clearBody ? null : (body ?? this.body),
    );
  }

  Map<String, Object?> toJson() => {
        if (id != null) 'id': id,
        if (sender != null) 'sender': sender!.toJson(),
        if (subject != null) 'subject': subject!.toJson(),
        if (body != null) 'body': body!.toJson(),
      };

  factory FilterRule.fromJson(Map<String, Object?> j) => FilterRule(
        id: j['id'] as String?,
        sender: _field(j['sender']),
        subject: _field(j['subject']),
        body: _field(j['body']),
      );

  static RuleField? _field(Object? raw) {
    if (raw is! Map) return null;
    final value = raw['value'];
    final match = raw['matchType'];
    if (value is! String || value.isEmpty || match is! String) return null;
    final mt = MatchType.values.firstWhere(
      (m) => m.name == match,
      orElse: () => MatchType.contains,
    );
    return RuleField(value: value, matchType: mt);
  }
}

class RuleField {
  const RuleField({required this.value, required this.matchType});

  final String value;
  final MatchType matchType;

  /// Returns true if [input] satisfies the condition. Invalid regex
  /// matches nothing — UI surfaces the error inline so the user can fix
  /// it before the next sync runs.
  bool matches(String input) {
    if (matchType == MatchType.contains) {
      return input.toLowerCase().contains(value.toLowerCase());
    }
    try {
      return RegExp(value, caseSensitive: false).hasMatch(input);
    } catch (_) {
      return false;
    }
  }

  Map<String, Object?> toJson() => {
        'value': value,
        'matchType': matchType.name,
      };
}

/// Whole user-configured filter set. Defaults (`enabled = false`, empty
/// `rules`) mean "process every Gmail message" — preserving the
/// pre-feature behavior for users who never touch Email filters. Once
/// the master switch flips on, rules become an *allowlist*: only
/// matching emails turn into transactions.
class FilterRuleSet {
  const FilterRuleSet({
    required this.enabled,
    required this.logic,
    required this.rules,
  });

  final bool enabled;
  final Logic logic;
  final List<FilterRule> rules;

  static const defaults = FilterRuleSet(
    enabled: false,
    logic: Logic.or,
    rules: <FilterRule>[],
  );

  FilterRuleSet copyWith({
    bool? enabled,
    Logic? logic,
    List<FilterRule>? rules,
  }) {
    return FilterRuleSet(
      enabled: enabled ?? this.enabled,
      logic: logic ?? this.logic,
      rules: rules ?? this.rules,
    );
  }

  /// Returns true if [from] / [subject] / [body] should be processed.
  /// When [enabled] is false, every email passes (the documented
  /// "process everything" default). When enabled with no non-empty
  /// rules, also passes — the master switch without any rule config
  /// means "process everything", otherwise flipping the switch on
  /// would silently kill all transactions with one tap.
  ///
  /// Semantics: rules are an *allowlist* (capture these). With OR,
  /// keep if any rule matches; with AND, keep only if every rule
  /// matches (intersection). Callers compose with
  /// `if (rules.allows(...))` to decide whether an envelope becomes
  /// a transaction — match the rule means process.
  bool allows({
    required String from,
    required String subject,
    required String body,
  }) {
    if (!enabled) return true;
    final active = rules.where((r) => !r.isEmpty).toList();
    if (active.isEmpty) return true;
    if (logic == Logic.and) {
      return active.every((r) => _ruleMatches(r, from, subject, body));
    }
    return active.any((r) => _ruleMatches(r, from, subject, body));
  }

  bool _ruleMatches(
    FilterRule r,
    String from,
    String subject,
    String body,
  ) {
    if (r.sender != null && !r.sender!.matches(from)) return false;
    if (r.subject != null && !r.subject!.matches(subject)) return false;
    if (r.body != null && !r.body!.matches(body)) return false;
    return true;
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'logic': logic.name,
        'rules': rules.map((r) => r.toJson()).toList(),
      };

  factory FilterRuleSet.fromJson(Map<String, Object?> j) {
    final logicName = j['logic'] as String?;
    final logic = Logic.values.firstWhere(
      (l) => l.name == logicName,
      orElse: () => Logic.or,
    );
    final raw = j['rules'];
    final rules = (raw is List)
        ? raw
            .whereType<Map>()
            .map((m) => FilterRule.fromJson(m.cast<String, Object?>()))
            .toList()
        : <FilterRule>[];
    return FilterRuleSet(
      enabled: (j['enabled'] as bool?) ?? defaults.enabled,
      logic: logic,
      rules: rules,
    );
  }
}

// Note: this file is a copy of lib/data/services/gmail_filter_rules.dart
// from the mobile app. We deliberately drop the `FilterRuleStore`
// (SharedPreferences-backed) class because the server has no use
// for it — it stores rule sets in Firestore instead.

/// Persistence boundary for [FilterRuleSet]. Implemented by
/// `AccountsFilterRuleStore` in production and by an in-memory fake
/// in tests. The handler takes this as a parameter so it can be
/// swapped without touching real Firestore.
abstract class FilterRuleStore {
  Future<void> init();
  Future<FilterRuleSet?> get(String sub);
  Future<void> put(String sub, FilterRuleSet set);

  /// Delete the user's filter rule doc. Called on account disconnect
  /// so filter rules don't outlive the account.
  Future<void> remove(String sub);
}

