import 'auth.dart';
import 'config.dart';
import 'crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'fcm.dart';
import 'gmail_fetch.dart';
import 'gmail_filter_rules.dart';
import 'gmail_labels.dart';
import 'gmail_watch.dart';
import 'mime.dart';
import 'package:dio/dio.dart' hide Response;
import 'package:dio/io.dart';
import 'package:logging/logging.dart';
import 'package:pocket_server/accounts_filter_rule_store.dart';
import 'package:pocket_server/envelope_store.dart';
import 'package:shelf/shelf.dart';
import 'token_store.dart';
import 'watch_mode.dart';

/// FCM v1 caps a data-only message at 4096 bytes total (header + body).
/// Anything bigger than this gets routed through Firestore instead —
/// the envelope lands at `envelopes/{messageId}` and FCM carries a
/// minimal `{messageId, truncated: 'true'}` marker that mobile pulls
/// via `/sync?messageId=...`. 3500 leaves ~500 bytes of headroom for
/// JSON wrapper + topic name + any base64 surprises in the envelope.
const _fcmSizeLimit = 3500;

/// `POST /pubsub/push` — Google's Pub/Sub delivers a push every time
/// a watched mailbox changes. We:
///   1. Verify the OIDC JWT (signed by Google).
///   2. Decode `{emailAddress, historyId}` from the payload.
///   3. Look up the account, decrypt its refresh token.
///   4. Call Gmail history.list to find new messages.
///   5. For each new message, fetch full payload + extract plain text.
///   6. Publish FCM data message to topic `gmail-sync-{sub}`.
///   7. Update the high-water mark in Firestore.
///
/// Returns 200 so Pub/Sub stops retrying; failures are logged.
/// Mint an access_token from a refresh_token. Extracted so tests can
/// inject a fake without spinning up Dio + hitting oauth2.googleapis.com.
typedef MintAccessToken = Future<String> Function(String refreshToken);

