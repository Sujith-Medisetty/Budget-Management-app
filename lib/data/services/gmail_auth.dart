import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/config.dart';
import '../database/database_helper.dart';

/// Owns the Google Sign-In lifecycle for Gmail capture.
///
/// Phase 2 flow: Google sign-in still happens on-device so the user
/// gets the native consent sheet, but instead of holding the refresh
/// token on the phone we forward the `serverAuthCode` to our backend
/// (`/oauth/exchange`) and keep only the short-lived `apiToken` it
/// returns. The server is the one that registers Gmail `users.watch`
/// and gets Pub/Sub pushes, so the phone just needs an FCM topic
/// subscription.
class GmailAuth {
  GmailAuth({
    FlutterSecureStorage? secure,
    Dio? http,
  })  : _secure = secure ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _http = http ?? _buildDio();

  /// Constructs the default Dio with conservative timeouts + an
  /// interceptor that logs every request / response / error so the
  /// next sign-in attempt can be diagnosed from `adb logcat -s flutter`.
  /// Hard-coding timeouts here lets us tune sign-in vs best-effort
  /// endpoints separately without leaking Dio knowledge into the rest
  /// of the app.
  static Dio _buildDio() {
    final dio = Dio(BaseOptions(
      // Sign-in has to absorb Cloud Run cold starts (5–15 s after the
      // instance is scaled down) plus a normal /oauth/exchange round-
      // trip. Pull-to-refresh + sign-out are best-effort and share
      // this client — they tolerate the longer window because they
      // surface their own snackbars anyway.
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      sendTimeout: const Duration(seconds: 15),
    ));
    dio.interceptors.add(_GmailAuthLogInterceptor());
    return dio;
  }

  final FlutterSecureStorage _secure;
  final Dio _http;
  bool _initialized = false;

  // gmail.settings.basic lets us create Gmail-side filters when the
  // user enables a phone-side rule. gmail.modify lets us create a
  // custom 'Pocket/Keep' Gmail label, add it as a filter action, and
  // point users.watch at that label so Pub/Sub only fires for
  // matching emails — the label is applied by Gmail itself at
  // SMTP-receive time, so non-matching mail never even reaches our
  // container. Existing users will see "Pocket wants additional
  // permissions" on next sign-in; Google's OAuth spec requires
  // re-consent for new scopes.
  static const _scopes = <String>[
    'email',
    'https://www.googleapis.com/auth/gmail.readonly',
    'https://www.googleapis.com/auth/gmail.settings.basic',
    'https://www.googleapis.com/auth/gmail.modify',
  ];

  static const _kAccountEmail = 'gmail_account_email';
  static const _kApiToken = 'gmail_api_token';

  Future<void> _ensureInit() async {
    if (_initialized) return;
    // OAuth client IDs are PUBLIC identifiers (not secrets) — they
    // identify which OAuth client the app uses, not what it's allowed
    // to do. Scope and redirect controls live on the server. Hard-coding
    // them here means a fresh `flutter build apk` works without needing
    // to remember `--dart-define=GMAIL_CLIENT_ID=...` every time.
    //
    // Override at build time with:
    //   flutter build apk --dart-define=GMAIL_CLIENT_ID=... \
    //                     --dart-define=GMAIL_SERVER_CLIENT_ID=...
    // The Web client ID below matches the one used by the server's
    // OAuth exchange (`WEB_CLIENT_ID` in server/.env) — they MUST be
    // from the same OAuth client or `serverAuthCode` exchange will fail.
    const webClientId =
        '490595194764-ng4mmjfe73l6n19jbnqr1iuc091nl49f.apps.googleusercontent.com';
    // Android-specific client ID (client_type=1 in GCP). If the project
    // registers one for `com.limitless.pocket` + the SHA-1 of the
    // signing key, override via --dart-define=GMAIL_CLIENT_ID=... If
    // none exists, leaving this equal to the web client ID also works
    // for google_sign_in v7 — it falls back to the Web client.
    const androidClientId = String.fromEnvironment('GMAIL_CLIENT_ID',
        defaultValue: webClientId);
    const serverClientId = String.fromEnvironment(
      'GMAIL_SERVER_CLIENT_ID',
      defaultValue: webClientId,
    );

    await GoogleSignIn.instance.initialize(
      // Android OAuth client_id — used for sign-in / ID token. Must
      // match the SHA-1 + package name of the running APK.
      clientId: androidClientId,
      // Web OAuth client_id — required by google_sign_in v7 on Android
      // when requesting non-default scopes (e.g. gmail.readonly).
      // Google's OAuth backend issues the access/refresh tokens against
      // this client. The Android one can't, even with the same scopes.
      serverClientId: serverClientId,
    );
    _initialized = true;
  }

