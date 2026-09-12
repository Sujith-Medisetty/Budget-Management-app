import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// SQLite bootstrap for Pocket. v2 swaps the three alert_at_X booleans
/// for a cleaner `alert_every` + `alert_thresholds` pair. Since this is
/// still pre-release we drop and recreate on the v1 → v2 upgrade; in
/// real production this would be a proper migration.
///
/// Local SQLite only holds USER DATA (transactions, budgets, AI log,
/// alert log). Per-user config (backup prefs, filter rules) lives in
/// Firestore `accounts/{sub}` and is fetched on demand via
/// `GET /accounts/<sub}` — no local mirror, no hydrator, no risk of
/// drift between device and cloud.
class DatabaseHelper {
  DatabaseHelper._({String? path}) : _pathOverride = path;
  static final DatabaseHelper instance = DatabaseHelper._();

  /// Test-only constructor: pass `:memory:` to get an in-memory
  /// database. Used by repository tests; production code should
  /// continue to use [instance].
  @visibleForTesting
  factory DatabaseHelper.test({String path = ':memory:'}) =>
      DatabaseHelper._(path: path);

  static const _dbName = 'pocket.db';
  static const _dbVersion = 4;

  final String? _pathOverride;
  Database? _database;

  Future<Database> get database async {
    _database ??= await _init();
    return _database!;
  }

  Future<Database> _init() async {
    final path = _pathOverride ?? p.join(await getDatabasesPath(), _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      // Belt-and-suspenders: the v2→v3 upgrade in [_onUpgrade] adds
      // `ai_log` non-destructively, but if the user upgrades through
      // a sequence where the cached Database singleton opens the
      // file at v2 before the new code's `_dbVersion = 3` reaches
      // it, the upgrade callback can be skipped. `onOpen` fires on
      // every successful open, so this guarantees `ai_log` exists
      // for any future schema additions too.
      onOpen: _onOpen,
    );
  }

  Future<void> _onOpen(Database db) async {
    await _createAiLog(db);
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createAll(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 → v2: rebuild from scratch. Pre-release.
    if (oldVersion < 2) {
      await db.execute('DROP TABLE IF EXISTS alert_log');
      await db.execute('DROP TABLE IF EXISTS budgets');
      await db.execute('DROP TABLE IF EXISTS transactions');
      await _createAll(db);
    }
    // v2 → v3: add ai_log. Non-destructive — old tables untouched.
    if (oldVersion < 3) {
      await _createAiLog(db);
    }
    // v3 → v4: add `ignored` to transactions. Non-destructive — default
    // 0 keeps every existing row active in spend calculations.
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE transactions ADD COLUMN ignored INTEGER NOT NULL DEFAULT 0',
      );
    }
    // v5 → v4 (downgrade): a user upgrading from the brief v5 build
    // (which carried an `accounts` + `backup_log` table mirroring
    // Firestore) loses those tables. The data they held is in
    // Firestore, so a fresh GET on next sign-in re-hydrates without
    // local loss. We DROP rather than leave the rows behind so the
    // sign-out "wipe everything" path doesn't trip over unknown
    // tables.
    if (oldVersion >= 5) {
      await db.execute('DROP TABLE IF EXISTS accounts');
      await db.execute('DROP TABLE IF EXISTS backup_log');
    }
  }

  Future<void> _createAll(Database db) async {
    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        notification_key TEXT UNIQUE NOT NULL,
        source TEXT NOT NULL,
        amount REAL NOT NULL,
        merchant TEXT NOT NULL,
        reason TEXT,
        occurred_at INTEGER NOT NULL,
        ignored INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_trans_occurred ON transactions(occurred_at DESC)',
    );

    await db.execute('''
      CREATE TABLE budgets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        amount REAL NOT NULL,
        period TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        alert_every INTEGER DEFAULT 0,
        alert_thresholds TEXT DEFAULT '80,100',
        active INTEGER DEFAULT 1,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE alert_log (
        budget_id INTEGER NOT NULL,
        threshold INTEGER NOT NULL,
        period_start TEXT NOT NULL,
        fired_at INTEGER NOT NULL,
        PRIMARY KEY (budget_id, threshold, period_start),
        FOREIGN KEY (budget_id) REFERENCES budgets(id) ON DELETE CASCADE
      )
    ''');

    await _createAiLog(db);
  }

  Future<void> _createAiLog(Database db) async {
    // IF NOT EXISTS is what makes this safe to call from both
    // onCreate / onUpgrade (fresh table creation) and onOpen
    // (defensive, runs every open). Without it, a second open
    // would throw "table ai_log already exists" and the app would
    // never reach the parser.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS ai_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL,
        package TEXT NOT NULL,
        source_text TEXT NOT NULL,
        ai_response TEXT,
        decision TEXT NOT NULL,
        reason TEXT,
        parsed_amount REAL,
        parsed_merchant TEXT,
        parsed_source TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ai_log_ts ON ai_log(ts DESC)',
    );
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// Drops every Pocket-owned row from the local SQLite. Used by the
  /// "sign out" path so a subsequent sign-back-in restores from cloud
  /// instead of carrying stale device-local state. The schema and
  /// AUTOINCREMENT counters are left alone — restore already resets
  /// the counters, and sign-out alone shouldn't reset them since the
  /// user might still be in the middle of writing a manual entry when
  /// the flow triggers.
  ///
  /// Delete order matches [BackupService.restore] to avoid FK trips:
  /// alert_log before budgets (FK chain), then transactions, then
  /// ai_log. Wrap in a single transaction so a mid-wipe crash leaves
  /// the DB consistent.
  Future<void> clearAllTables() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('alert_log');
      await txn.delete('transactions');
      await txn.delete('budgets');
      await txn.delete('ai_log');
    });
  }
}