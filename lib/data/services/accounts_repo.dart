import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../models/account_record.dart';
import 'gmail_auth.dart';

/// REST client for the per-user account record.
///
/// Wire format (matches `GET /accounts/<sub>` and `PATCH /accounts/<sub>`
/// on the VM):
///
/// ```
/// GET    /accounts/<sub>                       → AccountRecord
/// PATCH  /accounts/<sub>                       → AccountRecord
///        body: { backupPrefs?, budgetPrefs?,
///                filterRules?, lastSyncAt? }
/// GET    /budgets?month=YYYY-MM                → { sub, budgets[] }
/// GET    /budgets/ensure-current               → { sub, budget, result }
/// ```
///
/// Auth: `Bearer <apiToken>` (HS256 JWT minted server-side at the OAuth
/// exchange). The same apiToken the rest of the app uses, so no
/// FirebaseAuth dependency is needed — we read it from secure storage
/// on every call.
///
/// Replaces the old `FirestoreAccounts` which read / wrote the same
/// data via the Firestore SDK. We deleted the Firestore project during
/// the GCP → Oracle VM migration; the data lives in Postgres now and
/// is served by these endpoints. The class shape is kept identical
/// (`fetch`, `updateBackupPrefs`, `updateFilterRules`, `setLastSyncAt`)
/// so callers don't need to change — just the transport.
class AccountsRepo {
  AccountsRepo({required this.auth, Dio? http}) : _http = http ?? _dio();

  final GmailAuth auth;
  final Dio _http;

  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 5),
      ));

  Future<String?> _apiToken() => auth.tryRestore();

  /// `GET /accounts/<sub>`. Returns null when:
  ///   - the caller has no apiToken (not signed in) — silent
  ///   - the server returns 404 (signed in but no doc yet) — silent
  /// Throws on any other non-2xx so the caller decides whether to
  /// surface the failure (the Backup screen shows a snackbar) or
  /// fall back to defaults (gmail_filter_rules uses the local mirror).
  Future<AccountRecord?> fetch() async {
    final apiToken = await _apiToken();
    if (apiToken == null) return null;
    final sub = GmailAuth.subFromApiToken(apiToken);
    if (sub == null) return null;
    try {
      if (kDebugMode) {
        debugPrint('[accounts-repo] GET /accounts/$sub');
      }
      final res = await _http.get<dynamic>(
        '$kServerUrl/accounts/$sub',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 404) {
        if (kDebugMode) {
          debugPrint('[accounts-repo] GET /accounts/$sub → 404 (no doc)');
        }
        return null;
      }
      if (res.statusCode != 200) {
        throw AccountsRepoException(
            'GET /accounts/$sub failed: status=${res.statusCode}');
      }
      final body = _decodeBody(res.data, 'GET /accounts/$sub', res.statusCode);
      return AccountRecord.fromServerJson(body);
    } on DioException catch (e) {
      throw AccountsRepoException(
          'GET /accounts/$sub failed: message=${e.message}');
    }
  }

  /// `PATCH /accounts/<sub>` — partial update. Pass any subset of
  /// `backupPrefs`, `budgetPrefs`, `filterRules`, `lastSyncAt`. Server
  /// returns the updated record so the caller can re-hydrate, but
  /// most callers only need the success/failure signal.
  Future<AccountRecord> patch(Map<String, Object?> body) async {
    final apiToken = await _apiToken();
    if (apiToken == null) {
      throw AccountsRepoException('not signed in');
    }
    final sub = GmailAuth.subFromApiToken(apiToken);
    if (sub == null) {
      throw AccountsRepoException('could not decode sub from apiToken');
    }
    try {
      if (kDebugMode) {
        debugPrint('[accounts-repo] PATCH /accounts/$sub body=$body');
      }
      final res = await _http.patch<dynamic>(
        '$kServerUrl/accounts/$sub',
        data: body,
        options: Options(
          headers: {
            'authorization': 'Bearer $apiToken',
            'content-type': Headers.jsonContentType,
          },
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        throw AccountsRepoException(
            'PATCH /accounts/$sub failed: status=${res.statusCode} '
            'body=${res.data}');
      }
      final respBody =
          _decodeBody(res.data, 'PATCH /accounts/$sub', res.statusCode);
      return AccountRecord.fromServerJson(respBody);
    } on DioException catch (e) {
      throw AccountsRepoException(
          'PATCH /accounts/$sub failed: message=${e.message}');
    }
  }

  /// Convenience: write the `backupPrefs` map under the matching key
  /// the server expects (`backupPrefs` — the server-side handler reads
  /// this exact key in [accountsPatchHandler]). Server merges with the
  /// existing record so other fields (filterRules, lastSyncAt) are
  /// untouched.
  Future<void> updateBackupPrefs(Map<String, Object?> prefs) async {
    await patch({'backupPrefs': prefs});
  }

  /// Convenience: write the JSON-encoded filter-rule set. Pass `null`
  /// to clear.
  Future<void> updateFilterRules(String? json) async {
    await patch({'filterRules': json});
  }

  /// Convenience: advance the sync high-water mark. Epoch-millis matches
  /// what the server stores in `accounts.lastSyncAt`.
  Future<void> setLastSyncAt(int epochMs) async {
    await patch({'lastSyncAt': epochMs});
  }

  /// Convenience: write the `budgetPrefs` map (currently just
  /// `autoMonthlyBudget: bool`). Server-side PATCH reader looks at
  /// `body['budgetPrefs']` exactly like it does for `backupPrefs` —
  /// no top-level alias needed since there's no per-user systemd
  /// timer to reconcile (the 1st-of-month cron reads from the
  /// `budget_prefs` JSONB column on every fire, so a PATCH here is
  /// visible to the next cron without any secondary write).
  Future<void> updateBudgetPrefs(Map<String, Object?> prefs) async {
    await patch({'budgetPrefs': prefs});
  }

  Map<String, dynamic> _decodeBody(dynamic data, String op, int? status) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
        throw AccountsRepoException(
            '$op: decoded body is ${decoded.runtimeType}, not Map');
      } on FormatException catch (e) {
        throw AccountsRepoException('$op: body is not valid JSON: $e');
      }
    }
    throw AccountsRepoException(
        '$op: unexpected body type: ${data.runtimeType}');
  }
}

class AccountsRepoException implements Exception {
  AccountsRepoException(this.message);
  final String message;
  @override
  String toString() => 'AccountsRepoException: $message';
}
