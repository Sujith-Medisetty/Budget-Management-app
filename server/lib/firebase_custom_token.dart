import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:logging/logging.dart';

/// Mints Firebase Auth custom tokens for the Pocket client. The Dart
/// `firebase_admin` package on pub.dev is half-implemented
/// (`Credentials.cert` throws UnimplementedError), so we sign the JWT
/// directly with `dart_jsonwebtoken` instead — same wire format, same
/// private key, fewer moving parts.
///
/// Wire format reference:
/// https://firebase.google.com/docs/auth/admin/create-custom-tokens
///
///   Header:  `{ "alg": "RS256", "kid": "<private_key_id>", "typ": "JWT" }`
///   Payload: ```
///     {
///       "aud": "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
///       "iss": "<client_email>",
///       "sub": "<client_email>",
///       "uid": "<user uid to sign in as>",
///       "iat": &lt;unix seconds now&gt;,
///       "exp": &lt;unix seconds now + 3600&gt;
///     }
///   ```
///
/// The client receives this token in the OAuth exchange response and
/// calls `FirebaseAuth.instance.signInWithCustomToken(<token>)` to
/// establish a Firebase Auth session. After that, the client SDK can
/// read `accounts/{sub}` directly under Firestore rules gated by
/// `request.auth.token.sub == sub`.
///
/// Service account JSON: same `FCM_SERVICE_ACCOUNT_JSON` path that
/// `GcpSchedulerClient` and FCM already use. No new env var, no new
/// secret — the key is the project-level service account the Cloud
/// Run service already runs as.
class FirebaseCustomTokenMinter {
  FirebaseCustomTokenMinter(this._serviceAccountJsonPath);

  final String _serviceAccountJsonPath;
  final _log = Logger('firebase-custom-token');

  /// Audience claim baked into the JWT — fixed by Firebase's
  /// identitytoolkit service. Must match exactly; the server
  /// rejects the token with `invalid-audience` otherwise.
  static const _aud =
      'https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit';

  /// Tokens expire after 1 hour. The client signs in once per OAuth
  /// exchange; Firebase Auth refreshes the resulting ID token silently
  /// after that, so we never need to mint another.
  static const _ttl = Duration(hours: 1);

  Map<String, dynamic>? _cached;
  DateTime? _cachedAt;

  Future<Map<String, dynamic>> _loadServiceAccount() async {
    final cached = _cached;
    final ts = _cachedAt;
    if (cached != null && ts != null &&
        DateTime.now().difference(ts) < const Duration(minutes: 5)) {
      return cached;
    }
    final raw = await File(_serviceAccountJsonPath).readAsString();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    _cached = map;
    _cachedAt = DateTime.now();
    return map;
  }

  /// Mint a custom token for [uid]. Returns the encoded JWT string,
  /// or null if the service account file can't be read (the OAuth
  /// exchange will surface a 500 to the client in that case — better
  /// than silently handing back a half-broken sign-in).
  Future<String?> mint(String uid) async {
    try {
      final sa = await _loadServiceAccount();
      final clientEmail = sa['client_email'] as String?;
      final privateKey = sa['private_key'] as String?;
      final keyId = sa['private_key_id'] as String?;
      if (clientEmail == null ||
          privateKey == null ||
          keyId == null) {
        _log.warning('service account JSON missing fields: '
            'clientEmail=${clientEmail != null} '
            'privateKey=${privateKey != null} '
            'keyId=${keyId != null}');
        return null;
      }
      final now = DateTime.now().toUtc();
      final jwt = JWT(
        {
          'aud': _aud,
          'iss': clientEmail,
          'sub': clientEmail,
          'uid': uid,
          'iat': now.millisecondsSinceEpoch ~/ 1000,
          'exp': (now.add(_ttl)).millisecondsSinceEpoch ~/ 1000,
        },
        header: {
          'alg': 'RS256',
          'kid': keyId,
          'typ': 'JWT',
        },
      );
      return jwt.sign(
        RSAPrivateKey(privateKey),
        algorithm: JWTAlgorithm.RS256,
      );
    } catch (e, st) {
      _log.severe('mint failed for $uid: $e\n$st');
      return null;
    }
  }
}
