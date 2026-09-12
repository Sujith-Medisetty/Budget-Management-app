import 'auth.dart';
import 'config.dart';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';

/// `GET /sync?since=<msEpoch>` — mobile calls this on pull-to-refresh
/// and on screen mount to catch up on any FCM messages it missed
/// (airplane mode, app killed, etc.).
///
/// `GET /sync?messageId=<id>` — single envelope fetch. Used by mobile
/// when an FCM payload comes in with `truncated: 'true'` (the email
/// was too big to inline). The full body lives at
/// `envelopes/{messageId}` in Firestore; we read it back here.
///
/// Auth: `Authorization: Bearer <apiToken>`.
Handler syncSince(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth,
  EnvelopeStore envelopes,
) {
  final log = Logger('sync');
  return (Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: 'missing bearer');
    }
    final apiToken = authHeader.substring(7);

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

    // Single-envelope fetch (FCM truncated-payload fallback).
    final messageId = request.url.queryParameters['messageId'];
    if (messageId != null) {
      if (config.gmailTestMode) {
        final hit = _cannedEnvelopes()
            .where((e) => e['messageId'] == messageId)
            .toList();
        if (hit.isEmpty) return Response.notFound('envelope not found');
        return Response.ok(
          jsonEncode({'envelope': hit.first}),
          headers: {'content-type': 'application/json'},
        );
      }
      try {
        final env = await envelopes.get(messageId);
        if (env == null) return Response.notFound('envelope not found');
        return Response.ok(
          jsonEncode({'envelope': env}),
          headers: {'content-type': 'application/json'},
        );
      } catch (e) {
        log.warning('envelope fetch failed for $messageId: $e');
        return Response.internalServerError(body: 'envelope fetch failed');
      }
    }

    final sinceMs = int.tryParse(request.url.queryParameters['since'] ?? '');
    final since = sinceMs == null
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : DateTime.fromMillisecondsSinceEpoch(sinceMs);

    log.info('sync from sub=$sub since=${since.toIso8601String()}');

    final result = <Map<String, dynamic>>[];
    if (config.gmailTestMode) {
      result.addAll(_cannedEnvelopes().where(
        (e) => DateTime.parse(e['date'] as String).isAfter(since),
      ));
    } else {
      try {
        result.addAll(await envelopes.listSince(since));
      } catch (e) {
        log.warning('listSince failed: $e');
        return Response.internalServerError(body: 'sync failed');
      }
    }

    return Response.ok(
      jsonEncode({'envelopes': result}),
      headers: {'content-type': 'application/json'},
    );
  };
}

List<Map<String, dynamic>> _cannedEnvelopes() {
  final now = DateTime.now().toUtc().toIso8601String();
  return [
    {
      'messageId': 'canned-msg-${now.hashCode}',
      'from': 'service@paypal.com',
      'subject': 'You sent \$29.99 to Amazon',
      'date': now,
      'text':
          'You sent \$29.99 USD to Amazon. Transaction ID: 5XY12345. '
              'Available balance: \$1,234.56.',
    },
  ];
}

