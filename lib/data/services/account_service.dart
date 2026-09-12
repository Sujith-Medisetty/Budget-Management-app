import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../database/database_helper.dart';
import 'gmail_auth.dart';

/// User-facing "delete my account" — server wipes everything
/// (Gmail filter, accounts/{sub}, filter_rules, GCS backup), then
/// the phone wipes its own SQLite + SecureStorage. Idempotent on
/// the server side; locally we only wipe once per call.
///
/// Why a separate service: the wiring spans three systems (network,
/// SQLite, SecureStorage). Pulling it into a single method means
/// callers can `await accountService.deleteAccount()` and trust the
/// local state will be clean regardless of which underlying call
/// succeeded. Without it, each screen that wanted to expose delete
/// would reimplement the dance and drift.
///
/// `onComplete` runs after every successful deletion so the caller
/// can navigate back to the login screen — kept as a callback rather
/// than a returned Future because the order "delete → wipe → navigate"
/// shouldn't be reordered by a caller who just awaits.
class AccountService {
  AccountService({
    required GmailAuth auth,
    Dio? http,
  })  : _auth = auth,
        _http = http ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  final GmailAuth _auth;
  final Dio _http;

  /// Result returned to the UI layer — keep this small so the
  /// caller can render either a snackbar or a screen-level error
  /// without parsing a tree.
  Future<DeleteResult> deleteAccount() async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) {
      return DeleteResult.failure('Not signed in');
    }
    try {
      final res = await _http.post<dynamic>(
        '$kServerUrl/account/delete',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        return DeleteResult.failure('Server returned ${res.statusCode}');
      }
      // Server confirmed the wipe. Tear down local state next —
      // order matters: SecureStorage last so `_auth.tryRestore`
      // above can still find the token until the very end.
      await _wipeLocal();
      return DeleteResult.success();
    } on DioException catch (e) {
      if (kDebugMode) debugPrint('[account] delete failed: $e');
      // Server call failed but the user's intent ("delete my account")
      // is unambiguous. Wipe locally anyway so the phone isn't sitting
      // on a zombie session; the server-side state will catch up on
      // the next op (e.g., a re-login attempt gets a 401 because the
      // account is gone, signaling them what's up).
      await _wipeLocal();
      return DeleteResult.failure(
          'Could not reach server (${_dioReason(e)}). Local data cleared.');
    } catch (e) {
      if (kDebugMode) debugPrint('[account] delete failed: $e');
      await _wipeLocal();
      return DeleteResult.failure(e.toString());
    }
  }

  Future<void> _wipeLocal() async {
    try {
      await DatabaseHelper.instance.clearAllTables();
    } catch (e) {
      if (kDebugMode) debugPrint('[account] local SQLite wipe failed: $e');
    }
    // Always sign out last — signOut() also wipes SecureStorage. Doing
    // this AFTER the SQLite wipe means any provider ref.invalidate
    // wired to signOut won't see half-empty state.
    try {
      await _auth.signOut();
    } catch (e) {
      if (kDebugMode) debugPrint('[account] signOut failed: $e');
    }
  }

  String _dioReason(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return 'timeout';
      case DioExceptionType.connectionError:
        return 'no network';
      default:
        return 'network error';
    }
  }
}

class DeleteResult {
  const DeleteResult._({required this.success, this.reason});
  factory DeleteResult.success() => const DeleteResult._(success: true);
  factory DeleteResult.failure(String reason) =>
      DeleteResult._(success: false, reason: reason);

  final bool success;
  final String? reason;
}
