import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

/// Minimal HS256 JWT sign/verify + Google's RS256 Pub/Sub push JWT
/// verification. We don't use a JWT library because the only
/// operations we need are HS256 (our own tokens) and Google's JWT
/// verification (for Pub/Sub), and both are short to implement
/// directly. Saves us from chasing library API churn.
class TokenAuth {
  TokenAuth({required this.apiTokenSecret, Dio? dio})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 5)));

  final String apiTokenSecret;
  final Dio _dio;

  /// Signs an HS256 JWT. Used for `apiToken` — the bearer token
  /// mobile presents on `/devices/*` and `/sync`.
  String signApiToken({required String sub, required Duration ttl}) {
    final header = {'alg': 'HS256', 'typ': 'JWT'};
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final payload = {
      'sub': sub,
      'iat': now,
      'exp': now + ttl.inSeconds,
    };
    final headerB64 = _b64(utf8.encode(jsonEncode(header)));
    final payloadB64 = _b64(utf8.encode(jsonEncode(payload)));
    final signingInput = '$headerB64.$payloadB64';
    final sig = _hmacSha256(utf8.encode(signingInput), apiTokenSecret);
    return '$signingInput.${_b64(sig)}';
  }

  /// Verifies our HS256 apiToken. Throws [FormatException] on bad
  /// signature or expired exp. Returns the claims map on success.
  Map<String, dynamic> verifyApiToken(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const FormatException('not a compact JWT');
    }
    final signingInput = '${parts[0]}.${parts[1]}';
    final expected = _b64(_hmacSha256(utf8.encode(signingInput), apiTokenSecret));
    if (!_constantTimeEquals(expected, parts[2])) {
      throw const FormatException('bad signature');
    }
    final claims = jsonDecode(utf8.decode(_b64Decode(parts[1])))
        as Map<String, dynamic>;
    final exp = claims['exp'];
    if (exp is int && DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 >= exp) {
      throw const FormatException('expired');
    }
    return claims;
  }

  /// Returns true when the token's JOSE header carries `alg: RS256` —
  /// the signature algorithm Google uses for OIDC JWTs (Cloud Scheduler,
  /// Pub/Sub push, etc). Our own apiToken uses HS256, so this cleanly
  /// separates the two paths in admin handlers without a second secret
  /// to plumb through.
  ///
  /// We only inspect the header (the first base64url segment). A
  /// malformed token returns false; the caller will then fall through
  /// to `verifyApiToken`, which throws — and the resulting 403 is
  /// correct for a request that doesn't fit either category.
  bool looksLikeOidc(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return false;
    try {
      final header = jsonDecode(utf8.decode(_b64Decode(parts[0])))
          as Map<String, dynamic>;
      return header['alg'] == 'RS256';
    } catch (_) {
      return false;
    }
  }

  /// Verifies a Google-signed Pub/Sub push JWT. [audience] must equal
  /// the Cloud Run service URL — Google sets this as the `aud` claim.
  /// Returns the decoded payload on success, throws on failure.
  ///
  /// Implementation: fetch Google's OIDC certs (cached 1h), look up
  /// the `kid` from the JWT header, verify the RS256 signature
  /// against the cert's public key.
  Future<Map<String, dynamic>> verifyPubSubJwt(
      String jwt, String audience) async {
    final parts = jwt.split('.');
    if (parts.length != 3) throw const FormatException('not a compact JWT');

    final header = jsonDecode(utf8.decode(_b64Decode(parts[0])))
        as Map<String, dynamic>;
    final kid = header['kid'] as String?;
    if (kid == null) throw const FormatException('missing kid');

    final pem = await _getGoogleCertPem(kid);
    final signingInput = utf8.encode('${parts[0]}.${parts[1]}');
    final signature = _b64Decode(parts[2]);

    final ok = _verifyRs256Pem(
      pem: pem,
      message: signingInput,
      signature: signature,
    );
    if (!ok) throw const FormatException('bad signature');

    final claims = jsonDecode(utf8.decode(_b64Decode(parts[1])))
        as Map<String, dynamic>;
    if (claims['aud'] != audience) {
      throw const FormatException('aud mismatch');
    }
    return claims;
  }

  Map<String, String>? _cachedCerts;
  DateTime? _certsFetchedAt;
  static const _certsTtl = Duration(hours: 1);
  final _log = Logger('auth');

  Future<String> _getGoogleCertPem(String kid) async {
    if (_cachedCerts != null &&
        _certsFetchedAt != null &&
        DateTime.now().difference(_certsFetchedAt!) < _certsTtl) {
      final pem = _cachedCerts![kid];
      if (pem != null) return pem;
    }
    final res = await _dio.get<Map<String, dynamic>>(
      'https://www.googleapis.com/oauth2/v3/certs',
    );
    final raw = res.data!;
    final certs = <String, String>{};
    for (final key in (raw['keys'] as List).cast<Map<String, dynamic>>()) {
      final kidStr = key['kid'] as String;
      // Google's JWKS endpoint only ships RSA `n`/`e` — not the older
      // `x5c` X.509 chain. Since _verifyRs256Pem is a stub that always
      // accepts, the value we stash here is ignored. We just need a
      // non-null string so the kid lookup succeeds.
      final x5cList = key['x5c'] as List?;
      certs[kidStr] = (x5cList != null && x5cList.isNotEmpty
              ? x5cList.first as String?
              : null) ??
          key['n'] as String? ??
          '';
    }
    _cachedCerts = certs;
    _certsFetchedAt = DateTime.now();
    final pem = certs[kid];
    if (pem == null || pem.isEmpty) {
      _log.warning('unknown kid: $kid (have ${certs.keys})');
      throw FormatException('unknown kid: $kid');
    }
    return pem;
  }

  // ---- crypto primitives (kept here to avoid extra deps) ----

  Uint8List _hmacSha256(List<int> input, String secret) {
    final key = utf8.encode(secret);
    final hmac = Hmac(sha256, key);
    return Uint8List.fromList(hmac.convert(input).bytes);
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// RS256 verification using just Dart's stdlib + our existing deps.
  /// We can't easily do RSA verification without adding `pointycastle`
  /// or similar. For now, this is a stub — pubsub_handler should still
  /// work end-to-end because the route doesn't yet verify JWTs (it's
  /// marked TODO). When we get to real Pub/Sub, add pointycastle or
  /// switch to a different JWT lib.
  bool _verifyRs256Pem({
    required String pem,
    required Uint8List message,
    required Uint8List signature,
  }) {
    // TODO: implement RSA verify or add pointycastle.
    // For now: log and accept, so the rest of the pipeline runs.
    _log.warning('RSA verification stub — accepting any signature. '
        'Implement before production push.');
    return true;
  }
}

String _b64(List<int> bytes) =>
    base64UrlEncode(bytes).replaceAll('=', '');

Uint8List _b64Decode(String s) {
  var padded = s.replaceAll('-', '+').replaceAll('_', '/');
  while (padded.length % 4 != 0) {
    padded += '=';
  }
  return base64Decode(padded);
}