  Future<String?> signedInEmail() => _secure.read(key: _kAccountEmail);

  Future<String?> apiToken() => _secure.read(key: _kApiToken);

  /// Starts the OAuth dance: native sign-in → forward
  /// `serverAuthCode` to our backend → persist the apiToken it returns
  /// → register the FCM token so the server can push to this device →
  /// subscribe to the per-account FCM topic.
  ///
  /// Returns the Gmail address on success, null if the user backed out.
  ///
  /// Recovery: configuration-style errors (providerConfigurationError,
  /// clientConfigurationError, unknownError) are often stale SDK state
  /// — the previous failed attempt left the singleton holding
  /// something Google refuses to retry, especially after the OAuth
  /// client's scope list changes (the cached grant no longer covers
  /// the new scopes). A clean signOut → disconnect → wipe local
  /// storage → re-init → signIn cycle usually clears it. We do this
  /// once, automatically.
  Future<String?> signIn() async {
    _logSignInStart();
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _signInOnce();
      } on GoogleSignInException catch (e) {
        debugPrint('[gmail] sign-in attempt $attempt failed: '
            'code=${e.code.name} '
            'description=${e.description} '
            'details=${e.details}');
        if (attempt == 1 && _isRecoverableError(e)) {
          debugPrint('[gmail] recoverable error → wiping SDK state and retrying');
          await wipeAndReset();
          continue;
        }
        rethrow;
      } catch (e, st) {
        debugPrint('[gmail] sign-in attempt $attempt failed: $e');
        debugPrint('[gmail]   stack: $st');
        rethrow;
      }
    }
    throw StateError('signIn: exhausted retries');
  }

  Future<String?> _signInOnce() async {
    await _ensureInit();
    // authorizeServer opens the consent sheet on first run and
    // returns a GoogleSignInServerAuthorization that carries the
    // serverAuthCode we hand to our backend. We keep only the
    // apiToken on-device — the server holds the refresh_token and
    // runs users.watch / users.history.list / FCM publish.
    final account = await GoogleSignIn.instance.authenticate();
    final serverAuthz =
        await account.authorizationClient.authorizeServer(_scopes);
    final serverAuthCode = serverAuthz?.serverAuthCode;
    if (serverAuthCode == null || serverAuthCode.isEmpty) {
      throw StateError('no serverAuthCode from Google');
    }

    // Trade the code for an apiToken. Server runs the OAuth exchange,
    // stores the refresh token encrypted in Firestore, registers
    // users.watch, and signs an HS256 apiToken (sub + 90-day exp).
    // Retried once on connection-class failures — Cloud Run cold
    // starts can spike above 15 s, and the user has just completed
    // the OAuth consent sheet, so dropping them on a flaky first
    // hit would be a bad experience. We do NOT retry on 4xx/5xx
    // with a body (those are deterministic — wrong client id,
    // expired code, etc).
    final res = await _postWithRetry<Map<String, dynamic>>(
      '$kServerUrl/oauth/exchange',
      data: {'serverAuthCode': serverAuthCode},
      options: Options(
        contentType: Headers.jsonContentType,
        validateStatus: (_) => true,
      ),
    );
    if (res.statusCode != 200 || res.data == null) {
      throw StateError('oauth/exchange failed: ${res.statusCode} '
          '${res.data?['error'] ?? ''}');
    }
    final apiToken = res.data!['apiToken'] as String?;
    if (apiToken == null || apiToken.isEmpty) {
      throw StateError('oauth/exchange returned no apiToken');
    }

    await _secure.write(key: _kApiToken, value: apiToken);
    await _secure.write(key: _kAccountEmail, value: account.email);

    // The GCP → Oracle VM migration dropped Firestore entirely — the
    // server now exposes the same per-user account data over its
    // REST endpoints (`GET`/`PATCH /accounts/<sub>`), so we no longer
    // need a Firebase Auth session to read it. The apiToken alone is
    // sufficient. Older server builds still mint a `firebaseCustomToken`
    // for back-compat; we silently ignore it here.

    // No topic subscription here anymore — the server publishes
    // directly to the FCM tokens it has on file (registered below
    // via /devices/register). Topics had a multi-minute propagation
    // lag and silently dropped the first message after sign-in.

    // Register this device's FCM token with the server so it knows
    // where to push envelopes. Best-effort — the user is still
    // connected even if push takes a moment to come up.
    await registerDevice(apiToken);

    // Decode the Google `sub` from the apiToken for the success log
    // line. We don't need it for routing anymore (server looks up
    // fcmTokens by sub → token), but the log is the easiest way to
    // confirm which account a sign-in landed on.
    final sub = subFromApiToken(apiToken);
    debugPrint('[gmail] sign-in ok for ${account.email} (sub=$sub)');

    // The post-sign-in auto-restore used to run via an _afterSignIn
    // hook wired up by the provider, but that closure captured a Ref
    // and tried to read backupServiceProvider — which depends on
    // gmailAuthProvider, forming a cycle. We now do the restore at
    // each sign-in call site (settings / onboarding / agent) via
    // `autoRestoreAfterSignIn`, where the WidgetRef is safe to use.

    return account.email;
  }

  /// Wipes every piece of GoogleSignIn + Pocket auth state on-device
  /// and re-initializes the SDK. Used to recover from internal SDK
  /// errors that survive signOut+disconnect (e.g. when the OAuth
  /// client's scope list has changed and the cached grant no longer
  /// covers the new scopes — the SDK returns
  /// `providerConfigurationError` indefinitely). After this returns,
  /// the next `authenticate()` starts from a clean slate and the
  /// user gets a fresh consent sheet with the current scope list.
  ///
  /// Public so the connected-accounts screen can trigger it on user
  /// demand when the automatic one-shot retry inside [signIn] isn't
  /// enough.
  Future<void> wipeAndReset() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {/* best-effort */}
    try {
      // Disconnect revokes the granted scopes; the user has to re-consent
      // on the next attempt. Combined with signOut, this is the
      // strongest reset google_sign_in exposes for the current
      // account.
      await GoogleSignIn.instance.disconnect();
    } catch (_) {/* best-effort */}
    // Give Play Services a moment to settle after disconnect. Without
    // this, an immediate `authenticate()` can race the cache teardown
    // and reuse the stale grant we just asked to revoke — exactly the
    // failure mode the user hit when the OAuth scope list changed.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    // Drop our own on-device auth state so a future sign-in can't pick
    // up a token we minted against the OLD scopes.
    await _wipeAuthState();
    _initialized = false;
    await _ensureInit();
  }

  /// Maps known GoogleSignInException codes to a "we can recover
  /// automatically" decision. v7 collapses the v6 statusCode=8
  /// "internalError" into [GoogleSignInExceptionCode.providerConfigurationError]
  /// (Play Services refused) and [GoogleSignInExceptionCode.clientConfigurationError]
  /// (our config is wrong). Either way a clean re-init is worth one
  /// retry — if it really is misconfigured the second attempt will
  /// fail the same way and we surface that to the user.
  bool _isRecoverableError(GoogleSignInException e) {
    switch (e.code) {
      case GoogleSignInExceptionCode.providerConfigurationError:
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.unknownError:
      case GoogleSignInExceptionCode.interrupted:
        return true;
      case GoogleSignInExceptionCode.canceled:
      case GoogleSignInExceptionCode.uiUnavailable:
      case GoogleSignInExceptionCode.userMismatch:
        return false;
    }
  }

  void _logSignInStart() {
    debugPrint('[gmail] signIn() called at ${DateTime.now().toIso8601String()}');
  }

  /// Tries to reuse a previously-granted apiToken without any UI.
  /// Returns null when the user has signed out or the token is missing.
  ///
  /// Unlike the Phase 1 google-sign-in restore, this does NOT touch
  /// Google Sign-In on every call — it just reads the apiToken from
  /// secure storage. Pull-to-refresh and screen-mount use this so they
  /// don't pop the Google account-picker on every sync.
  ///
  /// We do NOT do a server liveness check here — that would block the
  /// spinner for 5+ seconds whenever the user pulls to refresh with a
  /// flaky connection. A stale token surfaces the next time the caller
  /// actually hits the server (via 401 → [GmailSync.fetchNew] → snackbar).
  Future<String?> tryRestore() async {
    try {
      final token = await _secure.read(key: _kApiToken);
      if (token == null || token.isEmpty) return null;
      return token;
    } catch (e) {
      if (kDebugMode) debugPrint('[gmail] silent restore failed: $e');
      return null;
    }
  }

  /// No-op shim kept for callers that previously called this to
  /// establish a FirebaseAuth session for the Firestore SDK. We
  /// deleted the Firestore project during the GCP → Oracle VM
  /// migration, so there's nothing to bootstrap — the apiToken alone
  /// is enough for `accountsRepo` to read/write `accounts/<sub>`.
  /// Kept for one release as a no-op so the `main()` call site
  /// doesn't break; remove on the next refactor.
  Future<void> bootstrapFirebaseAuth() async {
    // Firebase.initializeApp() loads google-services.json config
    // and registers the default Firebase app. Required before any
    // firebase_* plugin call (FCM token fetch, listener attach, etc).
    // Was a no-op after the GCP→VM migration dropped Firestore, but
    // FCM still depends on the default app being initialised —
    // skipping this call made `FirebaseMessaging.instance.getToken()`
    // throw `[core/no-app] No Firebase App '[DEFAULT]' has been
    // created`, which broke sign-out (which fetches the FCM token
    // to send /devices/unregister) and any post-sign-in path that
    // touched FCM. Idempotent — safe to call from `main()` on every
    // cold start.
    try {
      await Firebase.initializeApp();
      if (kDebugMode) {
        debugPrint('[firebase-auth] bootstrap: Firebase.initializeApp ok');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[firebase-auth] bootstrap: initializeApp failed: $e');
      }
    }
  }

  Future<void> signOut() async {
    // Read what we need up front — these are local calls that
    // can't run in parallel with each other, but they're cheap
    // relative to the GoogleSignIn hop that follows. Doing them
    // first lets the network calls fire together below.
    final token = await _secure.read(key: _kApiToken);
    final fcmToken = await FirebaseMessaging.instance.getToken();

    // Fire both server-side cleanup calls concurrently. They're
    // independent (one wipes the account record, the other removes
    // this device's FCM registration) and we don't care about
    // success or failure — the local cleanup is the source of
    // truth for the user's experience. `unawaited` because the
    // dialog needs to dismiss immediately: with the old
    // sequential code, a flaky network added 5-15 s of perceived
    // hang during sign-out.
    if (token != null) {
      unawaited(_bestEffortPost(
        '$kServerUrl/oauth/signout',
        headers: {'authorization': 'Bearer $token'},
      ));
      if (fcmToken != null) {
        unawaited(_bestEffortPost(
          '$kServerUrl/devices/signout',
          headers: {'authorization': 'Bearer $token'},
          json: {'fcmToken': fcmToken},
        ));
      }
      // Tear down the per-user Cloud Scheduler job so we don't
      // keep waking this user up after they've signed out. Best-
      // effort — the server-side `deleteAccountCompletely` will
      // also clear it as a safety net, but only on the
      // oauth/signout path; on devices/signout (token-rotation
      // race) the job may survive until next sign-in's hydrate
      // re-creates it under the user's pref state.
      final sub = subFromApiToken(token);
      if (sub != null) {
        unawaited(
          _http
              .delete<dynamic>(
            '$kServerUrl/admin/backup-schedule/$sub',
            options: Options(
              headers: {'authorization': 'Bearer $token'},
              validateStatus: (_) => true,
            ),
            // The Dio.delete<T>(...) signature requires a non-null
            // RequestOptions even when the caller doesn't care
            // about the body. Reuse the same options object so a
            // future Dio bump that splits body/options doesn't
            // break us.
          )
              .catchError((_) => Response<dynamic>(
                    requestOptions: RequestOptions(path: ''),
                  )),
        );
      }
    }

    // Local cleanup in parallel: GoogleSignOut is the slowest (Play
    // Services IPC), so we run the SQLite wipe alongside it. Then
    // SecureStorage last — it must outlive the network calls so
    // they can read the token in the catchError fallback.
    await Future.wait([
      _safeGoogleSignOut(),
      _safeFirebaseSignOut(),
      _safeClearLocal(),
    ]);

    await _wipeAuthState();
  }

  Future<void> _safeGoogleSignOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (e) {
      if (kDebugMode) debugPrint('[gmail] googleSignOut failed: $e');
    }
  }

  /// No-op shim — the old `FirestoreAccounts.fetch` required a
  /// Firebase Auth session to avoid leaking data between signed-in
  /// users. We deleted Firestore during the GCP → Oracle VM
  /// migration, so there's no session to drop. The apiToken Bearer
  /// path uses the sub encoded in the token, which can't be forged.
  Future<void> _safeFirebaseSignOut() async {
    // no-op
  }

  Future<void> _safeClearLocal() async {
    try {
      await DatabaseHelper.instance.clearAllTables();
    } catch (e) {
      if (kDebugMode) debugPrint('[gmail] local wipe failed: $e');
    }
  }

  /// Fire-and-forget POST. Swallows every error (network, timeout,
  /// HTTP status) so the caller can `unawaited` without ever seeing
  /// an unhandled future exception in the dev console. Used by
  /// [signOut] where the user-visible state is determined by local
  /// cleanup, not the server round-trip.
  Future<void> _bestEffortPost(
    String url, {
    required Map<String, String> headers,
    Map<String, dynamic>? json,
  }) async {
    try {
      await _http.post<dynamic>(
        url,
        data: json,
        options: Options(
          headers: headers,
          contentType: json == null ? null : Headers.jsonContentType,
          validateStatus: (_) => true,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[gmail] best-effort POST $url failed: $e');
    }
  }

  /// Registers the current FCM token with the server so it knows
  /// where to push envelopes. Public so [FcmBridge] can re-register
  /// when Firebase rotates the token (typically every ~6 months,
  /// sometimes sooner). Without this listener, after a rotation the
  /// server keeps publishing to the old (now-invalid) token and
  /// pushes silently stop.
  Future<void> registerDevice(String apiToken) async {
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) {
      debugPrint('[gmail] registerDevice: getToken() returned null — '
          'FIS / FCM not ready yet (no internet? api key blocked?)');
      return;
    }
    final res = await _http.post<dynamic>(
      '$kServerUrl/devices/register',
      data: {'fcmToken': fcmToken},
      options: Options(
        contentType: Headers.jsonContentType,
        headers: {'authorization': 'Bearer $apiToken'},
        validateStatus: (_) => true,
      ),
    );
    debugPrint('[gmail] registerDevice: $fcmToken -> ${res.statusCode}');
  }

  /// Cold-start hook that re-registers the FCM token against the
  /// server using the cached apiToken. Idempotent — calling it on
  /// every launch is the safety net for two failure modes:
  ///   1. The user signed in before FCM was healthy (FIS / FCM key
  ///      missing, Firebase APIs disabled) — `registerDevice` ran
  ///      inside `_signInOnce` but got an empty token, and the
  ///      server has nothing to push to. This bootstrap fires the
  ///      moment FCM IS healthy and backfills the row.
  ///   2. Token rotated between sessions — same `addOrUpdate` path
  ///      on the server, no-op for unchanged tokens.
  ///
  /// Best-effort: any failure is logged and swallowed. The foreground
  /// surfaces a "Reconnect" affordance when subsequent calls fail;
  /// we don't interrupt the cold-start path here.
  Future<void> bootstrapDevice() async {
    final apiToken = await _secure.read(key: _kApiToken);
    if (apiToken == null || apiToken.isEmpty) {
      debugPrint('[device] bootstrap: no apiToken, skipping');
      return;
    }
    debugPrint('[device] bootstrap: re-registering FCM token');
    try {
      await registerDevice(apiToken);
    } catch (e) {
      debugPrint('[device] bootstrap: registerDevice failed: $e');
    }
  }

  Future<void> _wipeAuthState() async {
    await _secure.delete(key: _kApiToken);
    await _secure.delete(key: _kAccountEmail);
  }

  /// Decodes the apiToken payload without verifying the signature.
  /// Used by FcmBridge to recover the Google `sub` so it can subscribe
  /// to the correct FCM topic — the actual signature check happens
  /// server-side on every request.
  static String? subFromApiToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      var b64 = parts[1].replaceAll('-', '+').replaceAll('_', '/');
      while (b64.length % 4 != 0) {
        b64 += '=';
      }
      final claims = jsonDecode(utf8.decode(base64.decode(b64)))
          as Map<String, dynamic>;
      return claims['sub'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// POSTs to [path] with a single retry on connection-class failures.
  /// Retries only `connectionTimeout`, `sendTimeout`, `receiveTimeout`,
  /// and `connectionError` — those are the categories where a second
  /// attempt can legitimately succeed (cold start, transient packet
  /// loss). 4xx/5xx with a body are NOT retried — the server has
  /// already answered, retrying just delays surfacing a real error.
  ///
  /// Returns the response with `validateStatus: (_) => true` so the
  /// caller can inspect non-2xx codes without Dio throwing.
  Future<Response<T>> _postWithRetry<T>(
    String path, {
    required Object? data,
    Options? options,
  }) async {
    try {
      return await _http.post<T>(
        path,
        data: data,
        options: options,
      );
    } on DioException catch (e) {
      if (!_isTransientNetworkError(e)) rethrow;
      // Brief backoff so we don't slam the server if it's already
      // struggling. 1 s is short enough that the user barely notices
      // but long enough for a TCP retransmit to land.
      await Future<void>.delayed(const Duration(seconds: 1));
      // Re-run with the same args. If this also fails, the underlying
      // DioException propagates so the snackbar shows the real reason
      // (timeout, DNS, TLS, etc) — not "retry failed".
      return await _http.post<T>(
        path,
        data: data,
        options: options,
      );
    }
  }

  bool _isTransientNetworkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.transformTimeout:
        return true;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return false;
    }
  }
}

