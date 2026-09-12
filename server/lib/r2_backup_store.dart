import 'backup_snapshot.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

/// Cloudflare R2–backed [BackupStore]. S3-compatible via hand-rolled
/// AWS Sig V4 — no AWS SDK dep, just `crypto` + `http` (both already
/// in pubspec). One gzipped JSON blob per user at
/// `{bucket}/{sub}.json.gz`; PUT overwrites the same key atomically.
///
/// R2 free tier: 10 GB stored / 10 M Class A reads / 10 M Class B
/// writes per month. We're nowhere near — at ~50 KB compressed × N
/// users with one blob each, even daily uploads cost essentially
/// nothing.
///
/// Path-style URL: `https://<account>.r2.cloudflarestorage.com/<bucket>/<key>`.
/// R2 supports both path-style and virtual-hosted-style; path-style
/// keeps the host constant so the signing code doesn't need a bucket
/// substitution step.
///
/// Region is `auto` — R2 is regionless and Sig V4 just needs *some*
/// string. Using `auto` matches what aws-cli / wrangler use.
class R2BackupStore implements BackupStore {
  R2BackupStore({
    required this.endpoint,
    required this.bucket,
    required this.accessKeyId,
    required this.secretAccessKey,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String endpoint;
  final String bucket;
  final String accessKeyId;
  final String secretAccessKey;
  final http.Client _http;
  final _log = Logger('r2-backup-store');

  static const _service = 's3';
  static const _region = 'auto';

  String _objectKey(String sub) => '${Uri.encodeComponent(sub)}.json.gz';

  String _objectUrl(String sub) {
    // Strip any trailing slash from the endpoint to avoid '//' before bucket.
    final base = endpoint.endsWith('/')
        ? endpoint.substring(0, endpoint.length - 1)
        : endpoint;
    return '$base/$bucket/${_objectKey(sub)}';
  }

  @override
  Future<void> init() async {
    _log.info('r2 backup store ready (bucket=$bucket, endpoint=$endpoint)');
  }

  @override
  Future<void> put(
    String sub, {
    required List<Map<String, Object?>> transactions,
    required List<Map<String, Object?>> budgets,
  }) async {
    final payload = jsonEncode({
      'schemaVersion': 1,
      'uploadedAt': DateTime.now().toUtc().toIso8601String(),
      'transactions': transactions,
      'budgets': budgets,
    });
    final gzipped = gzip.encode(utf8.encode(payload));
    final url = Uri.parse(_objectUrl(sub));
    final headers = _signHeaders(
      method: 'PUT',
      url: url,
      body: gzipped,
      // No `Content-Encoding: gzip` header on purpose. R2 echoes it
      // back on GET, and Dart's `http` client auto-decompresses gzip
      // responses — so `res.bodyBytes` would arrive already inflated
      // and our manual `gzip.decode()` would choke. Treating the
      // payload as opaque bytes keeps the round-trip symmetric.
      extraHeaders: const {
        'content-type': 'application/octet-stream',
      },
    );
    final res = await _http.put(url, headers: headers, body: gzipped);
    if (res.statusCode ~/ 100 != 2) {
      throw StateError('R2 PUT ${res.statusCode}: ${res.body}');
    }
    _log.info(
      'backup stored: ${transactions.length} txns, ${budgets.length} '
      'budgets for $sub (${payload.length} → ${gzipped.length} bytes)',
    );
  }

  @override
  Future<BackupSnapshot?> get(String sub) async {
    final url = Uri.parse(_objectUrl(sub));
    final headers = _signHeaders(method: 'GET', url: url);
    final res = await _http.get(url, headers: headers);
    if (res.statusCode == 404) return null;
    if (res.statusCode ~/ 100 != 2) {
      throw StateError('R2 GET ${res.statusCode}: ${res.body}');
    }
    Map<String, dynamic> json;
    try {
      json = jsonDecode(utf8.decode(gzip.decode(res.bodyBytes)))
          as Map<String, dynamic>;
    } catch (e) {
      _log.warning('backup object for $sub malformed — treating as no backup: $e');
      return null;
    }
    final ts = json['uploadedAt'] as String?;
    final txns = _decodeList(json['transactions']);
    final budgets = _decodeList(json['budgets']);
    if (ts == null || txns == null || budgets == null) {
      _log.warning('backup object for $sub malformed — treating as no backup');
      return null;
    }
    return BackupSnapshot(
      uploadedAt: DateTime.parse(ts),
      transactions: txns,
      budgets: budgets,
    );
  }

  @override
  Future<void> remove(String sub) async {
    final url = Uri.parse(_objectUrl(sub));
    final headers = _signHeaders(method: 'DELETE', url: url);
    final res = await _http.delete(url, headers: headers);
    // 204 = deleted, 404 = never existed. Both are no-ops for the caller.
    if (res.statusCode != 204 && res.statusCode != 404) {
      throw StateError('R2 DELETE ${res.statusCode}: ${res.body}');
    }
    _log.info('backup $sub deleted (status=${res.statusCode})');
  }

  List<Map<String, Object?>>? _decodeList(dynamic raw) {
    if (raw is! List) return null;
    try {
      return raw
          .cast<Map>()
          .map((m) => m.cast<String, Object?>())
          .toList(growable: false);
    } catch (e) {
      _log.warning('backup list decode failed: $e');
      return null;
    }
  }

  // ─── AWS Sig V4 ─────────────────────────────────────────────────────

  Map<String, String> _signHeaders({
    required String method,
    required Uri url,
    List<int>? body,
    Map<String, String> extraHeaders = const {},
  }) {
    final now = DateTime.now().toUtc();
    final amzDate = _formatAmzDate(now);
    final dateStamp = _formatDateStamp(now);
    final payloadBytes = body ?? const <int>[];
    final payloadHash = sha256.convert(payloadBytes).toString();

    final headers = <String, String>{
      'host': url.host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...extraHeaders,
    };

    // Sig V4 requires canonical headers sorted by lowercase name, each
    // as `name:trimmed-value\n`, with a trailing blank line before
    // SignedHeaders.
    final sortedKeys = headers.keys.toList()..sort();
    final canonicalHeaders = '${sortedKeys
        .map((k) => '$k:${headers[k]!.trim()}')
        .join('\n')}\n';
    final signedHeaders = sortedKeys.join(';');

    final canonicalRequest = [
      method,
      _canonicalPath(url),
      _canonicalQuery(url),
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$_region/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    final signingKey =
        _deriveSigningKey(secretAccessKey, dateStamp, _region, _service);
    final signature =
        Hmac(sha256, signingKey).convert(utf8.encode(stringToSign)).toString();

    headers['authorization'] =
        'AWS4-HMAC-SHA256 '
        'Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';
    return headers;
  }

  /// Path-style: percent-encode each segment but preserve `/` between
  /// them. `Uri.encodeComponent` already does this — slashes inside a
  /// segment get encoded, but the `/` we add between segments stays raw.
  String _canonicalPath(Uri url) {
    final encoded = url.pathSegments
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    return encoded.isEmpty ? '/' : '/$encoded';
  }

  /// Sig V4 canonical query: each (key, value) pair URI-encoded as
  /// `key=value`, sorted by key then value, joined by `&`. Empty string
  /// when no query.
  String _canonicalQuery(Uri url) {
    if (url.query.isEmpty) return '';
    final pairs = <MapEntry<String, String>>[];
    url.queryParametersAll.forEach((k, vs) {
      for (final v in vs) {
        pairs.add(MapEntry(k, v));
      }
    });
    pairs.sort((a, b) {
      final k = a.key.compareTo(b.key);
      if (k != 0) return k;
      return a.value.compareTo(b.value);
    });
    return pairs
        .map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
  }

  List<int> _deriveSigningKey(
    String secret,
    String dateStamp,
    String region,
    String service,
  ) {
    final kSecret = utf8.encode('AWS4$secret');
    final kDate = Hmac(sha256, kSecret).convert(utf8.encode(dateStamp)).bytes;
    final kRegion = Hmac(sha256, kDate).convert(utf8.encode(region)).bytes;
    final kService = Hmac(sha256, kRegion).convert(utf8.encode(service)).bytes;
    return Hmac(sha256, kService).convert(utf8.encode('aws4_request')).bytes;
  }

  String _formatAmzDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}T'
        '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}Z';
  }

  String _formatDateStamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}${two(dt.month)}${two(dt.day)}';
  }
}