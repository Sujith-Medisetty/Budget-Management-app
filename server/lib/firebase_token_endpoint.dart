import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'firebase_custom_token.dart';

/// `POST /auth/firebase-token` — exchanges a valid apiToken for a
/// fresh Firebase Auth custom token. Used by the client when the user
/// was signed in BEFORE this refactor (their apiToken predates the
/// Firebase Auth integration), so they have a valid apiToken but no
/// FirebaseAuth session.
///
/// Why not just re-do the OAuth flow: that requires the user to tap
/// through Google Sign-In UI again. This endpoint lets the same client
/// exchange the long-lived apiToken (90-day TTL) for a short-lived
/// custom token (1-hour TTL) on demand, no UI.
//
// The OAuth flow already mints the same token alongside the apiToken
// response, so new sign-ins get both in one round-trip. This endpoint
// is the recovery path for users whose cached FirebaseAuth session was
// lost or never established (e.g. upgrading from a build that didn't
// have the SDK).
///
/// Idempotency: yes — same apiToken always returns a fresh token, and
/// each Firebase custom token is independently usable (Firebase Auth
/// rejects reuse after ~5 min, but the client only ever calls this
/// once per app cold start, so reuse isn't a concern).
///
/// Failure modes:
///
///   - 400: body isn't JSON or `apiToken` is missing
///   - 401: apiToken signature / expiry invalid
///   - 500: service-account JSON can't be read or the JWT signing throws
///   - 200 with `firebaseCustomToken: null`: a mint failure (rare;
///     server logs the cause). Client falls back to defaults; user
///     surfaces a "Reconnect" affordance in Settings.
Handler firebaseTokenHandler(
  TokenAuth tokenAuth,
  FirebaseCustomTokenMinter? minter,
) {
  final log = Logger('firebase-token-endpoint');
  return (Request request) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response(400, body: 'invalid json');
    }
    final apiToken = body['apiToken'] as String?;
    if (apiToken == null || apiToken.isEmpty) {
      return Response(400, body: 'missing apiToken');
    }

    Map<String, dynamic> claims;
    try {
      claims = tokenAuth.verifyApiToken(apiToken);
    } on FormatException catch (e) {
      log.warning('verifyApiToken rejected: ${e.message}');
      return Response(401, body: 'invalid apiToken');
    }
    final sub = claims['sub'] as String?;
    if (sub == null || sub.isEmpty) {
      log.warning('apiToken claims missing sub');
      return Response(401, body: 'invalid apiToken claims');
    }

    final customToken = minter != null ? await minter.mint(sub) : null;
    return Response.ok(
      jsonEncode({'firebaseCustomToken': customToken}),
      headers: {'content-type': 'application/json'},
    );
  };
}