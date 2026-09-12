import 'dart:math';

import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';

import 'accounts_repo.dart';
import 'token_store.dart';

/// Postgres-backed access to the server-side `budgets` table. The
/// phone is still the editor / source of truth for user-visible
/// state; this repo exists so:
///   1. The 1st-of-month cron can mint next month's row even if the
///      user doesn't sign in mid-rollover.
///   2. The sign-in path's `ensureCurrentMonthBudget` helper can
///      mint a row immediately for a brand-new account that lands
///      mid-month.
///   3. A future restore-from-server flow has historical rows to
///      pull from.
///
/// Shares the same Postgres connection as [AccountsRepo] (passed in
/// via the constructor — pass `accountsRepo.ready()` as the
/// future-bound connection access). NOT a separate pool — keeping a
/// single connection keeps the schema layout consistent and means
/// the cron doesn't double the Postgres connection count.
///
/// Schema (see `tool/schema_postgres.sql`):
///   - primary key: (sub, id)
///   - period check: daily/weekly/monthly/yearly/custom
///   - source check: auto/manual
///   - indexes: budgets_sub_start_idx (sub, start_date),
///              budgets_sub_active_idx (sub) WHERE active
class BudgetsRepo {
  BudgetsRepo({required this.accounts});

  /// Parent [AccountsRepo]. Used to reuse its connection so we
  /// don't open a second Postgres connection just for this table.
  final AccountsRepo accounts;
  final _log = Logger('budgets-repo');

