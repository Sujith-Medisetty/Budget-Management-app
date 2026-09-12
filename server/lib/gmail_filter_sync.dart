import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'config.dart';
import 'gmail_filter_rules.dart';
import 'http_client.dart';

/// Mirrors a [FilterRule] to a Gmail-side filter via the Gmail REST
/// API. Pocket rules are an *allowlist* (capture these as
/// transactions), so the Gmail-side filter is purely decorative —
/// it copies the same criteria to Gmail so the user can see "what
/// Pocket will process" inside Gmail Settings → Filters, but it
/// doesn't archive, mark read, or otherwise mutate matched emails.
/// The actual keep/drop decision happens server-side via
/// [FilterRuleSet.allows] when Pocket parses the message.
///
/// One Pocket rule maps to one Gmail filter (1:1). The Gmail filter
/// `id` is stored back on the Pocket rule's `id` field so future
/// updates can find and replace it.
///
/// Mapping:
///   - RuleField.contains  → Gmail `from`/`subject`/`query` field
///   - RuleField.regex     → NOT translated (Gmail doesn't support
///                            regex); phone-side keeps the regex check
///                            as a last-resort gate. Logged as a
///                            warning so the operator sees it.
class GmailFilterSync {
  GmailFilterSync({
    required this.accessToken,
    http.Client? client,
    this.config,
    this.pocketLabelId,
  }) : _http = client ?? safeHttpClient();

  final String accessToken;
  final http.Client _http;
  final ServerConfig? config;

  /// Gmail label id for our "Pocket/Keep" label. When set, every
  /// filter action adds this label to matching emails — Gmail applies
  /// the label at SMTP-receive time and our `users.watch` listens for
  /// changes to this label, so Pub/Sub only fires for matching mail.
  /// Null = legacy account pre-label-scheme, falls back to STARRED.
  final String? pocketLabelId;
  final _log = Logger('gmail-filters');

  static const _base = 'https://gmail.googleapis.com/gmail/v1/'
      'users/me/settings/filters';

  int _fakeIdCounter = 0;

