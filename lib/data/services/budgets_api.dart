import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../models/budget.dart';
import 'gmail_auth.dart';

/// Outcome of `GET /budgets/ensure-current`. The server returns:
///   - `alreadyExisted` — a row for the current calendar month
///     existed on the server; the device may or may not have it
///     locally. Mobile uses this only to confirm there's a row
///     somewhere.
///   - `createdNow` — server minted a fresh row (the user's first
///     sign-in of the new month, or the auto-create flow on the
///     device is off but turned back on). The body carries the
///     new [BudgetPayload] so the device can mirror it into local
///     SQLite.
///   - `userOptedOut` — `accounts.budget_prefs.autoMonthlyBudget`
///     is false on the server. The device should not insert a
///     mirrored row; the user has explicitly disabled the flow.
enum EnsureCurrentResult {
  alreadyExisted,
  createdNow,
  userOptedOut;

  static EnsureCurrentResult fromName(String name) {
    for (final v in EnsureCurrentResult.values) {
      if (v.name == name) return v;
    }
    return EnsureCurrentResult.alreadyExisted;
  }
}

/// Server-side Budget row shape. The id is server-minted (UUID-ish),
/// unlike the device-side `int?` sqlite autoincrement — they're not
/// the same space. The hydrator matches on `(name, startDate)` rather
/// than `id` so re-runs are safe. See `BudgetHydrator.ensureCurrentMonth`.
class BudgetPayload {
  const BudgetPayload({
    required this.id,
    required this.name,
    required this.amount,
    required this.period,
    required this.startDate,
    required this.endDate,
    required this.active,
    required this.source,
    required this.createdAt,
    this.alertEvery,
    this.alertThresholds,
  });

  final String id;
  final String name;
  final double amount;
  final String period;
  final DateTime startDate;
  final DateTime endDate;
  final bool active;
  final String source;
  final DateTime createdAt;
  final bool? alertEvery;
  final String? alertThresholds;

  factory BudgetPayload.fromJson(Map<String, dynamic> j) {
    DateTime parseDate(Object? v) {
      // Server returns "YYYY-MM-DD" (substring of ISO-8601).
      final s = v is String
          ? v
          : (v is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  v.toInt(),
                  isUtc: true,
                ).toIso8601String().substring(0, 10)
              : '');
      return DateTime.parse(s);
    }

    DateTime parseIso(Object? v) {
      final s = v is String ? v : '';
      return DateTime.parse(s);
    }

    return BudgetPayload(
      id: j['id'] as String,
      name: j['name'] as String,
      amount: (j['amount'] as num).toDouble(),
      period: j['period'] as String,
      startDate: parseDate(j['startDate']),
      endDate: parseDate(j['endDate']),
      active: j['active'] as bool? ?? false,
      source: j['source'] as String? ?? 'auto',
      createdAt: parseIso(j['createdAt']),
      alertEvery: j['alertEvery'] as bool?,
      alertThresholds: j['alertThresholds'] as String?,
    );
  }

  /// Convert to the mobile-side [Budget] (data/models/budget.dart)
  /// for insertion into local SQLite. The `id` is intentionally null
  /// — let SQLite mint the local autoincrement so the device-side
  /// row id stays in the device's own id space and never references
  /// the server's UUID.
  Budget toMobileBudget() {
    return Budget(
      id: null,
      name: name,
      amount: amount,
      // Period enum on mobile only has weekly/monthly/custom — see
      // `data/models/budget.dart::BudgetPeriod`. Anything else falls
      // back to custom (the device-side `range()` uses startDate /
      // endDate in that case).
      period: switch (period) {
        'weekly' => BudgetPeriod.weekly,
        'monthly' => BudgetPeriod.monthly,
        _ => BudgetPeriod.custom,
      },
      startDate: startDate,
      endDate: endDate,
      alertEvery: alertEvery ?? false,
      alertThresholds: alertThresholds == null
          ? const [80, 100]
          : Budget.parseThresholds(alertThresholds),
      active: active,
      createdAt: createdAt,
    );
  }
}

/// REST client for the server-side `budgets` table. Currently used
/// only for `GET /budgets/ensure-current` on sign-in — the device
/// is otherwise the source of truth for budgets and reads from
/// local SQLite. A future restore-from-server path would add
/// `GET /budgets?month=YYYY-MM` for historical sync.
class BudgetsApi {
  BudgetsApi({required this.auth, Dio? http}) : _http = http ?? _dio();

