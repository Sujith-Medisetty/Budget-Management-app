import 'auth.dart';
import 'config.dart';
import 'crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'gmail_filter_rules.dart';
import 'gmail_filter_sync.dart';
import 'gmail_watch.dart';
import 'package:dio/dio.dart' hide Response;
import 'package:dio/io.dart';
import 'package:logging/logging.dart';
import 'package:pocket_server/accounts_filter_rule_store.dart';
import 'package:pocket_server/accounts_repo.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';
import 'watch_mode.dart';

/// `POST /filters/sync` — the phone pushes its current [FilterRuleSet]
/// and the server mirrors it to the user's Gmail account via the
/// Gmail filters API.
///
/// Body: `{ "rules": "<json-encoded FilterRuleSet>" }`. The double
/// encoding lets us treat the body as opaque on the wire and avoid
/// a schema versioning problem if the rule shape grows.
///
/// Response: 200 with `{ "rules": "<json-encoded FilterRuleSet with
/// gmail-assigned ids>" }`. The phone merges this back into its
/// local SharedPreferences copy so future syncs can PATCH/DELETE
/// by id.
/// Optional [store] + [gmailFactory] + [exchangeRefresh] parameters
/// for tests — production wiring in `bin/server.dart` passes nothing
/// and gets the real Firestore + Gmail REST + OAuth; tests inject
/// in-memory fakes.
Future<Response> Function(Request) filtersSyncHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenCipher cipher,
  TokenAuth auth, {
  FilterRuleStore? store,
  GmailFilterSync Function(String accessToken, {String? pocketLabelId})?
      gmailFactory,
  Future<String> Function(String refreshToken)? exchangeRefresh,
  GmailWatchRegistrar? watch,
}) {
  final log = Logger('filters-sync');
  final store0 = store ?? AccountsFilterRuleStore(tokens: tokens);
  // Default factory closure captures the function type so callers
  // see the new `pocketLabelId` parameter. The closure is invoked
  // per-request once we know the account's label id.
  GmailFilterSync defaultGmail(String t, {String? pocketLabelId}) =>
          GmailFilterSync(accessToken: t, config: config, pocketLabelId: pocketLabelId);
  final gmail0 = gmailFactory ?? defaultGmail;
  final exchange0 =
      exchangeRefresh ?? (r) => exchangeRefreshToken(r, config);
  final watch0 = watch ?? GmailWatchRegistrar(config: config, tokens: tokens);

  return (Request req) async {
    await store0.init();

    // 1. Auth.
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

    // 2. Decode body.
    Map<String, dynamic> bodyMap;
    try {
      bodyMap =
          jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }
    final rulesRaw = bodyMap['rules'];
    if (rulesRaw is! String) {
      return Response.badRequest(body: 'missing rules');
    }
    final FilterRuleSet incoming;
    try {
      final decoded = jsonDecode(rulesRaw);
      if (decoded is! Map) {
        return Response.badRequest(body: 'rules must be an object');
      }
      incoming = FilterRuleSet.fromJson(decoded.cast<String, Object?>());
    } catch (e) {
      return Response.badRequest(body: 'malformed rules: $e');
    }
    log.info('sync for sub=$sub: enabled=${incoming.enabled}, '
        '${incoming.rules.length} rules');

    // 3. Load existing server-side state.
    final existing = await store0.get(sub ?? '') ?? FilterRuleSet.defaults;

    // 4. Open Gmail client with a fresh access token.
    final record = await tokens.get(sub ?? '');
    if (record == null) {
      log.warning('sync for unknown sub=$sub');
      return Response.forbidden('unknown account');
    }
    if (record.revoked) {
      // Defence-in-depth: a revoked account (post-soft-delete, awaiting
      // re-sign-in) shouldn't accept /filters/sync — there's no live
      // refresh_token to mint an access_token with, and even if there
      // was, the user has explicitly said "I'm leaving". Mirror the
      // pubsub_handler guard.
      log.warning('filters/sync for revoked sub=$sub');
      return Response.forbidden('revoked');
    }
    String accessToken;
    try {
      final refreshPlain = await cipher.open(record.refreshToken);
      accessToken = await exchange0(refreshPlain);
    } catch (e) {
      log.warning('refresh-token exchange failed for $sub: $e');
      return Response(502,
          body: 'failed to obtain gmail access token',
          headers: {'content-type': 'text/plain'});
    }
    final gmail = gmail0(accessToken, pocketLabelId: record.pocketLabelId);

    // 5. Delete removed rules (existed on server, gone from incoming).
    final incomingById = <String, FilterRule>{
      for (final r in incoming.rules)
        if (r.id != null) r.id!: r,
    };
    for (final old in existing.rules) {
      if (old.id != null && !incomingById.containsKey(old.id)) {
        try {
          await gmail.deleteFilter(old.id!);
        } catch (e) {
          log.warning('delete filter ${old.id} failed: $e');
        }
      }
    }

    // 6. Create or replace each incoming rule.
    final existingById = <String, FilterRule>{
      for (final r in existing.rules)
        if (r.id != null) r.id!: r,
    };
    final merged = <FilterRule>[];
    final errors = <String, String>{}; // rule-index → error message
    for (var i = 0; i < incoming.rules.length; i++) {
      final r = incoming.rules[i];
      if (r.isEmpty) {
        // Half-built rule the user hasn't finished — keep it but
        // without a Gmail filter (there's nothing to mirror).
        merged.add(r);
        continue;
      }
      // If we already have a Gmail-side mirror with the same id AND
      // the criteria are unchanged, this is a no-op sync — skip
      // Gmail entirely so we don't churn Gmail filter ids.
      if (r.id != null && existingById.containsKey(r.id)) {
        final old = existingById[r.id!]!;
        if (_sameCriteria(old, r)) {
          merged.add(r);
          continue;
        }
        // Criteria changed — Gmail filters are immutable on PATCH, so
        // delete the old and create a new one. Without this, the old
        // filter would keep matching the old criteria forever.
        try {
          await gmail.deleteFilter(r.id!);
        } catch (e) {
          log.warning('delete filter ${r.id} for re-create failed: $e');
        }
      }
      String? newId;
      try {
        newId = await gmail.createFilter(r);
      } catch (e) {
        if (isUntranslatable(e)) {
          // Rule uses regex or otherwise has no Gmail criteria —
          // keep it but with no id so the phone knows there's no
          // mirror to clean up later.
          merged.add(r.copyWith(id: null));
          continue;
        }
        // Log the failure on its own line so Gmail's multi-line error
        // body (which explains *why* the filter was rejected) doesn't
        // get truncated by single-line log filters. Without this we
        // had no way to tell apart "user typed an invalid rule" from
        // "Gmail API quota exceeded" — both showed up as a 400.
        log.warning('create filter for rule ${r.id} (index $i) failed:\n$e');
        // Don't silently drop the rule: keep it with id=null so the
        // user's edit survives locally and the phone can show that
        // the Gmail mirror didn't land. The `errors` map below tells
        // the client which rules didn't get mirrored.
        errors[i.toString()] = e.toString();
        merged.add(r.copyWith(id: null));
        continue;
      }
      merged.add(r.copyWith(id: newId));
    }

    final newSet = incoming.copyWith(rules: merged);
    await store0.put(sub ?? '', newSet);
    log.info('synced ${merged.length} rules for $sub '
        '(${errors.length} create failures)');

    // Reconcile watch mode with the resulting rule state. INBOX when
    // no Gmail-mirrored rules exist (so every email flows through and
    // server-side allows() decides); Pocket label when all non-empty
    // rules are mirrored (so Pub/Sub only fires for matching emails).
    // Idempotent — calls users.watch even if mode didn't change, which
    // also resets the ~7-day expiry. Watch is cheap (one HTTPS call).
    final wanted = desiredWatchLabelId(newSet, record.pocketLabelId);
    try {
      await watch0.refresh(sub ?? '', accessToken, pocketLabelId: wanted);
    } catch (e) {
      log.warning('watch reconcile after sync failed for $sub: $e');
    }

    return Response.ok(
      jsonEncode({
        'rules': jsonEncode(newSet.toJson()),
        if (errors.isNotEmpty) 'errors': errors,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// Compare two rules by criteria only — id is metadata, not part of
/// the matching logic. Used to skip Gmail API calls on no-op syncs.
bool _sameCriteria(FilterRule a, FilterRule b) {
  if (a.sender != b.sender) {
    if (a.sender == null || b.sender == null) return false;
    if (a.sender!.value != b.sender!.value) return false;
    if (a.sender!.matchType != b.sender!.matchType) return false;
  }
  if (a.subject != b.subject) {
    if (a.subject == null || b.subject == null) return false;
    if (a.subject!.value != b.subject!.value) return false;
    if (a.subject!.matchType != b.subject!.matchType) return false;
  }
  if (a.body != b.body) {
    if (a.body == null || b.body == null) return false;
    if (a.body!.value != b.body!.value) return false;
    if (a.body!.matchType != b.body!.matchType) return false;
  }
  return true;
}

/// Public alias for the OAuth refresh-token exchange. Imported by
/// `filters_status.dart` so we don't duplicate the keep-alive-aware
/// Dio wiring. The 1-second idle timeout on the shared client
/// prevents the stale-keep-alive crash that bit us before.
Future<String> exchangeRefreshToken(
  String refreshToken,
  ServerConfig config,
) async {
  if (config.gmailTestMode) {
    // Skip the real Google OAuth endpoint in test mode — the stored
    // refresh_token is fake (set by `oauth.dart` when OAUTH_TEST_MODE
    // is on), so a real exchange would always 400. Hand back a dummy
    // access token; GmailFilterSync also short-circuits in test mode.
    return 'test-access-token';
  }
  final res = await _oauthDio.post<Map<String, dynamic>>(
    'https://oauth2.googleapis.com/token',
    data: {
      'client_id': config.webClientId,
      'client_secret': config.webClientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    },
    options: Options(
      contentType: Headers.formUrlEncodedContentType,
      responseType: ResponseType.json,
    ),
  );
  final t = res.data!;
  final at = t['access_token'] as String?;
  if (at == null) {
    throw StateError('access_token missing from refresh response: ${t.keys}');
  }
  return at;
}

/// Singleton Dio with a 1-second keep-alive idle timeout.
///
/// Why: Google's `oauth2.googleapis.com` closes keep-alive sockets
/// between requests. The next time we reuse the connection, dio's
/// underlying `dart:io HttpClient` raises `HttpException: Unexpected
/// response (unsolicited response without request)`. That error
/// escapes the request future and, with no isolate-wide handler,
/// killed the process (Cloud Run cold start). Setting a 1-second
/// idle timeout ensures connections are recycled fast enough that we
/// never hit a stale one. Refresh-token exchanges happen at most
/// once per Pub/Sub push, so the cost of an extra TLS handshake is
/// invisible.
final _oauthDio = Dio()
  ..httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..idleTimeout = const Duration(seconds: 1),
  );

