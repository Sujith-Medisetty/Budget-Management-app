import 'dart:convert';

import 'package:dio/dio.dart' hide Response;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'config.dart';
import 'crypto.dart';
import 'firebase_custom_token.dart';
import 'gmail_labels.dart';
import 'gmail_watch.dart';
import 'token_store.dart';

/// `POST /oauth/exchange` — accepts a one-time `serverAuthCode` from
/// mobile, redeems it for Google OAuth tokens, persists the refresh
/// token (encrypted) in Firestore, then hands back a short-lived
/// `apiToken` the mobile app uses on subsequent calls.
///
/// Test mode (`OAUTH_TEST_MODE=1`): skips Google entirely and stores a
/// fake `test-sub-*` record. Lets us exercise the full server path
/// without doing a real consent flow.
Handler oauthExchange(
  ServerConfig config,
  TokenStore tokens,
  TokenCipher cipher,
  TokenAuth auth,
  GmailWatchRegistrar watch, {
  FirebaseCustomTokenMinter? firebaseMinter,
  Dio? dio,
}) {
  final log = Logger('oauth');
  final d = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
  final minter = firebaseMinter ??
      (config.fcmServiceAccountJsonPath != null
          ? FirebaseCustomTokenMinter(config.fcmServiceAccountJsonPath!)
          : null);

  return (Request request) async {
    Map<String, dynamic> body;
    try {
      final raw = await request.readAsString();
      body = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return Response(400, body: 'invalid json');
    }

    final code = body['serverAuthCode'] as String?;
    if (code == null || code.isEmpty) {
      return Response(400, body: 'missing serverAuthCode');
    }

    String sub;
    String email;
    String refreshToken;
    final now = DateTime.now().toUtc();

    if (config.oauthTestMode) {
      log.info('OAUTH_TEST_MODE: bypassing Google for code=$code');
      sub = 'test-sub-${code.hashCode.abs()}';
      email = (body['email'] as String?) ?? 'test@example.com';
      refreshToken = 'fake-refresh-token-$code';
    } else {
      try {
        final tokenRes = await d.post<Map<String, dynamic>>(
          'https://oauth2.googleapis.com/token',
          data: {
            'code': code,
            'client_id': config.webClientId,
            'client_secret': config.webClientSecret,
            'redirect_uri': 'urn:ietf:wg:oauth:2.0:oob',
            'grant_type': 'authorization_code',
          },
          options: Options(
            contentType: Headers.formUrlEncodedContentType,
            responseType: ResponseType.json,
          ),
        );
        final t = tokenRes.data!;
        final rt = t['refresh_token'] as String?;
        final idToken = t['id_token'] as String?;
        if (rt == null || idToken == null) {
          log.warning('google token response missing fields: ${t.keys}');
          return Response(401, body: 'google rejected code');
        }
        refreshToken = rt;

        // Decode id_token claims. We got it via TLS from Google; we
        // could verify the RS256 signature with Google's OIDC certs
        // (see TokenAuth.verifyPubSubJwt) but for now the TLS trust
        // is enough — Mobile never sees a token we didn't get fresh
        // from Google's servers.
        final parts = idToken.split('.');
        final claims = jsonDecode(utf8.decode(_b64Decode(parts[1])))
            as Map<String, dynamic>;
        final s = claims['sub'] as String?;
        final e = claims['email'] as String?;
        if (s == null || e == null) {
          log.warning('id_token missing sub/email: ${claims.keys}');
          return Response(401, body: 'id_token missing claims');
        }
        sub = s;
        email = e;
      } on DioException catch (e) {
        log.warning('token exchange failed: ${e.response?.statusCode} '
            '${e.response?.data}');
        return Response(502, body: 'google token endpoint unreachable');
      }
    }

    final sealed = await cipher.seal(refreshToken);

    // Create the custom "Pocket/Keep" label BEFORE persisting the
    // record. users.labels.create needs a Bearer access_token, which
    // we mint via the same refresh_token flow watch.refresh uses.
    // If this fails (e.g. user just granted a new scope and Google
    // hasn't propagated it yet), we still complete sign-in but log
    // loudly — the pubsub_handler will self-heal on the next push.
    String? pocketLabelId;
    if (config.oauthTestMode) {
      log.info('OAUTH_TEST_MODE: skipping label creation for $sub');
      // In test mode the FakeLabelManager or watch will inject one.
      pocketLabelId = null;
    } else {
      try {
        final labelAccessToken = await watch.exchangeForAccessToken(refreshToken);
        pocketLabelId =
            await GmailLabelManager(accessToken: labelAccessToken, config: config)
                .ensurePocketLabelId();
      } catch (e) {
        log.warning('pocket label creation failed for $sub: $e '
            '— will retry on first push');
      }
    }

    // Resurrect (existing.revoked), same-device re-auth (existing non-revoked),
    // and first-ever sign-in (existing null) all share one write path —
    // `existing.copyWith(...)` preserves the user's prefs across cases 1 and
    // 2, and the constructor at the bottom handles case 3.
    final existing = await tokens.get(sub);
    final AccountRecord record;
    if (existing != null) {
      record = existing.copyWith(
        refreshToken: sealed,
        email: email,
        lastWatchAt: now,
        revoked: false,
        // Re-create label if it was missing or lost — the self-heal in
        // pubsub_handler will do this anyway, but doing it on sign-in
        // means the user gets label-mode filtering on the first push.
        pocketLabelId: pocketLabelId ?? existing.pocketLabelId,
      );
    } else {
      record = AccountRecord(
        sub: sub,
        refreshToken: sealed,
        email: email,
        lastWatchAt: now,
        lastHistoryId: null,
        fcmTokens: const {},
        revoked: false,
        pocketLabelId: pocketLabelId,
      );
    }

    try {
      await tokens.put(sub, record);
    } catch (e) {
      log.severe('failed to persist account for $sub: $e');
      return Response(500, body: 'failed to persist account');
    }

    // Register Gmail users.watch() so Pub/Sub starts pushing history
    // notifications for this account. Done BEFORE handing back the
    // apiToken so a watch failure surfaces to the user as a sign-in
    // error rather than a silent "connected but never gets pushes".
    //
    // We default to INBOX mode on sign-in (pocketLabelId: null) — the
    // Pocket label exists on the account, but we don't watch it yet
    // because the user has no Gmail-side filters at this point. If we
    // watched the label and there are no filters to apply it, Pub/Sub
    // never fires and the user sees an empty inbox until they save a
    // filter. INBOX mode lets every email through; the server-side
    // `FilterRuleSet.allows()` check is the gate. After the first
    // /filters/sync OR the first Pub/Sub push, pubsub_handler
    // reconciles the watch to Pocket-label mode if the user has any
    // Gmail-mirrored rules.
    if (config.oauthTestMode) {
      log.info('OAUTH_TEST_MODE: skipping users.watch for $sub');
    } else {
      try {
        await watch.refresh(sub, refreshToken, pocketLabelId: null);
      } catch (e) {
        log.severe('users.watch failed for $sub: $e');
        // Don't fail the whole sign-in — token is persisted, the
        // Pub/Sub handler or next cold start can re-register. But
        // surface the issue so the operator can see it in logs.
      }
    }

    final apiToken = auth.signApiToken(
      sub: sub,
      ttl: const Duration(days: 90),
    );

    // Mint a Firebase Auth custom token so the client can
    // `signInWithCustomToken` once and then read `accounts/{sub}`
    // directly via the Firestore SDK. Best-effort — the OAuth
    // exchange still succeeds without it; old clients that don't
    // know about the field just ignore it. The field is omitted
    // entirely (rather than null) when minting fails so the client
    // can `if (response['firebaseCustomToken'] is String)`.
    String? firebaseCustomToken;
    if (minter != null) {
      firebaseCustomToken = await minter.mint(sub);
    }

    log.info('issued apiToken for $email (sub=$sub) firebaseToken=${firebaseCustomToken != null}');
    return Response.ok(
      jsonEncode({
        'apiToken': apiToken,
        'email': email,
        'firebaseCustomToken': ?firebaseCustomToken,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `POST /oauth/signout` — soft-delete. Marks the row revoked,
/// clears the refresh_token + fcm_tokens (so we can't call Gmail or
/// push to the device that just left), and **preserves every
/// preference** (backupPrefs / budgetPrefs / filterRules / timezone).
/// The next /oauth/exchange detects revoked=true and resurrects, so
/// sign-in feels like "I'm back" not "fresh account with defaults".
///
/// Hard-delete is reserved for paths that signal a real end-of-life:
///   - FCM UNREGISTERED (the only reactive hook for app uninstall)
///   - POST /account/delete (explicit user request)
Handler oauthSignout(
  ServerConfig config,
  TokenStore tokens,
) {
  final log = Logger('oauth');
  return (Request request) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response(400, body: 'invalid json');
    }
    final apiToken = body['apiToken'] as String?;
    if (apiToken == null) return Response(400, body: 'missing apiToken');

    try {
      final parts = apiToken.split('.');
      final claims = jsonDecode(utf8.decode(_b64Decode(parts[1])))
          as Map<String, dynamic>;
      final sub = claims['sub'] as String?;
      if (sub != null) {
        final existing = await tokens.get(sub);
        if (existing != null && !existing.revoked) {
          // The prefs-preserve is the entire point of this redesign:
          // before, sign-out wiped everything, so a re-sign-in landed
          // on defaults. Now prefs ride across the sign-out / sign-in
          // round trip and the user picks up exactly where they left off.
          // Cleared fields: refresh_token (can't call Gmail without a
          // fresh OAuth grant), fcm_tokens (don't push to a device
          // that just left), revoked (gate Pub/Sub pushes / /filters/sync
          // / watch reconciliation — see pubsub_handler.dart line 120).
          await tokens.put(sub, existing.copyWith(
            refreshToken: '',
            fcmTokens: const {},
            revoked: true,
          ));
          log.info('soft-deleted $sub on oauth/signout '
              '(prefs preserved: '
              'backupPrefs.enabled=${existing.backupPrefs.enabled}, '
              'budgetPrefs.autoMonthlyBudget='
              '${existing.budgetPrefs.autoMonthlyBudget}, '
              'filterRules=${existing.filterRules != null}, '
              'timezone=${existing.timezone})');
        }
      }
    } catch (e) {
      log.warning('signout soft-delete failed (continuing): $e');
    }
    log.info('signed out');
    return Response.ok('ok');
  };
}

List<int> _b64Decode(String s) {
  var x = s.replaceAll('-', '+').replaceAll('_', '/');
  while (x.length % 4 != 0) {
    x += '=';
  }
  return base64.decode(x);
}
