import 'dart:convert';

import 'package:logging/logging.dart';

import 'gmail_filter_rules.dart';
import 'token_store.dart';

/// Filter rule storage, consolidated into `accounts/{sub}.filter_rules`
/// (Postgres TEXT column on the [accounts] row). Replaces the legacy
/// Firestore implementation across the same [FilterRuleStore]
/// surface — handlers don't see the swap.
///
/// Migration note: the old Firestore code also knew how to fall back
/// to a `filter_rules/{sub}` legacy collection and copy it forward.
/// Firestore is gone now and nothing on the VM has that data, so
/// this version has no legacy path. New users start with [defaults];
/// existing users would only have rules if they saved them after
/// they switched accounts, in which case the text column already
/// has them.
class AccountsFilterRuleStore implements FilterRuleStore {
  AccountsFilterRuleStore({required this.tokens});

  /// Account row owner. The `filter_rules` column lives on `accounts`,
  /// so the same repo that reads/writes account metadata is the
  /// canonical place for rules too. Typed as the public [TokenStore]
  /// surface so test fakes (`InMemoryTokenStore`) can drive the
  /// handler without an `as AccountsRepo` cast — the actual SQL
  /// calls live behind `init()` / `get()` / `put()` which both impls
  /// share.
  final TokenStore tokens;
  final _log = Logger('rules');

  /// No-op: the underlying [TokenStore] is initialized by the caller
  /// (typically at boot). Concrete impls (Postgres) need their
  /// connection opened once; `InMemoryTokenStore` needs nothing.
  @override
  Future<void> init() async {}

  @override
  Future<void> put(String sub, FilterRuleSet set) async {
    final record = await tokens.get(sub);
    if (record == null) {
      throw StateError(
          'filter_rules put($sub): no account record to attach rules to');
    }
    await tokens.put(
      sub,
      record.copyWith(
        filterRules: jsonEncode(set.toJson()),
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    _log.info('filter_rules($sub) persisted '
        '(${set.rules.length} rules, enabled=${set.enabled})');
  }

  @override
  Future<FilterRuleSet?> get(String sub) async {
    final record = await tokens.get(sub);
    if (record == null) return null;
    final raw = record.filterRules;
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return FilterRuleSet.fromJson(decoded.cast<String, Object?>());
    } catch (e) {
      _log.warning('filter_rules($sub) malformed, ignoring: $e');
      return null;
    }
  }

  /// Account removal already drops the whole `accounts` row, so the
  /// `filter_rules` column goes with it. Kept as a no-op so callers
  /// can run the same `[FilterRuleStore].remove(sub)` cleanup path
  /// regardless of backend.
  @override
  Future<void> remove(String sub) async {
    // No-op — see class doc.
  }
}