  /// Creates a Gmail filter matching [rule]. Returns the Gmail-assigned
  /// `id` — caller persists it on the rule for later PATCH / DELETE.
  Future<String> createFilter(FilterRule rule) async {
    final criteria = _criteriaFor(rule);
    if (criteria.isEmpty) {
      // A rule that translates to no Gmail criteria (e.g. regex-only
      // fields) can't be mirrored. Skip silently — phone-side still
      // applies it after delivery.
      _log.info('rule ${rule.id} skipped — no translatable criteria');
      throw const UntranslatableRule();
    }
    if (config?.gmailTestMode ?? false) {
      // Test mode: skip the real Gmail call. We still hand back an id
      // so the phone-side diff + persistence flow exercises end-to-end.
      // IDs look like 'test-gid-N' to make them easy to spot in logs.
      _fakeIdCounter++;
      final fakeId = 'test-gid-$_fakeIdCounter';
      _log.info('GMAIL_TEST_MODE: created fake filter $fakeId');
      return fakeId;
    }
    final body = jsonEncode({
      'criteria': criteria,
      // Gmail's filter API rejects every filter without at least one
      // action. We add the Pocket label id so the filter actually
      // does the work of separating matching mail from non-matching
      // — without this, our `users.watch` against the Pocket label
      // would never fire. For legacy accounts that haven't migrated
      // yet (no pocketLabelId), fall back to STARRED so the filter
      // is still visible in Gmail Settings → Filters even if it
      // doesn't drive Pub/Sub selection.
      'action': {
        'addLabelIds': [
          if (pocketLabelId != null)
            pocketLabelId!
          else
            'STARRED',
        ],
      },
    });
    final res = await _http.post(
      Uri.parse(_base),
      headers: {
        'authorization': 'Bearer $accessToken',
        'content-type': 'application/json',
      },
      body: body,
    );
    if (res.statusCode != 200) {
      // Gmail refuses a duplicate with "Filter already exists" when
      // there's already a filter with identical criteria. This used
      // to be a hard failure — the rule stuck around with id=null and
      // the user saw "saved in Pocket, not in Gmail". Recover by
      // listing existing filters and matching criteria by exact
      // equality. Without this, every reinstall / sign-in on a new
      // device that already has Gmail-side filters hits the wall.
      if (res.statusCode == 400 && _isAlreadyExists(res.body)) {
        final existingId = await _findExistingByCriteria(criteria);
        if (existingId != null) {
          _log.info('recovered gmail filter $existingId for rule '
              '(${rule.id ?? "new"}) — Gmail said already exists');
          return existingId;
        }
      }
      throw StateError(
          'gmail filter create failed: ${res.statusCode} ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final id = json['id'] as String?;
    if (id == null) {
      throw StateError('gmail filter create returned no id: ${res.body}');
    }
    _log.info('created gmail filter $id for rule (${rule.id ?? "new"})');
    return id;
  }

  /// True if Gmail's error body says a duplicate filter already exists.
  /// Matches the exact wording Gmail's settings/filters endpoint
  /// returns; other 400s (invalid action, bad criteria) are still
  /// treated as real failures.
  bool _isAlreadyExists(String body) {
    try {
      final json = jsonDecode(body);
      if (json is! Map) return false;
      final msg = json['error']?['message'];
      return msg is String && msg.contains('Filter already exists');
    } catch (_) {
      return false;
    }
  }

  /// Lists the user's Gmail filters and returns the id of the one
  /// whose criteria exactly match [criteria], or null when no match
  /// exists. Used to recover the existing id when Gmail's POST
  /// refuses with "Filter already exists".
  Future<String?> _findExistingByCriteria(
      Map<String, dynamic> criteria) async {
    final res = await _http.get(
      Uri.parse(_base),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode != 200) return null;
    final json = jsonDecode(res.body);
    if (json is! Map) return null;
    final list = json['filter'] as List<dynamic>? ?? const <dynamic>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final existing = (raw['criteria'] as Map?)?.cast<String, dynamic>();
      if (existing == null) continue;
      if (_criteriaEqual(existing, criteria)) {
        return raw['id'] as String?;
      }
    }
    return null;
  }

  bool _criteriaEqual(
      Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Deletes a Gmail filter by id. Idempotent — 404 (already gone)
  /// is treated as success so retries are safe.
  Future<void> deleteFilter(String id) async {
    if (config?.gmailTestMode ?? false) {
      _log.info('GMAIL_TEST_MODE: deleted fake filter $id');
      return;
    }
    final res = await _http.delete(
      Uri.parse('$_base/$id'),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode == 200 || res.statusCode == 204) {
      _log.info('deleted gmail filter $id');
      return;
    }
    if (res.statusCode == 404) {
      _log.info('gmail filter $id already gone, ignoring');
      return;
    }
    // 403 with `insufficient authentication scopes` means the user
    // hasn't re-consented yet. Re-raise so the caller can decide.
    throw StateError(
        'gmail filter delete($id) failed: ${res.statusCode} ${res.body}');
  }

  /// Lists the Gmail-side filter ids that currently exist for the
  /// authenticated user. Used by the GET /filters/status pull-sync
  /// to prune stale ids from Firestore when the user deletes filters
  /// from inside Gmail's own UI (Settings → Filters). Without this,
  /// a Gmail-side delete leaves an orphan id in our store, and the
  /// next POST /filters/sync calls DELETE on a 404 forever.
  ///
  /// Returns an empty set in test mode (caller controls reality via
  /// the fake store). Production always issues the real GET. Gmail
  /// returns 200 with a `filter` array when filters exist, and 204
  /// No Content (empty body) when the account has none — both are
  /// legitimate empty-set cases.
  Future<Set<String>> listExistingFilterIds({
    Set<String>? injected,
  }) async {
    if (injected != null) return injected;
    if (config?.gmailTestMode ?? false) return <String>{};
    final res = await _http.get(
      Uri.parse(_base),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode == 204 || res.body.isEmpty) {
      return <String>{};
    }
    if (res.statusCode != 200) {
      throw StateError(
          'gmail filter list failed: ${res.statusCode} ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['filter'] as List<dynamic>? ?? const <dynamic>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map((f) => f['id'] as String?)
        .whereType<String>()
        .toSet();
  }

  /// Lists the user's Gmail-side filters with full criteria parsed
  /// into [FilterRule]s. Used by `GET /filters/status` to IMPORT
  /// filters the user created directly inside Gmail's own UI —
  /// without this, filters set up outside Pocket would never appear
  /// in the app's Email filters screen.
  ///
  /// Each Gmail filter maps to one [FilterRule]:
  ///   - `from`     → `sender`   (contains matchType)
  ///   - `subject`  → `subject`  (contains matchType)
  ///   - `query`    → `body`     (contains matchType)
  ///   - `to`/`has` → ignored (Pocket doesn't mirror those criteria)
  /// Filters with no translatable Pocket fields are still returned
  /// (with all three rule fields null) so the user can see they
  /// exist and decide to delete or refine them from Gmail.
  ///
  /// Returns the empty list in test mode. Gmail's 204 No Content
  /// (account has no filters) also returns the empty list.
  Future<List<FilterRule>> listExistingFilters({
    List<Map<String, dynamic>>? injected,
  }) async {
    if (injected != null) {
      return injected.map(_ruleFromGmailFilter).toList(growable: false);
    }
    if (config?.gmailTestMode ?? false) return const <FilterRule>[];
    final res = await _http.get(
      Uri.parse(_base),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode == 204 || res.body.isEmpty) {
      return const <FilterRule>[];
    }
    if (res.statusCode != 200) {
      throw StateError(
          'gmail filter list failed: ${res.statusCode} ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final list = json['filter'] as List<dynamic>? ?? const <dynamic>[];
    return list
        .whereType<Map<String, dynamic>>()
        .map(_ruleFromGmailFilter)
        .toList(growable: false);
  }

  /// Translate one Gmail-side filter object into a [FilterRule].
  /// Gmail filter JSON shape:
  ///   {
  ///     "id": "ABGH...",
  ///     "criteria": { "from": "...", "subject": "...", "query": "...",
  ///                   "to": "...", "has": "...", "negatedQuery": "..." },
  ///     "action":  { "addLabelIds": [...], ... }
  ///   }
  /// We only import the three fields Pocket uses (from / subject /
  /// body). `to`, `has`, `negatedQuery`, and any future Gmail field
  /// are silently ignored — they aren't first-class in Pocket.
  FilterRule _ruleFromGmailFilter(Map<String, dynamic> gmailFilter) {
    final id = gmailFilter['id'] as String?;
    final criteria =
        (gmailFilter['criteria'] as Map?)?.cast<String, dynamic>() ?? const {};
    RuleField? sender;
    RuleField? subject;
    RuleField? body;
    final fromValue = criteria['from'];
    if (fromValue is String && fromValue.isNotEmpty) {
      sender = RuleField(value: fromValue, matchType: MatchType.contains);
    }
    final subjectValue = criteria['subject'];
    if (subjectValue is String && subjectValue.isNotEmpty) {
      subject = RuleField(value: subjectValue, matchType: MatchType.contains);
    }
    // Gmail's full-text body field is `query` (the same search syntax
    // you can type into the Gmail search box). Treat it as the body
    // match since "contains" is the closest mapping.
    final queryValue = criteria['query'];
    if (queryValue is String && queryValue.isNotEmpty) {
      body = RuleField(value: queryValue, matchType: MatchType.contains);
    }
    return FilterRule(id: id, sender: sender, subject: subject, body: body);
  }

  /// Translates a Pocket rule into a Gmail `criteria` map.
  ///
  /// Per Gmail's docs, all set criteria are AND-combined by Gmail
  /// itself (matches our within-rule semantics exactly). Regex
  /// matchType is not translated — Gmail doesn't support it.
  @visibleForTesting
  Map<String, dynamic> criteriaFor(FilterRule rule) => _criteriaFor(rule);

  Map<String, dynamic> _criteriaFor(FilterRule rule) {
    final c = <String, dynamic>{};
    if (rule.sender != null) {
      if (rule.sender!.matchType == MatchType.contains) {
        c['from'] = rule.sender!.value;
      } else {
        _log.warning('rule ${rule.id} sender is regex; not mirrored to Gmail');
      }
    }
    if (rule.subject != null) {
      if (rule.subject!.matchType == MatchType.contains) {
        c['subject'] = rule.subject!.value;
      } else {
        _log.warning('rule ${rule.id} subject is regex; not mirrored to Gmail');
      }
    }
    if (rule.body != null) {
      if (rule.body!.matchType == MatchType.contains) {
        // Gmail has no `body` field — use `query` (full search syntax).
        c['query'] = rule.body!.value;
      } else {
        _log.warning('rule ${rule.id} body is regex; not mirrored to Gmail');
      }
    }
    return c;
  }
}

/// Sentinel thrown when a rule has no Gmail-translatable criteria.
/// Caught by the sync handler so we can skip without treating it as
/// a hard failure (phone-side still applies the rule).
class UntranslatableRule implements Exception {
  const UntranslatableRule();
  @override
  String toString() => 'untranslatable rule (no contains-type criteria)';
}

/// Public re-export so callers can pattern-match without importing
/// the private symbol.
bool isUntranslatable(Object e) => e is UntranslatableRule;