  /// Mint a server UUID. We don't reuse the phone-side int
  /// autoincrement because the server has no way to predict what
  /// the next local id would be on the device.
  String _mintId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    // RFC 4122 v4 shape — set the version and variant bits so the
    // id round-trips safely through any tooling that expects UUID.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final buf = StringBuffer();
    for (var i = 0; i < hex.length; i++) {
      if (i == 8 || i == 12 || i == 16 || i == 20) buf.write('-');
      buf.write(hex[i]);
    }
    return buf.toString();
  }

  /// Insert a new auto-created row. The `id` and `createdAt` are
  /// minted server-side; `sub` / `name` / `amount` / `period` /
  /// `startDate` / `endDate` / `active` / `source` come from the
  /// caller. `alertEvery` / `alertThresholds` are typically null
  /// for auto-created rows — the user adjusts them on the device
  /// and the device mirrors them back later.
  ///
  /// Returns the persisted [Budget] (with the new `id` and
  /// `createdAt`).
  Future<Budget> insert({
    required String sub,
    required String name,
    required double amount,
    required String period,
    required DateTime startDate,
    required DateTime endDate,
    required bool active,
    String source = 'auto',
    bool? alertEvery,
    String? alertThresholds,
  }) async {
    final conn = await accounts.ready();
    final id = _mintId();
    final now = DateTime.now().toUtc();
    await conn.execute(
      Sql.named('''
      INSERT INTO budgets (
        sub, id, name, amount, period,
        start_date, end_date, active, source,
        alert_every, alert_thresholds, created_at
      ) VALUES (
        @sub, @id, @name, @amount, @period,
        @startDate::date, @endDate::date, @active, @source,
        @alertEvery, @alertThresholds, @createdAt
      )
      '''),
      parameters: {
        'sub': sub,
        'id': id,
        'name': name,
        'amount': amount,
        'period': period,
        'startDate': startDate,
        'endDate': endDate,
        'active': active,
        'source': source,
        'alertEvery': alertEvery,
        'alertThresholds': alertThresholds,
        'createdAt': now,
      },
    );
    return Budget(
      sub: sub,
      id: id,
      name: name,
      amount: amount,
      period: period,
      startDate: startDate,
      endDate: endDate,
      active: active,
      source: source,
      createdAt: now,
      alertEvery: alertEvery,
      alertThresholds: alertThresholds,
    );
  }

  /// All rows for a sub, ordered chronologically. Used by the
  /// `GET /budgets?month=YYYY-MM` endpoint and the rollover helper
  /// that needs to find the latest auto-created budget to copy the
  /// cap from.
  Future<List<Budget>> listForSub(String sub) async {
    final conn = await accounts.ready();
    final res = await conn.execute(
      Sql.named('SELECT sub, id, name, amount, period, start_date, end_date, '
          'active, source, alert_every, alert_thresholds, created_at '
          'FROM budgets WHERE sub=@sub ORDER BY start_date ASC'),
      parameters: {'sub': sub},
    );
    return res.map(_rowToBudget).toList(growable: false);
  }

  /// All budgets in a given calendar month for a sub. `monthStart`
  /// should be the 1st-of-month (UTC midnight). Used by the mobile
  /// sign-in hydration so the phone can pull server-created rows
  /// for the months it missed.
  Future<List<Budget>> listForSubInMonth(
    String sub,
    DateTime monthStart,
  ) async {
    final conn = await accounts.ready();
    final nextMonth = DateTime.utc(monthStart.year, monthStart.month + 1, 1);
    final res = await conn.execute(
      Sql.named('SELECT sub, id, name, amount, period, start_date, end_date, '
          'active, source, alert_every, alert_thresholds, created_at '
          'FROM budgets WHERE sub=@sub '
          'AND start_date >= @start::date AND start_date < @end::date '
          'ORDER BY start_date ASC'),
      parameters: {
        'sub': sub,
        'start': monthStart,
        'end': nextMonth,
      },
    );
    return res.map(_rowToBudget).toList(growable: false);
  }

  /// Latest auto-created budget for a sub (regardless of month) —
  /// used by `budget_rollover` to copy the cap from. Returns null
  /// for first-time users.
  Future<Budget?> latestAuto(String sub) async {
    final conn = await accounts.ready();
    final res = await conn.execute(
      Sql.named('SELECT sub, id, name, amount, period, start_date, end_date, '
          'active, source, alert_every, alert_thresholds, created_at '
          'FROM budgets WHERE sub=@sub AND source=\'auto\' '
          'ORDER BY start_date DESC LIMIT 1'),
      parameters: {'sub': sub},
    );
    if (res.isEmpty) return null;
    return _rowToBudget(res.first);
  }

  /// The currently-active row for a sub, or null when none exists.
  /// The DB enforces at-most-one-active via the activate() method,
  /// so the LIMIT 1 here is just defensive.
  Future<Budget?> activeFor(String sub) async {
    final conn = await accounts.ready();
    final res = await conn.execute(
      Sql.named('SELECT sub, id, name, amount, period, start_date, end_date, '
          'active, source, alert_every, alert_thresholds, created_at '
          'FROM budgets WHERE sub=@sub AND active LIMIT 1'),
      parameters: {'sub': sub},
    );
    if (res.isEmpty) return null;
    return _rowToBudget(res.first);
  }

  /// Transactional activation: clear `active` on every existing row
  /// for this sub and set it on the target row. Postgres doesn't
  /// guarantee at-most-one-active without this — the table has no
  /// unique partial index on `active` per sub (and adding one would
  /// be migration friction). Both steps run in the same transaction
  /// so a crash between them doesn't leave two rows active.
  Future<void> activate(String sub, String id) async {
    final conn = await accounts.ready();
    await conn.runTx((txn) async {
      await txn.execute(
        Sql.named('UPDATE budgets SET active=false WHERE sub=@sub AND active'),
        parameters: {'sub': sub},
      );
      await txn.execute(
        Sql.named('UPDATE budgets SET active=true WHERE sub=@sub AND id=@id'),
        parameters: {'sub': sub, 'id': id},
      );
    });
    _log.info('activate($sub, $id) committed');
  }

  /// Update the alert prefs for the budget matching `(sub, name,
  /// start_date)`. Used by the mobile `BudgetFormScreen` after every
  /// local edit so a sign-out/sign-in cycle on a second device can
  /// recover the user's alert prefs from this row. Returns the
  /// updated [Budget], or null when no matching row exists — the
  /// caller treats null as "locally-only budget, nothing to sync"
  /// and silently moves on (manual local creations never have a
  /// server-side counterpart).
  ///
  /// Match on (name, start_date) rather than `id` because the
  /// mobile's local SQLite autoincrement id and the server's UUID
  /// id live in different namespaces — the form screen has neither
  /// to send, and sending both would just create room for drift.
  Future<Budget?> updateAlertPrefs({
    required String sub,
    required String name,
    required DateTime startDate,
    required bool? alertEvery,
    required String? alertThresholds,
  }) async {
    final conn = await accounts.ready();
    final res = await conn.execute(
      Sql.named('''
      UPDATE budgets
         SET alert_every = @alertEvery,
             alert_thresholds = @alertThresholds
       WHERE sub = @sub
         AND name = @name
         AND start_date = @startDate::date
       RETURNING sub, id, name, amount, period, start_date, end_date,
                 active, source, alert_every, alert_thresholds, created_at
      '''),
      parameters: {
        'sub': sub,
        'name': name,
        'startDate': startDate,
        'alertEvery': alertEvery,
        'alertThresholds': alertThresholds,
      },
    );
    if (res.isEmpty) return null;
    return _rowToBudget(res.first);
  }

  /// Removes a row. Used by the phone in the (rare) case the user
  /// deletes a budget locally and the server-side copy needs to
  /// follow. Not wired today (phone-only delete) but cheap to keep
  /// around for symmetry.
  Future<void> remove(String sub, String id) async {
    final conn = await accounts.ready();
    await conn.execute(
      Sql.named('DELETE FROM budgets WHERE sub=@sub AND id=@id'),
      parameters: {'sub': sub, 'id': id},
    );
  }

  /// List every account's `sub` + `auto_monthly_budget` pref in one
  /// query — used by the 1st-of-month cron to decide whom to mint
  /// for. Returns the empty list when the table is empty / cron
  /// hasn't run yet.
  Future<List<({String sub, bool autoMonthlyBudget})>>
      accountsWithAutoBudget() async {
    final conn = await accounts.ready();
    final res = await conn.execute(
      Sql.named("SELECT sub, budget_prefs->'autoMonthlyBudget' AS auto "
          "FROM accounts WHERE (budget_prefs->>'autoMonthlyBudget')::text "
          "<>'false'"),
      parameters: {},
    );
    return res
        .map((r) => (
              sub: r[0]! as String,
              autoMonthlyBudget: (r[1] as bool?) ?? true,
            ))
        .toList(growable: false);
  }

  /// Iterate every account's `sub` (used by the cron). Pulled
  /// separately from `accountsWithAutoBudget` so a future admin
  /// tool can re-use it without cooking in the WHERE clause.
  Future<List<String>> allSubs() async {
    final conn = await accounts.ready();
    final res = await conn.execute('SELECT sub FROM accounts');
    return res.map((r) => r[0]! as String).toList(growable: false);
  }

  Budget _rowToBudget(ResultRow row) {
    // The `postgres` Dart driver returns `numeric` / `decimal` columns
    // as `String` (e.g. `"0.00"`) unless a type-coercion codec is
    // installed — casting to `num` directly throws `type 'String' is
    // not a subtype of type 'num'`. Parse explicitly so SELECTs from
    // the `budgets.amount` column work the same way as INSERTs, which
    // accept a Dart `double` and send it as text-encoded numeric.
    final amountRaw = row[3];
    final amount = amountRaw is num
        ? amountRaw.toDouble()
        : double.parse(amountRaw as String);
    return Budget.fromRow(
      sub: row[0]! as String,
      id: row[1]! as String,
      name: row[2]! as String,
      amount: amount,
      period: row[4]! as String,
      startDate: row[5]! as DateTime,
      endDate: row[6]! as DateTime,
      active: row[7]! as bool,
      source: row[8]! as String,
      alertEvery: row[9] as bool?,
      alertThresholds: row[10] as String?,
      createdAt: row[11]! as DateTime,
    );
  }
}
