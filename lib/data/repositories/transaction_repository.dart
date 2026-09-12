import 'package:sqflite/sqflite.dart' hide Transaction;

import '../database/database_helper.dart';
import '../models/transaction.dart';

class TransactionRepository {
  TransactionRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  Future<Database> get _db => _dbHelper.database;

  /// Insert if [notificationKey] is new; returns the row (existing or new)
  /// so the caller can dedup cheaply without a second round-trip. Used by
  /// the notification pipeline for auto-captured PayPal / Google Pay.
  Future<({Transaction row, bool inserted})> insertIfNew(
    Transaction t,
  ) async {
    final db = await _db;
    final existing = await db.query(
      'transactions',
      where: 'notification_key = ?',
      whereArgs: [t.notificationKey],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      return (row: Transaction.fromMap(existing.first), inserted: false);
    }
    final id = await db.insert('transactions', t.toMap()..remove('id'));
    return (row: t.copyWith(id: id), inserted: true);
  }

  /// Inserts a manually-entered expense. Generates a synthetic
  /// notification_key so it still flows through dedup naturally.
  Future<Transaction> insertManual(Transaction t) async {
    final db = await _db;
    final withKey = t.notificationKey.isEmpty
        ? t.copyWith(
            notificationKey:
                'manual-${DateTime.now().microsecondsSinceEpoch}',
          )
        : t;
    final id = await db.insert('transactions', withKey.toMap()..remove('id'));
    return withKey.copyWith(id: id);
  }

  Future<Transaction?> findByKey(String key) async {
    final db = await _db;
    final rows = await db.query(
      'transactions',
      where: 'notification_key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : Transaction.fromMap(rows.first);
  }

  Future<List<Transaction>> recent({int limit = 200}) async {
    final db = await _db;
    final rows = await db.query(
      'transactions',
      orderBy: 'occurred_at DESC',
      limit: limit,
    );
    return rows.map(Transaction.fromMap).toList(growable: false);
  }

  /// Transactions that happened inside [start, end]. Newest first.
  Future<List<Transaction>> inRange(DateTime start, DateTime end) async {
    final db = await _db;
    final rows = await db.query(
      'transactions',
      where: 'occurred_at >= ? AND occurred_at <= ?',
      whereArgs: [
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      ],
      orderBy: 'occurred_at DESC',
    );
    return rows.map(Transaction.fromMap).toList(growable: false);
  }

  /// Sum of positive amounts (spend) within [start, end]. Ignored
  /// rows are excluded — the user has explicitly marked them as not
  /// part of their spend, so they don't count toward budgets.
  Future<double> spentBetween(DateTime start, DateTime end) async {
    final db = await _db;
    final r = await db.rawQuery(
      '''
      SELECT COALESCE(SUM(amount), 0) AS total
      FROM transactions
      WHERE occurred_at >= ? AND occurred_at <= ?
        AND amount > 0
        AND ignored = 0
      ''',
      [
        start.millisecondsSinceEpoch,
        end.millisecondsSinceEpoch,
      ],
    );
    return (r.first['total'] as num).toDouble();
  }

  /// Replaces the row with [t.id]. Used by the edit-expense flow.
  Future<void> update(Transaction t) async {
    final db = await _db;
    final id = t.id;
    if (id == null) {
      throw ArgumentError('Cannot update a transaction without an id');
    }
    await db.update(
      'transactions',
      t.toMap()..remove('id'),
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Deletes the row by id. Used by the edit-expense sheet's Delete button.
  Future<void> deleteById(int id) async {
    final db = await _db;
    await db.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  /// Bulk delete. Used by the multi-select delete flow on the
  /// transactions screen. Returns the number of rows actually
  /// removed (so the caller can show an accurate undo toast if it
  /// adds one later).
  Future<int> deleteByIds(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final db = await _db;
    final placeholders = List.filled(ids.length, '?').join(',');
    return db.delete(
      'transactions',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// Flips the `ignored` flag for a single row. The edit sheet uses
  /// this for the "Ignore from spending" switch; the agent uses it for
  /// the `set_ignored` action. Returning the refreshed row lets the
  /// caller invalidate providers with the canonical post-update state.
  Future<Transaction?> setIgnored(int id, bool ignored) async {
    final db = await _db;
    final affected = await db.update(
      'transactions',
      {'ignored': ignored ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
    if (affected == 0) return null;
    final rows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Transaction.fromMap(rows.first);
  }
}