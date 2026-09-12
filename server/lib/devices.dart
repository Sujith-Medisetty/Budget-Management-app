import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'token_store.dart';

/// `POST /devices/register` — mobile sends `{apiToken, fcmToken}` after
/// signing in. We verify the API token, look up the account, and append
/// the FCM token to the account's `fcmTokens` set. The Pub/Sub handler
/// uses this set when publishing push notifications.
Handler devicesRegister(
  TokenStore tokens,
  TokenAuth auth,
) {
  final log = Logger('devices');

  return (Request request) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response(400, body: 'invalid json');
    }

    // Mobile sends the apiToken in the `Authorization: Bearer` header
    // (REST convention) but for compatibility we also accept it in the
    // body. Header wins when both are present so callers don't trip
    // over an old client passing a stale token in the body.
    final authHeader = request.headers['authorization'];
    final apiToken = (authHeader != null && authHeader.startsWith('Bearer '))
        ? authHeader.substring(7)
        : body['apiToken'] as String?;
    final fcmToken = body['fcmToken'] as String?;
    if (apiToken == null || fcmToken == null) {
      return Response(400, body: 'missing apiToken or fcmToken');
    }

    String sub;
    try {
      final claims = auth.verifyApiToken(apiToken);
      final s = claims['sub'] as String?;
      if (s == null) return Response(401, body: 'bad apiToken');
      sub = s;
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    }

    final record = await tokens.get(sub);
    if (record == null || record.revoked) {
      return Response(401, body: 'unknown account');
    }

    final updated = record.copyWith(
      fcmTokens: {...record.fcmTokens, fcmToken},
    );
    await tokens.put(sub, updated);

    log.info('registered fcmToken for ${record.email} '
        '(total=${updated.fcmTokens.length})');
    return Response.ok(jsonEncode({'registered': true}),
        headers: {'content-type': 'application/json'});
  };
}

/// `POST /devices/signout` — remove one FCM token from the account.
/// Never triggers account wipe even when the set empties: a multi-
/// device user signing out of the second device shouldn't lose
/// their prefs. Hard-delete is reserved for FCM UNREGISTERED
/// (server/bin/server.dart) and POST /account/delete.
Handler devicesSignout(
  TokenStore tokens,
  TokenAuth auth,
) {
  final log = Logger('devices');

  return (Request request) async {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response(400, body: 'invalid json');
    }

    // Same header-or-body precedence as /devices/register.
    final authHeader = request.headers['authorization'];
    final apiToken = (authHeader != null && authHeader.startsWith('Bearer '))
        ? authHeader.substring(7)
        : body['apiToken'] as String?;
    final fcmToken = body['fcmToken'] as String?;
    if (apiToken == null || fcmToken == null) {
      return Response(400, body: 'missing apiToken or fcmToken');
    }

    String sub;
    try {
      final claims = auth.verifyApiToken(apiToken);
      final s = claims['sub'] as String?;
      if (s == null) return Response(401, body: 'bad apiToken');
      sub = s;
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    }

    final record = await tokens.get(sub);
    if (record == null) return Response.ok('ok');

    final remaining = {...record.fcmTokens}..remove(fcmToken);
    await tokens.put(sub, record.copyWith(fcmTokens: remaining));
    log.info('unregistered fcmToken for ${record.email} '
        '(remaining=${remaining.length})');

    // No account wipe here, ever. The old code called
    // deleteAccountCompletely when remaining.isEmpty, which wiped
    // prefs along with the row — a sign-out → sign-in round trip
    // dropped the user back to defaults. Today the user has to
    // explicitly tap "Delete account" in Settings, or the FCM
    // UNREGISTERED signal has to fire (real uninstall), for a
    // hard-delete to happen.
    return Response.ok('ok');
  };
}
