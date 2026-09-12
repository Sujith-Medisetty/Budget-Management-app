import 'gmail_filter_rules.dart';

/// Computes which Gmail label set `users.watch` should listen on,
/// given the user's current rule set. Returns the Pocket label id
/// to watch (Pub/Sub only fires for label changes → only matching
/// emails) or null to fall back to watching INBOX (Pub/Sub fires
/// for every email → server-side `FilterRuleSet.allows()` is the
/// gate).
///
/// Rules:
///   - 0 non-empty rules → INBOX (no Gmail filter to apply the label,
///     watching the label would suppress everything).
///   - All non-empty rules have Gmail ids (i.e. are mirrored to
///     Gmail filters) → Pocket label (Pub/Sub optimization).
///   - Any non-empty rule lacks a Gmail id (e.g. regex rule,
///     half-built rule, server-only rule) → INBOX. Regex rules can't
///     be translated to Gmail criteria, so Gmail-side filtering would
///     miss them. INBOX mode lets the server's allows() catch them.
///
/// Centralized so oauth.dart, filters_sync.dart, and pubsub_handler.dart
/// all compute the same answer.
String? desiredWatchLabelId(FilterRuleSet set, String? pocketLabelId) {
  final nonEmpty = set.rules.where((r) => !r.isEmpty).toList();
  if (nonEmpty.isEmpty) return null;
  final allMirrored = nonEmpty.every((r) => r.id != null);
  if (!allMirrored) return null;
  return pocketLabelId;
}