Handler pubsubHandler(
  ServerConfig config,
  TokenStore tokens,
  MimeExtractor mime,
  TokenAuth auth,
  TokenCipher cipher,
  FcmPublisher fcm,
  GmailFetcher fetcher,
  EnvelopeStore envelopes, {
  MintAccessToken? mintAccessToken,
  FilterRuleStore? rules,
  GmailWatchRegistrar? watch,
}) {
  final log = Logger('pubsub');
  final rules0 = rules ?? AccountsFilterRuleStore(tokens: tokens);
  final watch0 = watch ?? GmailWatchRegistrar(config: config, tokens: tokens);
  final mint = mintAccessToken ??
      ((rt) => _exchangeRefreshToken(rt, config));

  return (Request request) async {
    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      log.warning('pubsub push missing/invalid Authorization header');
      return Response.forbidden('missing bearer');
    }
    final jwt = authHeader.substring(7);

    Map<String, dynamic>? claims;
    if (config.gmailTestMode && jwt.startsWith('test-')) {
      // Test mode: skip JWT verify, log the bypass. Real Pub/Sub will
      // always send a valid Google-signed JWT; this is just for local
      // curl-based smoke tests.
      log.info('test-mode JWT bypass (jwt=$jwt)');
    } else {
      try {
        claims = await auth.verifyPubSubJwt(jwt, config.pubsubAudience);
      } on FormatException catch (e) {
        log.warning('pubsub jwt verify failed: ${e.message} '
            '(audience="${config.pubsubAudience}")');
        return Response.forbidden('bad jwt: ${e.message}');
      }
      log.info('verified pubsub push for ${claims['email']}');
    }

    // Decode the Pub/Sub message envelope.
    Map<String, dynamic> envelope;
    try {
      envelope = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }
    final msg = envelope['message'] as Map<String, dynamic>?;
    if (msg == null) return Response.badRequest(body: 'missing message');
    final data = msg['data'];
    if (data is! String) return Response.badRequest(body: 'missing data');

    Map<String, dynamic> payload;
    try {
      payload = jsonDecode(utf8.decode(base64.decode(_pad(data))))
          as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid base64 data');
    }

    final email = payload['emailAddress'] as String?;
    final historyId = payload['historyId']?.toString();
    if (email == null) return Response.badRequest(body: 'missing emailAddress');
    log.info('push for $email historyId=$historyId');

    // Find the account.
    final record = await tokens.findByEmail(email);
    if (record == null) {
      log.warning('no account for $email — dropping push');
      return Response.ok('no-account');
    }
    if (record.revoked) {
      log.warning('account $email is revoked — dropping push');
      return Response.ok('revoked');
    }

    // Decrypt the refresh token for Gmail API use.
    final refreshPlain = await cipher.open(record.refreshToken);

    // Trade refresh_token for an access_token; Gmail's access_tokens
    // last ~1h so we mint fresh per push. The Gmail API fetcher
    // threads the token through every call in [withAccessToken].
    final accessToken = await mint(refreshPlain);
    log.info('minted access_token for $email');

    // Self-heal: if this account predates the label scheme (no
    // pocketLabelId), create the label so future syncs can use it as
    // a filter action. We do NOT auto-flip the watch to label mode
    // here — that's a separate decision based on whether the user
    // actually has Gmail-mirrored rules (handled by the reconciliation
    // step below). Failures are non-fatal — we still process the push
    // through the server-side filter. Next push retries.
    var record0 = record;
    if (record0.pocketLabelId == null) {
      try {
        final labelId =
            await GmailLabelManager(accessToken: accessToken, config: config)
                .ensurePocketLabelId();
        record0 = record0.copyWith(pocketLabelId: labelId);
        await tokens.put(record0.sub, record0);
        log.info('self-healed $email: pocketLabelId=$labelId');
      } catch (e) {
        log.warning('label self-heal failed for $email: $e');
      }
    }

    // Reconcile watch mode against current rule state. Idempotent —
    // safe to call on every push. Watches are cheap (one HTTPS call)
    // and resetting the expiry is fine. The whole point: an account
    // can flip between INBOX and label mode as the user adds/deletes
    // filters, and the next push fixes the watch accordingly. This
    // also catches legacy accounts that signed in before the
    // label-scheme change — they'll migrate naturally as soon as the
    // user opens Email filters and saves.
    FilterRuleSet ruleSet = FilterRuleSet.defaults;
    try {
      await rules0.init();
      ruleSet = await rules0.get(record0.sub) ?? FilterRuleSet.defaults;
    } catch (e) {
      log.warning('failed to load filter rules for ${record0.sub}: $e — '
          'using defaults (will keep INBOX watch)');
    }
    final wanted = desiredWatchLabelId(ruleSet, record0.pocketLabelId);
    try {
      await watch0.refresh(
        record0.sub,
        refreshPlain,
        pocketLabelId: wanted,
      );
      log.info('watch reconciled for $email: '
          'pocketLabelId=${record0.pocketLabelId}, '
          'mode=${wanted == null ? 'INBOX' : 'label'}');
    } catch (e) {
      log.warning('watch reconcile failed for $email: $e');
    }

    final startHistoryId = record.lastHistoryId ?? historyId ?? '1';
    final List<String> messageIds;
    try {
      messageIds = await fetcher.withAccessToken(
        accessToken,
        () => fetcher.messagesSince(startHistoryId),
      );
    } catch (e) {
      // 404 means our stored lastHistoryId is invalid (e.g. from a
      // test publish, or older than Gmail's 7-day history window).
      // Only advance to the pushed historyId if it's a real Gmail
      // value (numeric and greater than the stored one) — otherwise
      // we'd overwrite a valid baseline with a garbage test value and
      // break every subsequent push.
      log.warning('history.list failed for $email (startHistoryId='
          '$startHistoryId): $e');
      final pushed = historyId == null ? null : int.tryParse(historyId);
      final stored = startHistoryId == '1' ? null : int.tryParse(startHistoryId);
      if (pushed != null && (stored == null || pushed > stored)) {
        await tokens.put(
          record.sub,
          record.copyWith(lastHistoryId: pushed.toString()),
        );
        log.info('advanced lastHistoryId to $pushed');
      } else {
        log.warning('not advancing — pushed=$pushed stored=$stored');
      }
      return Response.ok('history-failed');
    }
    log.info('found ${messageIds.length} new messages for $email');

    // Load the user's filter rules so we can apply them server-side
    // before pushing anything to FCM / Firestore. The Gmail-side
    // filter mirror is purely decorative (just adds a STARRED label
    // Rule set was already loaded above (during the watch-reconciliation
    // step). Reuse it — the rule set can only change via /filters/sync
    // which doesn't run concurrently with a Pub/Sub push for the same
    // account.
    final filtering = ruleSet.enabled &&
        ruleSet.rules.any((r) => !r.isEmpty);
    if (filtering) {
      log.info('filtering active: ${ruleSet.rules.length} rule(s), '
          'logic=${ruleSet.logic.name}');
    }

    int approved = 0;
    int approvedInline = 0;
    int approvedFallback = 0;
    int rejected = 0;
    int filtered = 0;
    for (final messageId in messageIds) {
      try {
        final env = await fetcher.withAccessToken(
          accessToken,
          () => fetcher.fetchEnvelope(messageId),
        );
        // In prod: Gmail API returns raw MIME; mime extractor pulls
        // text/plain. In test mode: canned envelopes already carry
        // plain text in env.text.
        final text = config.gmailTestMode
            ? env.text
            : mime.extractPlainText(env.rawPayload ?? {});

        // Server-side allowlist check. When the user has filtering
        // on and this email doesn't match any rule, drop it silently —
        // no Firestore write, no FCM publish — and log a single line
        // so a grep can confirm what happened. Without this, the
        // phone receives every Gmail change and the user's filter
        // does nothing visible.
        if (filtering &&
            !ruleSet.allows(from: env.from, subject: env.subject, body: text)) {
          log.info('envelope ${env.messageId} FILTERED '
              '(from="${env.from}" subject="${env.subject}")');
          filtered++;
          continue;
        }
        final data2 = <String, String>{
          'messageId': env.messageId,
          // 'from' is a reserved FCM data key — use a different name.
          'emailFrom': env.from,
          'subject': env.subject,
          'date': env.date.toIso8601String(),
          'text': text,
        };
        // Size guard: FCM v1 caps data-only messages at 4 KB total.
        // Anything bigger: write the envelope to Firestore and publish
        // a minimal {messageId, truncated: 'true'} marker. Mobile pulls
        // the full body via GET /sync?messageId=...
        final payloadSize = utf8.encode(jsonEncode({
          'message': {
            'topic': 'gmail-sync-${record.sub}',
            'data': data2,
          },
        })).length;

        // Per-envelope disposition: every message gets exactly one
        // APPROVED/REJECTED line so a grep over the logs answers
        // "did this get delivered?" without piecing together context.
        if (payloadSize <= _fcmSizeLimit) {
          // Always persist to Firestore too, even on the inline path.
          // FCM topic messages are best-effort: a sleeping device, a
          // transient topic-subscription race right after sign-in, or
          // a FCM outage can all drop them silently. Writing the
          // envelope every time gives the phone a guaranteed pull
          // fallback via GET /sync?since=... — at our scale
          // (~300 emails/day) this is ~9k writes/month, well under
          // Firestore's free tier.
          String? firestoreErr;
          try {
            await envelopes.put(
              env.messageId,
              {
                'from': env.from,
                'subject': env.subject,
                'text': text,
              },
              sub: record0.sub,
              date: env.date,
            );
          } catch (e) {
            firestoreErr = e.toString();
            log.warning('envelope ${env.messageId} inline firestore put '
                'failed: $e — FCM publish will still proceed');
          }
          try {
            await fcm.publishToTokens(
              sub: record0.sub,
              tokens: record0.fcmTokens,
              data: data2,
            );
            log.info('envelope ${env.messageId} ($payloadSize B) '
                'APPROVED inline'
                '${firestoreErr != null ? ' [firestore-write-failed]' : ''}');
            approved++;
            approvedInline++;
          } catch (e) {
            log.warning('envelope ${env.messageId} ($payloadSize B) '
                'REJECTED inline: $e');
            rejected++;
          }
        } else {
          String? firestoreErr;
          try {
            await envelopes.put(
              env.messageId,
              {
                'from': env.from,
                'subject': env.subject,
                'text': text,
              },
              sub: record0.sub,
              date: env.date,
            );
          } catch (e) {
            // Don't drop the message entirely if Firestore write fails —
            // still publish the truncated marker so the user sees
            // something rather than nothing.
            firestoreErr = e.toString();
            log.warning('envelope ${env.messageId} firestore put failed: '
                '$e — will still push marker');
          }
          try {
            await fcm.publishToTokens(
              sub: record0.sub,
              tokens: record0.fcmTokens,
              data: {
                'messageId': env.messageId,
                'truncated': 'true',
              },
            );
            log.info('envelope ${env.messageId} ($payloadSize B) '
                'APPROVED via fallback'
                '${firestoreErr != null ? ' (firestore write failed, marker still pushed)' : ''}');
            approved++;
            approvedFallback++;
          } catch (e) {
            log.warning('envelope ${env.messageId} ($payloadSize B) '
                'REJECTED fallback: $e'
                '${firestoreErr != null ? ' (firestore write also failed: $firestoreErr)' : ''}');
            rejected++;
          }
        }
      } catch (e) {
        log.warning('envelope $messageId REJECTED fetch: $e');
        rejected++;
      }
    }

    // Update high-water mark.
    await tokens.put(
      record0.sub,
      record0.copyWith(lastHistoryId: historyId ?? record0.lastHistoryId),
    );
    log.info('batch for ${record.email}: '
        'approved=$approved (inline=$approvedInline, fallback=$approvedFallback), '
        'rejected=$rejected, filtered=$filtered');
    return Response.ok('approved=$approved rejected=$rejected '
        'filtered=$filtered');
  };
}

Future<String> _exchangeRefreshToken(String refreshToken, ServerConfig config) async {
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

/// Shared Dio with a 1-second keep-alive idle timeout. See the
/// matching singleton in `filters_sync.dart` for the rationale.
final _oauthDio = Dio()
  ..httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..idleTimeout = const Duration(seconds: 1),
  );

String _pad(String s) {
  var x = s.replaceAll('-', '+').replaceAll('_', '/');
  while (x.length % 4 != 0) {
    x += '=';
  }
  return x;
}

