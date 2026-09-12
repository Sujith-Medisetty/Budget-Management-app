import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'accounts_repo.dart';

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

/// Whole user-configured filter set. The defaults ([enabled] = false,
/// empty [rules]) mean "process every Gmail message" — matching the
/// pre-feature behavior so nothing breaks for users who never touched
/// the Email filters screen. Once the master switch is on, rules act
/// as an *allowlist*: only matching emails become transactions, and
/// everything else is silently dropped.
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
  /// matches (intersection). The raw match is what callers get to
  /// compose `if (rules.allows(...))` against — match the rule means
  /// turn into a transaction.
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

/// Per-user filter rules storage. The save path goes through the VM
/// `PATCH /accounts/<sub>` — the canonical state lives in
/// `accounts.filterRules` (Postgres jsonb). Local edits (every
/// keystroke, every delete in the Email filters screen) write ONLY
/// to an in-memory cache + a SharedPreferences mirror so a half-typed
/// rule survives an app restart. Crucially the local edit path does
/// NOT touch the cloud: if it did, the next Save POST would see the
/// same diff the controller just wrote and the server's Gmail delete
/// loop would no-op. Save is the only path that flushes to the cloud.
class FilterRuleStore {
  FilterRuleStore(this._repo);
  final AccountsRepo _repo;

  /// Synchronous read for hot paths (background FCM handler, parser
  /// gating). Returns the cached snapshot or defaults if the cache
  /// is cold.
  FilterRuleSet read() => _cache ?? FilterRuleSet.defaults;

  FilterRuleSet? _cache;

  /// SharedPreferences key for the local mirror. The mirror is a
  /// write-through cache of the user's in-progress edits — it is
  /// never authoritative on its own. If the cloud returns a fresher
  /// value (e.g. after a Save), the mirror is overwritten with the
  /// cloud copy. If the cloud is unreachable on cold start, the
  /// mirror lets the UI restore the user's last view.
  static const _kPrefsKey = 'filter_rules_local_cache';

  /// Reads from the local SharedPreferences mirror without touching
  /// the network. Used on cold start to populate the UI before the
  /// cloud fetch completes — without it, an in-progress edit that's
  /// never been Saved would flicker the screen back to the
  /// cloud-state as soon as Firestore returned.
  Future<FilterRuleSet?> readLocalMirror() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return FilterRuleSet.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  /// Fetch from Firestore and update [_cache] + the local mirror.
  /// The cloud wins — anything in the local mirror from a Save that
  /// hasn't propagated yet is overwritten.
  Future<FilterRuleSet> loadFromDisk() async {
    final record = await _repo.fetch();
    final raw = record?.filterRulesJson;
    FilterRuleSet parsed;
    if (raw == null) {
      parsed = FilterRuleSet.defaults;
    } else {
      try {
        final decoded = jsonDecode(raw);
        parsed = decoded is Map
            ? FilterRuleSet.fromJson(decoded.cast<String, Object?>())
            : FilterRuleSet.defaults;
      } catch (_) {
        parsed = FilterRuleSet.defaults;
      }
    }
    _cache = parsed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(parsed.toJson()));
    return parsed;
  }

  /// Local edit path. Updates the in-memory cache + SharedPreferences
  /// mirror only. Does NOT write to Firestore — that's [commit]'s job,
  /// and it's the responsibility of the Save flow to call commit
  /// before/after the `/filters/sync` POST. Splitting local edits
  /// from commits is what lets the server still see the rule's
  /// gmail-id when the user deletes + Saves (otherwise the delete
  /// would race ahead to Firestore and the server's diff would be
  /// empty).
  Future<void> write(FilterRuleSet s) async {
    _cache = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(s.toJson()));
  }

  /// Flushes the in-memory cache to Firestore. Called by the Save
  /// flow right before the `/filters/sync` POST so the server's
  /// incoming diff still has the rule's gmail-id to compare against
  /// in its `existing` snapshot. After a successful Save the
  /// server's merged response is also written here so subsequent
  /// reads see the freshly-assigned ids.
  Future<void> commit(FilterRuleSet s) async {
    _cache = s;
    await _repo.updateFilterRules(jsonEncode(s.toJson()));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(s.toJson()));
  }
}