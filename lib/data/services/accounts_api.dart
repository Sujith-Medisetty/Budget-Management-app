import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../models/account_record.dart';
import 'gmail_auth.dart';

/// Background-isolate-only REST client for the per-user account
/// endpoints. The foreground path (`backup_provider`,
/// `gmail_filter_rules`, `gmail_sync`, `account_hydrator`) reads /
/// writes `accounts/{sub}` directly via the Firestore SDK — see
/// `firestore_accounts.dart`.
///
/// This client survives ONLY for the background isolate (the FCM
/// `backup_trigger` and Gmail capture paths in `main.dart`). Those
/// run in a fresh isolate with no Firebase Auth session, so the SDK
/// path is unavailable — the apiToken Bearer route is the only way
/// for them to read `accounts/{sub>`.
///
/// The Dio instance, error handling, and body-decoding helpers stay
/// the same as the pre-refactor version. The other endpoints
/// (`PATCH /accounts/<sub>`, `POST /admin/backup-schedule`, etc.)
/// were dropped because the foreground no longer hits them — the
/// Cloud Run service keeps them around briefly so an old background
/// isolate can't crash on a stale path, but no new client code
/// references them.
class AccountsApi {
  AccountsApi({required this.auth, Dio? http}) : _http = http ?? _dio();

  final GmailAuth auth;
  final Dio _http;

  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 5),
      ));

  /// `GET /accounts/<sub>` via apiToken Bearer. Used only by the
  /// background isolate — `FirestoreAccounts.fetch(sub)` is the
  /// foreground equivalent. Returns null on 404 (signed in but no
  /// doc yet) and throws on any non-2xx the caller needs to know
  /// about. Caller already has the apiToken via `auth.tryRestore()`,
  /// so this method doesn't re-read it — that would be a deadlock in
  /// the background isolate where secure storage is the slow path.
  Future<AccountRecord?> get(String sub, {required String apiToken}) async {
    try {
      if (kDebugMode) {
        debugPrint('[accounts-api] GET /accounts/$sub');
      }
      final res = await _http.get<dynamic>(
        '$kServerUrl/accounts/$sub',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200) {
        throw AccountsApiException(
            'GET /accounts/$sub failed: status=${res.statusCode}');
      }
      final body = _decodeBody(res.data, 'GET /accounts/$sub', res.statusCode);
      return AccountRecord.fromServerJson(body);
    } on DioException catch (e) {
      throw AccountsApiException(
          'GET /accounts/$sub failed: message=${e.message}');
    }
  }

  /// Dio's default `responseType: ResponseType.json` auto-parses the body
  /// when the response `Content-Type` is `application/json`, so `res.data`
  /// arrives as a `Map<String, dynamic>`. If the server ever returns the
  /// body as a raw `String` (no JSON content-type, or an explicit
  /// `responseType: ResponseType.plain` override), we still need to
  /// `jsonDecode` it.
  Map<String, dynamic> _decodeBody(dynamic data, String op, int? status) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
        throw AccountsApiException(
            '$op: decoded body is ${decoded.runtimeType}, not Map');
      } on FormatException catch (e) {
        throw AccountsApiException('$op: body is not valid JSON: $e');
      }
    }
    throw AccountsApiException(
        '$op: unexpected body type: ${data.runtimeType}');
  }

  /// Convenience for callers that already have GmailAuth in scope —
  /// reads the apiToken from secure storage and forwards. Equivalent
  /// to `get(sub, apiToken: await auth.tryRestore() ?? '')`.
  Future<AccountRecord?> getWithAuth(String sub) async {
    final token = await auth.tryRestore();
    if (token == null) return null;
    return get(sub, apiToken: token);
  }

  /// Exposed so callers can recover the Google `sub` without re-
  /// reading the apiToken.
  static String? subFromApiToken(String token) =>
      GmailAuth.subFromApiToken(token);
}

class AccountsApiException implements Exception {
  AccountsApiException(this.message);
  final String message;
  @override
  String toString() => 'AccountsApiException: $message';
}
