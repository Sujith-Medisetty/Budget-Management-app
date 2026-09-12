import 'auth.dart';
import 'config.dart';
import 'package:logging/logging.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:shelf/shelf.dart';

/// `DELETE /envelope?messageId=<id>` — called by the mobile app after
/// it has successfully consumed the envelope body via
/// `GET /sync?messageId=...`. We keep envelopes around until the
/// client confirms consumption so a sleeping device / pulled network
/// doesn't lose messages (mobile can re-pull on next sync). Once
/// consumed, the client explicitly tells us to drop the doc.
///
/// Auth: `Authorization: Bearer <apiToken>` — the token's `sub` must
/// match the envelope's owning `sub`. The owning `sub` is stamped on
/// the envelope when it's written by the pubsub handler. 404 on
/// delete is a no-op (the Firestore 24h TTL may have already cleared
/// it).
Handler envelopeDeleteHandler(
  ServerConfig config,
  TokenAuth auth,
  EnvelopeStore envelopes,
) {
  final log = Logger('envelopes');
  return (Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: 'missing bearer');
    }
    Map<String, dynamic> claims;
    try {
      claims = auth.verifyApiToken(authHeader.substring(7));
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    }
    final callerSub = claims['sub'] as String?;
    if (callerSub == null) {
      return Response(401, body: 'token missing sub');
    }

    final messageId = request.url.queryParameters['messageId'];
    if (messageId == null || messageId.isEmpty) {
      return Response(400, body: 'missing messageId query param');
    }

    try {
      final existing = await envelopes.get(messageId);
      if (existing == null) {
        // Already gone (TTL cleared it). Treat as success.
        return Response.ok('already-gone');
      }
      final ownerSub = existing['sub'] as String? ?? '';
      if (ownerSub.isNotEmpty && ownerSub != callerSub) {
        log.warning('envelope $messageId owned by $ownerSub, '
            'caller is $callerSub — rejecting delete');
        return Response.forbidden('not your envelope');
      }
      await envelopes.delete(messageId);
      return Response.ok('deleted');
    } catch (e) {
      log.warning('envelope delete($messageId) failed: $e');
      return Response.internalServerError(body: 'delete failed');
    }
  };
}