  final GmailAuth auth;
  final Dio _http;

  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
        sendTimeout: const Duration(seconds: 5),
      ));

  /// `GET /budgets/ensure-current`. Returns the result enum + (when
  /// createdNow) the BudgetPayload. Idempotent — calling repeatedly
  /// is safe.
  Future<({EnsureCurrentResult result, BudgetPayload? budget})>
      ensureCurrentMonth() async {
    final apiToken = await auth.tryRestore();
    if (apiToken == null) {
      // Not signed in — fall back to no-op. The mobile `autoRestoreAfterSignIn`
      // is the single caller and only runs post-sign-in, so this branch
      // is just defence in depth.
      return (result: EnsureCurrentResult.alreadyExisted, budget: null);
    }
    try {
      if (kDebugMode) {
        debugPrint('[budgets-api] GET /budgets/ensure-current');
      }
      final res = await _http.get<dynamic>(
        '$kServerUrl/budgets/ensure-current',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200) {
        throw BudgetsApiException(
            'ensure-current failed: status=${res.statusCode}');
      }
      final body = _decodeBody(res.data, res.statusCode);
      final resultStr = body['result'] as String? ?? 'alreadyExisted';
      final budgetJson = body['budget'];
      return (
        result: EnsureCurrentResult.fromName(resultStr),
        budget: budgetJson is Map
            ? BudgetPayload.fromJson(budgetJson.cast<String, dynamic>())
            : null,
      );
    } on DioException catch (e) {
      throw BudgetsApiException(
          'ensure-current failed: message=${e.message}');
    }
  }

  /// `PATCH /budgets/match` — push the local budget's alert prefs to
  /// the server so a sign-in on a different device (or after a
  /// local DB wipe) can recover them. Match key is `(name,
  /// startDate)` because the mobile's local autoincrement id and
  /// the server's UUID id live in different namespaces — the form
  /// has neither to send.
  ///
  /// Returns true on success (200) OR when the budget is
  /// locally-only on this device (404 — manual creation, no server
  /// counterpart). The mobile treats 404 as a successful no-op so
  /// the same call site works for both auto-created and manual
  /// budgets without branching.
  ///
  /// Throws on transport failures (timeout, 5xx with body, DNS) —
  /// the caller logs and moves on since the local SQLite has
  /// already been updated and the R2 backup is the next-best path
  /// to a cross-device restore.
  Future<bool> patchAlertPrefs({
    required String name,
    required DateTime startDate,
    required bool alertEvery,
    required List<int> alertThresholds,
  }) async {
    final apiToken = await auth.tryRestore();
    if (apiToken == null) {
      // Not signed in — there's nothing to sync. Return true so the
      // caller's "fire and forget" pattern works without branching
      // on auth state at every site.
      if (kDebugMode) {
        debugPrint('[budgets-api] PATCH /budgets/match skipped: not signed in');
      }
      return true;
    }
    try {
      final body = jsonEncode({
        'name': name,
        'startDate':
            '${startDate.year.toString().padLeft(4, '0')}-'
            '${startDate.month.toString().padLeft(2, '0')}-'
            '${startDate.day.toString().padLeft(2, '0')}',
        'alertEvery': alertEvery,
        'alertThresholds': alertThresholds.join(','),
      });
      if (kDebugMode) {
        debugPrint('[budgets-api] PATCH /budgets/match name=$name '
            'alertEvery=$alertEvery thresholds=$alertThresholds');
      }
      final res = await _http.patch<dynamic>(
        '$kServerUrl/budgets/match',
        data: body,
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 200 || res.statusCode == 404) {
        return true;
      }
      throw BudgetsApiException(
          'patch-match failed: status=${res.statusCode} '
          'body=${res.data}');
    } on DioException catch (e) {
      throw BudgetsApiException(
          'patch-match failed: message=${e.message}');
    }
  }

  Map<String, dynamic> _decodeBody(dynamic data, int? status) {
    if (data is Map<String, dynamic>) return data;
    if (data is String) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map<String, dynamic>) return decoded;
        throw BudgetsApiException(
            'decoded body is ${decoded.runtimeType}, not Map');
      } on FormatException catch (e) {
        throw BudgetsApiException('body is not valid JSON: $e');
      }
    }
    throw BudgetsApiException('unexpected body type: ${data.runtimeType}');
  }
}

class BudgetsApiException implements Exception {
  BudgetsApiException(this.message);
  final String message;
  @override
  String toString() => 'BudgetsApiException: $message';
}
