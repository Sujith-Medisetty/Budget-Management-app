import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'config.dart';
import 'http_client.dart';
import 'token_store.dart';

/// Registers Gmail `users.watch()` for a connected account so Pub/Sub
/// starts delivering history notifications to our topic.
///
/// `users.watch()` returns `{historyId, expiration}` — we save the
/// `historyId` as the new high-water mark. Watch expires after ~7
/// days, so we re-register on each cold start (cheap — one API call).
class GmailWatchRegistrar {
  GmailWatchRegistrar({required this.config, required this.tokens});

  final ServerConfig config;
  final TokenStore tokens;
  final _log = Logger('gmail_watch');
  final http.Client _http = safeHttpClient();

  /// Trades a refresh_token for an access_token. Exposed so the
  /// OAuth sign-in handler can mint one for label creation before
  /// `users.watch` consumes a separate exchange.
  Future<String> exchangeForAccessToken(String refreshTokenPlain) async {
    final tokenRes = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': config.webClientId,
        'client_secret': config.webClientSecret,
        'refresh_token': refreshTokenPlain,
        'grant_type': 'refresh_token',
      },
    );
    if (tokenRes.statusCode != 200) {
      throw StateError(
          'refresh_token exchange failed: ${tokenRes.statusCode} ${tokenRes.body}');
    }
    final tokensJson = jsonDecode(tokenRes.body) as Map<String, dynamic>;
    final accessToken = tokensJson['access_token'] as String?;
    if (accessToken == null) {
      throw StateError('access_token missing from refresh response');
    }
    return accessToken;
  }

  /// Refreshes `users.watch()` for an account. Idempotent — calling it
  /// twice just resets the expiry.
  ///
  /// When [pocketLabelId] is supplied, the watch is registered against
  /// that custom label with `labelFilterAction: include` — Gmail only
  /// fires Pub/Sub when that label is added/removed, which means only
  /// matching emails (filter action `addLabelIds: [pocketLabelId]`)
  /// ever trigger a push. Non-matching mail never enters the pipeline.
  ///
  /// When [pocketLabelId] is null (legacy account that hasn't
  /// re-signed-in yet, or label creation failed), we fall back to
  /// watching INBOX — the pre-existing behavior, with the
  /// server-side `FilterRuleSet.allows()` check providing the safety
  /// net. `pubsub_handler` self-heals legacy accounts on the next
  /// push by calling `ensurePocketLabelId` and re-registering.
  Future<void> refresh(
    String sub,
    String refreshTokenPlain, {
    String? pocketLabelId,
  }) async {
    final accessToken = await exchangeForAccessToken(refreshTokenPlain);

    // Step 2: call users.watch with the access token.
    final body = <String, dynamic>{
      'topicName': config.pubsubTopic,
    };
    if (pocketLabelId != null) {
      body['labelIds'] = [pocketLabelId];
      body['labelFilterAction'] = 'include';
    } else {
      // Legacy / mid-migration fallback. Remove once every account
      // has a pocketLabelId (will happen naturally as users re-sign-in
      // or get self-healed via pubsub_handler).
      body['labelIds'] = ['INBOX'];
    }
    final watchRes = await _http.post(
      Uri.parse(
          'https://gmail.googleapis.com/gmail/v1/users/me/watch'),
      headers: {
        'authorization': 'Bearer $accessToken',
        'content-type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (watchRes.statusCode != 200) {
      throw StateError(
          'users.watch failed: ${watchRes.statusCode} ${watchRes.body}');
    }
    final watch = jsonDecode(watchRes.body) as Map<String, dynamic>;
    final historyId = watch['historyId']?.toString();
    final exp = watch['expiration']?.toString();

    // Step 3: persist new high-water mark.
    final record = await tokens.get(sub);
    if (record == null) {
      _log.warning('watch succeeded but no account for sub=$sub');
      return;
    }
    await tokens.put(sub, record.copyWith(
      lastWatchAt: DateTime.now().toUtc(),
      lastHistoryId: historyId ?? record.lastHistoryId,
    ));
    _log.info('watch refreshed for $sub '
        '(historyId=$historyId, expiration=$exp, '
        'labels=${body['labelIds']})');
  }
}

/// We don't use the generated GmailApi directly because we already have
/// a raw-HTTP path working. We can refactor to the typed client later
/// without ripping up callers by adding it back as a regular import.
