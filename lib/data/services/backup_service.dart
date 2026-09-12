import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../database/database_helper.dart';
import '../models/budget.dart';
import '../models/transaction.dart';
import 'gmail_auth.dart';
import 'notification_service.dart';

/// Cloud backup of the user's transactions + budgets to Firestore via
/// `POST /backup/upload`. The server stores a single document per
/// Google sub (`backups/{googleSub}`) holding the full snapshot as a
/// JSON blob — atomic overwrite, no per-row subcollections.
///
/// Restore (`GET /backup/current`) is replace-all: the local SQLite
/// tables are wiped and the snapshot rows are inserted verbatim. AI
/// logs are intentionally NOT part of the backup — they stay device-local
/// because they describe parser decisions, not user data.
///
/// Why this is a single service for both directions:
///   - The two operations are mirror images of each other (read SQLite
///     → POST vs GET → write SQLite). Sharing the auth + HTTP setup
///     means only one place has to know about the Bearer token.
///   - Restore uses the same `_readRows` helpers as upload, just
///     inverted, so the row shape can never drift between the two.
///
/// Failure handling: every method returns a structured result (not an
/// exception) so the UI layer can render an inline status row without
/// having to wrap each call in try/catch. Network / decode failures
/// land in [BackupResult.error] as a human-readable string.
class BackupService {
  BackupService({
    required this._auth,
    NotificationService? notifier,
    Dio? http,
  })  : _notifier = notifier ?? NotificationService.instance,
        _http = http ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 15),
            ));

  final GmailAuth _auth;
  final NotificationService _notifier;
  final Dio _http;

  /// Uploads every transaction + budget row currently in local SQLite.
  /// Returns the upload timestamp on success. The server overwrites the
  /// `backups/{sub}` document atomically — there's no incremental merge
  /// to coordinate.
  ///
  /// Returns [BackupResult.failure] with `reason` if the user isn't
  /// signed in (no Bearer token) or the server rejects the payload.
  /// The caller is responsible for showing the inline status row +
  /// snackbar — this method never throws.
  Future<BackupResult> upload() async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) {
      return BackupResult.failure('Not signed in');
    }
    try {
      final transactions = await _allTransactions();
      final budgets = await _allBudgets();
      final body = jsonEncode({
        'transactions': transactions,
        'budgets': budgets,
      });
      if (kDebugMode) {
        debugPrint('[backup] uploading: '
            '${transactions.length} txns, ${budgets.length} budgets, '
            '${body.length} bytes');
      }
      final res = await _http.post<dynamic>(
        '$kServerUrl/backup/upload',
        data: body,
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 || res.data == null) {
        final err = (res.data is Map ? res.data['error'] : null) ??
            'HTTP ${res.statusCode}';
        return BackupResult.failure(err.toString());
      }
      final ts = res.data is Map
          ? res.data['uploadedAt'] as String?
          : null;
      return BackupResult.success(
        uploadedAt: ts != null ? DateTime.tryParse(ts) : null,
        transactions: transactions.length,
        budgets: budgets.length,
      );
    } on DioException catch (e) {
      return BackupResult.failure(_dioReason(e));
    } catch (e) {
      return BackupResult.failure(e.toString());
    }
  }

  /// Pulls the user's `backups/{sub}` document and replaces every
  /// local transaction + budget with the rows from the snapshot.
  /// Triggers and load — no merge, no incremental apply. The alert
  /// log is wiped too because budget IDs change and the composite key
  /// would otherwise reference rows that no longer exist.
  ///
  /// Why we don't try to be smart about merging: the snapshot is the
  /// authoritative state from a different device (or an earlier
  /// point in time on this one). Anything the user added locally
  /// since the snapshot was taken is, by definition, not in the
  /// backup — restore is "I want what's in the cloud, not what I
  /// have here."
  Future<BackupResult> restore() async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) {
      return BackupResult.failure('Not signed in');
    }
    try {
      final res = await _http.get<dynamic>(
        '$kServerUrl/backup/current',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 404) {
        return BackupResult.failure('No backup found in cloud');
      }
      if (res.statusCode != 200 || res.data == null) {
        return BackupResult.failure('HTTP ${res.statusCode}');
      }
      final data = res.data as Map<String, dynamic>;
      final txnsRaw = (data['transactions'] as List?) ?? const [];
      final budgetsRaw = (data['budgets'] as List?) ?? const [];
      final txns = txnsRaw
          .whereType<Map>()
          .map((m) => _txnFromBackup(m.cast<String, dynamic>()))
          .toList(growable: false);
      final budgets = budgetsRaw
          .whereType<Map>()
          .map((m) => _budgetFromBackup(m.cast<String, dynamic>()))
          .toList(growable: false);

      final db = await DatabaseHelper.instance.database;
      await db.transaction((txn) async {
        // alert_log first — its FK to budgets(id) would block the
        // budgets delete otherwise. Same FK chain doesn't exist for
        // transactions so the order between those two doesn't matter.
        await txn.delete('alert_log');
        await txn.delete('transactions');
        await txn.delete('budgets');
        for (final b in budgets) {
          await txn.insert('budgets', b.toMap()..remove('id'));
        }
        for (final t in txns) {
          await txn.insert('transactions', t.toMap()..remove('id'));
        }
        // Reset autoincrement counters so future manual entries get
        // ids that don't collide with anything previously imported.
        // SQLite stores these in `sqlite_sequence`; missing rows just
        // mean "no autoincrement yet" and the UPDATE no-ops.
        await txn.rawUpdate(
          "UPDATE sqlite_sequence SET seq = (SELECT MAX(id) FROM transactions) "
          "WHERE name = 'transactions'",
        );
        await txn.rawUpdate(
          "UPDATE sqlite_sequence SET seq = (SELECT MAX(id) FROM budgets) "
          "WHERE name = 'budgets'",
        );
      });
      return BackupResult.success(
        uploadedAt: data['uploadedAt'] is String
            ? DateTime.tryParse(data['uploadedAt'] as String)
            : null,
        transactions: txns.length,
        budgets: budgets.length,
      );
    } on DioException catch (e) {
      return BackupResult.failure(_dioReason(e));
    } catch (e) {
      return BackupResult.failure(e.toString());
    }
  }

  /// Wipes the user's cloud backup. Used by the disconnect dialog
  /// "delete backup + sign out" path — distinct from /account/delete
  /// (which wipes the account record too) because we want to let the
  /// user sign back in fresh later. The server endpoint is idempotent
  /// and returns 200 even when there was no backup to remove.
  Future<bool> removeBackup() async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) return false;
    try {
      final res = await _http.post<dynamic>(
        '$kServerUrl/backup/remove',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      return res.statusCode == 200;
    } on DioException catch (e) {
      if (kDebugMode) debugPrint('[backup] removeBackup failed: $e');
      return false;
    }
  }

  /// Lightweight probe: hits GET /backup/current and returns just the
  /// `uploadedAt` timestamp + row counts without touching SQLite. The
  /// Delete Account screen uses this to decide whether to block the
  /// user with "take a fresh backup first". Distinct from [restore]
  /// which would nuke local rows — that side effect is exactly what
  /// we don't want here.
  ///
  /// Returns null when no backup exists or the server reply is
  /// malformed. Network/5xx errors propagate as [DioException] so the
  /// caller can show "couldn't check backup freshness — try again".
  Future<BackupInfo?> getBackupInfo() async {
    final apiToken = await _auth.tryRestore();
    if (apiToken == null) return null;
    try {
      final res = await _http.get<dynamic>(
        '$kServerUrl/backup/current',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode == 404) return null;
      if (res.statusCode != 200 || res.data is! Map) return null;
      final data = res.data as Map<String, dynamic>;
      final tsRaw = data['uploadedAt'];
      final ts = tsRaw is String ? DateTime.tryParse(tsRaw) : null;
      if (ts == null) return null;
      return BackupInfo(
        uploadedAt: ts,
        transactions: (data['transactions'] as List?)?.length ?? 0,
        budgets: (data['budgets'] as List?)?.length ?? 0,
      );
    } on DioException catch (e) {
      if (kDebugMode) debugPrint('[backup] getBackupInfo failed: $e');
      return null;
    }
  }

  Future<void> notifySuccess({
    required int transactions,
    required int budgets,
  }) async {
    try {
      await _notifier.showRaw(
        title: 'Backup complete',
        body: '$transactions transactions · $budgets budgets saved',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[backup] notify success failed: $e');
    }
  }

  Future<void> notifyFailure(String reason) async {
    try {
      await _notifier.showRaw(
        title: 'Backup failed',
        body: reason,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[backup] notify failure failed: $e');
    }
  }

  /// Notify the user that a user-initiated restore finished. Fired
  /// only when the user has `notifyOnRestoreComplete` toggled on in
  /// the Backup screen — otherwise the in-app snackbar is the only
  /// confirmation.
  Future<void> notifyRestoreComplete({
    required int transactions,
    required int budgets,
  }) async {
    try {
      await _notifier.showRaw(
        title: 'Restore complete',
        body: '$transactions transactions · $budgets budgets loaded',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[backup] notify restore failed: $e');
    }
  }

  Future<List<Map<String, Object?>>> _allTransactions() async {
    // Pull every row, not just the recent N — the user might have
    // entries from months ago that aren't in the dashboard query but
    // still belong in the backup. The server's 5 MB body cap is
    // generous enough (~25k transactions) that this won't run into it.
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('transactions');
    return rows.map((r) => r.map((k, v) => MapEntry(k, v))).toList(
          growable: false,
        );
  }

  Future<List<Map<String, Object?>>> _allBudgets() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query('budgets');
    return rows.map((r) => r.map((k, v) => MapEntry(k, v))).toList(
          growable: false,
        );
  }

  Transaction _txnFromBackup(Map<String, dynamic> m) => Transaction(
        id: null,
        notificationKey: m['notification_key'] as String,
        source: m['source'] as String,
        amount: (m['amount'] as num).toDouble(),
        merchant: m['merchant'] as String,
        reason: m['reason'] as String?,
        occurredAt: DateTime.fromMillisecondsSinceEpoch(m['occurred_at'] as int),
        ignored: ((m['ignored'] as int?) ?? 0) != 0,
      );

  Budget _budgetFromBackup(Map<String, dynamic> m) => Budget(
        id: null,
        name: m['name'] as String,
        amount: (m['amount'] as num).toDouble(),
        period: BudgetPeriod.values.firstWhere(
          (p) => p.name == m['period'],
          orElse: () => BudgetPeriod.monthly,
        ),
        startDate: DateTime.parse(m['start_date'] as String),
        endDate: DateTime.parse(m['end_date'] as String),
        alertEvery: (m['alert_every'] as int? ?? 0) == 1,
        alertThresholds: Budget.parseThresholds(
          m['alert_thresholds'] as String?,
        ),
        active: (m['active'] as int? ?? 0) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );

  String _dioReason(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Network timeout — check connection';
      case DioExceptionType.connectionError:
        return 'No network connection';
      case DioExceptionType.badResponse:
        return 'Server returned ${e.response?.statusCode ?? "?"}';
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
      case DioExceptionType.transformTimeout:
        return e.message ?? 'Network error';
    }
  }
}

/// Result of an upload or restore call. Either [success] is true with
/// counts populated, or [success] is false with [reason] populated.
/// Timestamp is whatever the server returned (may be null if the
/// server didn't include one — keep UI tolerant).
class BackupResult {
  BackupResult._({
    required this.success,
    this.uploadedAt,
    this.transactions = 0,
    this.budgets = 0,
    this.reason,
  });

  factory BackupResult.success({
    DateTime? uploadedAt,
    required int transactions,
    required int budgets,
  }) =>
      BackupResult._(
        success: true,
        uploadedAt: uploadedAt,
        transactions: transactions,
        budgets: budgets,
      );

  factory BackupResult.failure(String reason) =>
      BackupResult._(success: false, reason: reason);

  final bool success;
  final DateTime? uploadedAt;
  final int transactions;
  final int budgets;
  final String? reason;
}

/// Snapshot of the user's last backup, fetched independently of
/// restore so callers can show "last backed up X minutes ago" without
/// wiping local rows. Returned by [BackupService.getBackupInfo].
class BackupInfo {
  const BackupInfo({
    required this.uploadedAt,
    required this.transactions,
    required this.budgets,
  });

  final DateTime uploadedAt;
  final int transactions;
  final int budgets;
}
