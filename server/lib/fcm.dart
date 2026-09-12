import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'config.dart';

/// FCM HTTP v1 publisher. Sends data messages to FCM topics
/// (`gmail-sync-{googleSub}`). Data-only messages don't surface a
/// notification on the phone — mobile parses them locally and
/// pipelines through the existing NotificationPipeline.
///
/// Dry-run mode (`FCM_DRY_RUN=1`): logs the payload instead of
/// calling Google. Lets us exercise the full pipeline locally
/// without spamming real devices.
class FcmPublisher {
  FcmPublisher({required this.config, this.onTokenUnregistered});

  final ServerConfig config;

  /// Called when a publish fails with FCM error code `UNREGISTERED`
  /// — i.e. the FCM token is no longer registered. The signal fires
  /// when the user uninstalls the app, when FCM garbage-collects an
  /// expired token, or when the device is factory-reset.
  ///
  /// Server wires this to: (1) remove the token from the account's
  /// `fcmTokens` set, then (2) if the set goes empty, call
  /// `deleteAccountCompletely()` to wipe the Gmail-side filter +
  /// accounts/{sub} + filter_rules/{sub} so nothing outlives the
  /// uninstall.
  ///
  /// Returning a Future lets the callback do its bookkeeping
  /// (Firestore read/write + Gmail filter DELETE) before the
  /// publish loop continues. Errors are logged but never thrown —
  /// we never want one bad token to halt the entire publish cycle.
  final Future<void> Function(String sub, String token)? onTokenUnregistered;

  final _log = Logger('fcm');
  http.Client? _http;
  Future<void>? _initFuture;

  static const _scope = 'https://www.googleapis.com/auth/firebase.messaging';

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    if (config.fcmDryRun) {
      _log.info('FCM_DRY_RUN — payloads will be logged, not sent');
      return;
    }
    final path = config.fcmServiceAccountJsonPath;
    if (path == null) {
      throw StateError('FCM_SERVICE_ACCOUNT_JSON required for FCM publish');
    }
    final raw = await File(path).readAsString();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final creds = ServiceAccountCredentials.fromJson(json);
    _http = await clientViaServiceAccount(creds, [_scope]);
    _log.info('fcm client ready');
  }

  /// Publishes a data-only message to a set of FCM device tokens
  /// belonging to [sub]. Tokens are looked up from the account's
  /// `fcmTokens` set at publish time — the mobile app registers its
  /// current token via `POST /devices/register` on sign-in (and on
  /// token rotation, re-registering so the server keeps publishing
  /// to the live one).
  ///
  /// Why tokens, not topics: FCM topic subscriptions can take several
  /// minutes to propagate through Google's backend after the client
  /// calls `subscribeToTopic()`, and during that window messages
  /// published to the topic are silently dropped. Direct token send
  /// has no such lag — the token is already in the request. We hit
  /// the same failure mode in production where a $1 transaction
  /// (35 KB body, fell back to the truncated marker path) was
  /// APPROVED + FCM-published but never reached the device because
  /// the topic subscription hadn't propagated yet.
  ///
  /// HTTP v1 multicast note: there is NO `tokens` array field on the
  /// v1 `messages:send` endpoint — Google's docs and the live API
  /// both reject it with 400 "Unknown name 'tokens'". Each device
  /// requires its own send call. We loop here (typically 1 token per
  /// account, so a single round-trip in practice) and could be
  /// parallelized via HTTP/2 multiplexing if we ever grow to many
  /// devices per account. Each individual send sets high priority so
  /// the message wakes the device immediately instead of being
  /// batched/delayed by Android's normal-priority queue; iOS gets
  /// `apns-priority: 10` and `content-available` for the same reason.
  ///
  /// On UNREGISTERED, the token is reported via [onTokenUnregistered]
  /// and the loop continues to the next token. Any other failure
  /// (4xx/5xx) still throws so the caller (pubsub_handler) sees the
  /// failure and can decide to log vs. retry.
  Future<void> publishToTokens({
    required String sub,
    required Iterable<String> tokens,
    required Map<String, String> data,
  }) async {
    final tokenList = tokens.toList();
    if (tokenList.isEmpty) {
      _log.warning('publishToTokens called with empty token list — '
          'skipping (device has not registered an FCM token yet)');
      return;
    }
    if (config.fcmDryRun) {
      _log.info('[dry-run] would publish to ${tokenList.length} token(s) '
          'for sub=$sub priority=high data=${jsonEncode(data)}');
      return;
    }
    final http = await _ready();
    for (final token in tokenList) {
      await _publishOne(http, sub, token, data);
    }
  }

  Future<void> _publishOne(
    http.Client http,
    String sub,
    String token,
    Map<String, String> data,
  ) async {
    // FCM HTTP v1 send takes ONE target per call. The `message`
    // object must contain exactly one of {token, topic, condition}.
    final body = jsonEncode({
      'message': {
        'token': token,
        'data': data,
        'android': {
          'priority': 'high',
        },
        'apns': {
          'headers': {
            'apns-priority': '10',
          },
          'payload': {
            'aps': {
              'content-available': 1,
            },
          },
        },
      },
    });
    final res = await http.post(
      Uri.parse(
          'https://fcm.googleapis.com/v1/projects/${config.fcmProjectId}/messages:send'),
      headers: {'content-type': 'application/json'},
      body: body,
    );
    if (res.statusCode == 200) {
      _log.info('published to sub=$sub token=${token.substring(0, 12)}... priority=high');
      return;
    }

    // UNREGISTERED = the app uninstalled (or the token expired and
    // FCM garbage-collected it). The token is dead — there's no
    // point retrying. Hand it to the caller via the callback so they
    // can prune it from the account record; if the resulting set is
    // empty, the caller triggers full account cleanup.
    if (_isUnregistered(res.body)) {
      _log.info('token ${token.substring(0, 12)}... for sub=$sub '
          'is UNREGISTERED (app uninstalled?) — pruning');
      final cb = onTokenUnregistered;
      if (cb != null) {
        try {
          await cb(sub, token);
        } catch (e) {
          _log.warning('onTokenUnregistered callback threw: $e');
        }
      }
      return;
    }

    throw StateError('fcm publish failed for sub=$sub '
        'token=${token.substring(0, 12)}...: '
        '${res.statusCode} ${res.body}');
  }

  /// FCM error responses look like:
  ///   `{ "error": { "code": 404, "message": "...", "status": "NOT_FOUND",
  ///                  "details": [{ "@type": "...ErrorProto", "errorCode": { "value": "UNREGISTERED" } }] } }`
  /// We only need the `errorCode.value` substring — matching
  /// "UNREGISTERED" is enough to avoid false positives since Google
  /// returns it verbatim on every uninstall/expired-token case.
  bool _isUnregistered(String body) {
    return body.contains('"UNREGISTERED"');
  }

  Future<http.Client> _ready() async {
    await init();
    return _http!;
  }
}
