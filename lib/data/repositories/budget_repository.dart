import 'package:sqflite/sqflite.dart';

import '../database/database_helper.dart';
import '../models/budget.dart';

class BudgetRepository {
  BudgetRepository(this._dbHelper);
  final DatabaseHelper _dbHelper;

  Future<Database> get _db => _dbHelper.database;

  /// Returns every budget, active and inactive, oldest first.
  Future<List<Budget>> all() async {
    final db = await _db;
    final rows = await db.query('budgets', orderBy: 'created_at ASC');
    return rows.map(Budget.fromMap).toList(growable: false);
  }

  /// The currently active budget, or null. We enforce at most one active
  /// via [activate]; if somehow multiple exist (legacy data, race) we
  /// return the most recently activated.
  Future<Budget?> firstActive() async {
    final db = await _db;
    final rows = await db.query(
      'budgets',
      where: 'active = 1',
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Budget.fromMap(rows.first);
  }

  /// If there are no budgets at all, this returns null too — callers use
  /// that to decide whether to nudge the user toward creating one.
  Future<Budget?> insert(Budget b) async {
    final db = await _db;
    final id = await db.insert('budgets', b.toMap()..remove('id'));
    return b.copyWith(id: id);
  }

  Future<void> update(Budget b) async {
    final db = await _db;
    await db.update('budgets', b.toMap(), where: 'id = ?', whereArgs: [b.id]);
  }

  Future<void> delete(int id) async {
    final db = await _db;
    await db.delete('budgets', where: 'id = ?', whereArgs: [id]);
  }

  /// Deletes [id]. If that budget was the active one, picks the
  /// alphabetically-first remaining budget (case-insensitive name) and
  /// activates it so the dashboard never goes dead. Returns the budget
  /// that became active (or null if the table is now empty).
  Future<Budget?> deleteAndReactivateNext(int id) async {
    final db = await _db;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'budgets',
        where: 'id = ?',
        whereArgs: [id],
        limit: 1,
      );
      final wasActive =
          rows.isNotEmpty && (rows.first['active'] as int? ?? 0) == 1;
      await txn.delete('budgets', where: 'id = ?', whereArgs: [id]);
      if (!wasActive) return null;
      final remaining = await txn.query(
        'budgets',
        orderBy: 'LOWER(name) ASC',
      );
      if (remaining.isEmpty) return null;
      await txn.update('budgets', {'active': 0});
      final nextId = remaining.first['id'] as int;
      await txn.update(
        'budgets',
        {'active': 1},
        where: 'id = ?',
        whereArgs: [nextId],
      );
      return Budget.fromMap(remaining.first);
    });
  }

  /// Atomically deactivates every budget then activates [budget]. Single
  /// active invariant lives here — callers should never touch the
  /// `active` column directly.
  Future<void> activate(Budget budget) async {
    if (budget.id == null) return;
    final db = await _db;
    await db.transaction((txn) async {
      await txn.update('budgets', {'active': 0});
      await txn.update(
        'budgets',
        {'active': 1},
        where: 'id = ?',
        whereArgs: [budget.id],
      );
    });
  }

  /// Returns true if we've already fired [threshold]% for this budget in
  /// the current period. Threshold is one of 50, 80, 100.
  Future<bool> hasFiredAlert({
    required int budgetId,
    required int threshold,
    required DateTime periodStart,
  }) async {
    final db = await _db;
    final rows = await db.query(
      'alert_log',
      where: 'budget_id = ? AND threshold = ? AND period_start = ?',
      whereArgs: [budgetId, threshold, _ymd(periodStart)],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Records that we've fired [threshold]% for this budget in this period.
  /// Idempotent via the composite primary key.
  Future<void> recordAlert({
    required int budgetId,
    required int threshold,
    required DateTime periodStart,
  }) async {
    final db = await _db;
    await db.insert(
      'alert_log',
      {
        'budget_id': budgetId,
        'threshold': threshold,
        'period_start': _ymd(periodStart),
        'fired_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}