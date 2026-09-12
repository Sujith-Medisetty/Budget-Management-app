import 'auth.dart';
import 'config.dart';
import 'crypto.dart';
import 'dart:convert';
import 'filters_sync.dart' show exchangeRefreshToken;
import 'gmail_filter_rules.dart';
import 'gmail_filter_sync.dart';
import 'package:logging/logging.dart';
import 'package:pocket_server/accounts_filter_rule_store.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';

/// `GET /filters/status` — pull endpoint the phone calls on Email
/// filters screen open (and manual refresh). Reconciles the stored
/// [FilterRuleSet] with what Gmail currently has:
///
///   1. Read the user's stored rule set from Postgres.
///   2. Query Gmail's filters API for the live set of filter rules
///      (full criteria, not just ids).
///   3. Strip out any stored rule whose `id` is no longer present in
///      Gmail — that means the user deleted the filter from inside
///      Gmail's own UI, so we shouldn't keep trying to PATCH/DELETE
///      a phantom id on every save.
///   4. IMPORT any Gmail-side filter that isn't in the stored set —
///      the user may have created filters directly in Gmail's UI
///      without going through Pocket, and we want them to show up
///      in the app so the user can edit / delete them from one place.
///   5. Persist the merged set back to Postgres (no Gmail mutation —
///      this endpoint is read-only w.r.t. Gmail).
///   6. Return the merged set so the phone can refresh its UI.
///
/// Response: 200 with `{ "rules": "<json-encoded FilterRuleSet>" }`
/// in the same shape as `POST /filters/sync`. Bearer-token auth like
/// every other authenticated endpoint.
Future<Response> Function(Request) filtersStatusHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenCipher cipher,
  TokenAuth auth, {
  FilterRuleStore? store,
  GmailFilterSync Function(String accessToken, {String? pocketLabelId})?
      gmailFactory,
  Future<String> Function(String refreshToken)? exchangeRefresh,
}) {
  final log = Logger('filters-status');
  final store0 = store ?? AccountsFilterRuleStore(tokens: tokens);
  GmailFilterSync defaultGmail(String t, {String? pocketLabelId}) =>
          GmailFilterSync(accessToken: t, config: config, pocketLabelId: pocketLabelId);
  final gmail0 = gmailFactory ?? defaultGmail;
  final exchange0 = exchangeRefresh ?? (r) => exchangeRefreshToken(r, config);

  return (Request req) async {
    await store0.init();

    final authHeader = req.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response.forbidden('missing bearer');
    }
    Map<String, dynamic> claims;
    try {
      claims = auth.verifyApiToken(authHeader.substring(7));
    } on FormatException catch (e) {
      return Response.forbidden('bad token: ${e.message}');
    }
    final sub = claims['sub'] as String?;

    final stored =
        await store0.get(sub ?? '') ?? FilterRuleSet.defaults;
    final record = await tokens.get(sub ?? '');
    if (record == null) {
      log.warning('status for unknown sub=$sub');
      return Response.forbidden('unknown account');
    }
    String accessToken;
    try {
      final refreshPlain = await cipher.open(record.refreshToken);
      accessToken = await exchange0(refreshPlain);
    } catch (e, st) {
      log.warning('refresh-token exchange failed for $sub: $e\n$st');
      return Response(502,
          body: 'failed to obtain gmail access token',
          headers: {'content-type': 'text/plain'});
    }
    final gmail = gmail0(accessToken, pocketLabelId: record.pocketLabelId);

    final liveIds = <String>{};
    List<FilterRule> liveFilters = const <FilterRule>[];
    try {
      // One round trip to Gmail gives us both the id set (for prune)
      // and the full filter list (for import). Same endpoint, two
      // projections — no point in calling twice.
      liveFilters = await gmail.listExistingFilters();
      liveIds.addAll(liveFilters.map((r) => r.id).whereType<String>());
    } catch (e) {
      log.warning('gmail list filters failed for $sub: $e');
      return Response(502,
          body: 'gmail filter list failed: $e',
          headers: {'content-type': 'text/plain'});
    }

    // Build the merged rule list:
    //   - Start with the user's stored rules.
    //   - Drop any stored rule whose Gmail-side id is gone (prune).
    //   - Append every Gmail-side filter that we don't already know
    //     about by id (import).
    //
    // Empty-id stored rules (no Gmail mirror at all, e.g. regex-only
    // or half-built) always survive — Gmail never had them, so they
    // can't be "missing" from the live set.
    var pruned = 0;
    var imported = 0;
    final kept = <FilterRule>[];
    final knownIds = <String>{};
    for (final r in stored.rules) {
      if (r.id != null) knownIds.add(r.id!);
      if (r.id == null || liveIds.contains(r.id)) {
        kept.add(r);
      } else {
        pruned++;
        log.info('pruning orphan filter id=${r.id} for $sub');
      }
    }
    for (final live in liveFilters) {
      if (live.id == null) continue; // malformed Gmail filter, skip
      if (knownIds.contains(live.id)) continue; // already known
      kept.add(live);
      imported++;
      log.info('importing gmail filter ${live.id} for $sub '
          '(sender=${live.sender?.value}, '
          'subject=${live.subject?.value}, '
          'body=${live.body?.value})');
    }

    // `enabled` is preserved as-is from storage: a Gmail-side import
    // shouldn't silently turn the master switch on. The user toggles
    // that explicitly from the app's Email filters screen.
    final merged = stored.copyWith(rules: kept);
    if (pruned > 0 || imported > 0) {
      await store0.put(sub ?? '', merged);
      log.info('merged filter set for $sub: '
          'pruned=$pruned, imported=$imported, '
          'total=${kept.length} (was ${stored.rules.length})');
    }

    return Response.ok(
      jsonEncode({'rules': jsonEncode(merged.toJson())}),
      headers: {'content-type': 'application/json'},
    );
  };
}