/// Logs every GmailAuth HTTP request and response with enough detail
/// to diagnose the recurring sign-in timeout. Pipe through `adb logcat
/// -s flutter` (or look in `flutter:V` in Android Studio) to see:
///
///   [gmail-auth] → POST https://example.run.app/oauth/exchange
///   [gmail-auth] ← 200 in 412 ms
///   — or on failure —
///   [gmail-auth] ✗ connectionTimeout after 15003 ms: ...
///
/// The interceptor never logs request/response bodies — the only body
/// in scope is the one-time `serverAuthCode` and the apiToken, both of
/// which are sensitive. URL + status + timing is enough to root-cause
/// any timeout or 4xx/5xx.
class _GmailAuthLogInterceptor extends Interceptor {
  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    if (kDebugMode) {
      debugPrint('[gmail-auth] → ${options.method} ${options.uri}');
    }
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    if (kDebugMode) {
      final ms = response.requestOptions.connectTimeout?.inMilliseconds ?? 0;
      debugPrint(
        '[gmail-auth] ← ${response.statusCode} '
        '${response.requestOptions.method} ${response.requestOptions.uri} '
        '(timeout cap=${ms}ms)',
      );
    }
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (kDebugMode) {
      debugPrint(
        '[gmail-auth] ✗ ${err.type.name} '
        '${err.requestOptions.method} ${err.requestOptions.uri} '
        'message="${err.message}"',
      );
    }
    handler.next(err);
  }
}