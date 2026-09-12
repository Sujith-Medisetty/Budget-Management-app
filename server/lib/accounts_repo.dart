import 'dart:convert';
import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';

import 'token_store.dart';

/// Postgres-backed [TokenStore]. One row per Google account in
/// `accounts`. Replaces the legacy Firestore implementation across the
/// same public surface so handlers don't need to know the swap
/// happened.
///
/// Schema (see `tool/schema_postgres.sql`):
///   - `sub` is the primary key.
///   - `email` has a unique index on `lower(email)` for reverse
///     lookups (`findByEmail` / `subForEmail`).
///   - `refresh_token` is bytea — it's encrypted at the caller with
///     `TokenCipher` before put, decrypted after get.
///   - `fcm_tokens` is text[].
///   - `backup_prefs` is jsonb, in the same shape as
///     [BackupPrefs.toJson].
///   - `filter_rules` is text (JSON-encoded `FilterRuleSet`). Null
///     when the user has no rules configured.
class AccountsRepo implements TokenStore {
  AccountsRepo({required this.endpoint});

  /// Postgres endpoint. Pulled from config at boot; tests construct one
  /// pointing at an ephemeral container.
  final Endpoint endpoint;
  final _log = Logger('accounts-repo');

  Connection? _conn;

  /// Idempotent — held in a Future so concurrent callers share the
  /// same connect cycle. Same pattern the Firestore impl used.
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    // Long-running service — sane defaults that survive a brief PG
    // restart without dropping the first few requests after it comes
    // back. Disable TLS because Pocket's Postgres sits on the loopback
    // of an Oracle VM (no wire encryption needed between Dart and
    // the same kernel's TCP stack); switch to SslMode.requireTls
    // when the VM gains a separate DB host.
    final settings = ConnectionSettings(
      sslMode: SslMode.disable,
    );
    _conn = await Connection.open(endpoint, settings: settings);
    // Smoke check — surfaces "wrong password" / "no database" at
    // boot rather than on first request.
    final res = await _conn!.execute('SELECT 1 AS up');
    final row = res.first;
    if (row[0] != 1) {
      throw StateError('postgres smoke check failed: $row');
    }
    _log.info('accounts repo ready (db=${endpoint.database}, '
        'host=${endpoint.host})');
  }

  @override
  Future<void> put(String sub, AccountRecord record) async {
    final conn = await _ready();
    final now = DateTime.now().toUtc();
    await conn.execute(
      Sql.named('''
      INSERT INTO accounts (
        sub, refresh_token, email,
        last_watch_at, last_history_id,
        fcm_tokens, revoked, pocket_label_id,
        backup_prefs, budget_prefs, timezone, filter_rules,
        last_sync_at, last_backup_at,
        created_at, updated_at
      ) VALUES (
        @sub, @rt, @email,
        @lastWatchAt, @lastHistoryId,
        @fcmTokens::text[], @revoked, @pocketLabelId,
        @backupPrefs::jsonb, @budgetPrefs::jsonb, @timezone, @filterRules,
        @lastSyncAt, @lastBackupAt,
        COALESCE(@createdAt::timestamptz, @now::timestamptz), @now
      )
      ON CONFLICT (sub) DO UPDATE SET
        refresh_token = EXCLUDED.refresh_token,
        email = EXCLUDED.email,
        last_watch_at = EXCLUDED.last_watch_at,
        last_history_id = EXCLUDED.last_history_id,
        fcm_tokens = EXCLUDED.fcm_tokens,
        revoked = EXCLUDED.revoked,
        pocket_label_id = EXCLUDED.pocket_label_id,
        backup_prefs = EXCLUDED.backup_prefs,
        budget_prefs = EXCLUDED.budget_prefs,
        timezone = EXCLUDED.timezone,
        filter_rules = EXCLUDED.filter_rules,
        last_sync_at = EXCLUDED.last_sync_at,
        last_backup_at = EXCLUDED.last_backup_at,
        updated_at = EXCLUDED.updated_at
      '''),
      parameters: {
        'sub': sub,
        'rt': utf8.encode(record.refreshToken),
        'email': record.email,
        'lastWatchAt': record.lastWatchAt.toUtc(),
        'lastHistoryId': record.lastHistoryId,
        'fcmTokens': record.fcmTokens.toList(growable: false),
        'revoked': record.revoked,
        'pocketLabelId': record.pocketLabelId,
        'backupPrefs': record.backupPrefs.toJson(),
        'budgetPrefs': record.budgetPrefs.toJson(),
        'timezone': record.timezone,
        'filterRules': record.filterRules,
        'lastSyncAt': record.lastSyncAt?.toUtc(),
        'lastBackupAt': record.lastBackupAt?.toUtc(),
        'createdAt': record.createdAt?.toUtc(),
        'now': now,
      },
    );
  }

  @override
  Future<AccountRecord?> get(String sub) async {
    final conn = await _ready();
    final res = await conn.execute(
      Sql.named('SELECT sub, refresh_token, email, last_watch_at, last_history_id, '
          'fcm_tokens, revoked, pocket_label_id, backup_prefs, budget_prefs, '
          'timezone, filter_rules, last_sync_at, last_backup_at, created_at, '
          'updated_at FROM accounts WHERE sub=@sub'),
      parameters: {'sub': sub},
    );
    if (res.isEmpty) return null;
    return _rowToRecord(res.first);
  }

  @override
  Future<void> remove(String sub) async {
    final conn = await _ready();
    await conn.execute(
      Sql.named('DELETE FROM accounts WHERE sub=@sub'),
      parameters: {'sub': sub},
    );
  }

  /// Reverse lookup keyed on email. Pub/Sub payloads carry
  /// `emailAddress`, not `sub`, so this is hot path.
  @override
  Future<AccountRecord?> findByEmail(String email) async {
    final conn = await _ready();
    final res = await conn.execute(
      Sql.named('SELECT sub, refresh_token, email, last_watch_at, last_history_id, '
          'fcm_tokens, revoked, pocket_label_id, backup_prefs, budget_prefs, '
          'timezone, filter_rules, last_sync_at, last_backup_at, created_at, '
          'updated_at FROM accounts WHERE lower(email)=lower(@email) LIMIT 1'),
      parameters: {'email': email},
    );
    if (res.isEmpty) return null;
    return _rowToRecord(res.first);
  }

  @override
  Future<String?> subForEmail(String email) async {
    final record = await findByEmail(email);
    return record?.sub;
  }

  @override
  Future<List<AccountRecord>> all() async {
    final conn = await _ready();
    final res = await conn.execute(
      'SELECT sub, refresh_token, email, last_watch_at, last_history_id, '
      'fcm_tokens, revoked, pocket_label_id, backup_prefs, budget_prefs, '
      'timezone, filter_rules, last_sync_at, last_backup_at, created_at, '
      'updated_at FROM accounts ORDER BY created_at ASC LIMIT 200',
    );
    return res.map((r) => _rowToRecord(r)).toList(growable: false);
  }

  Future<Connection> _ready() async {
    await init();
    return _conn!;
  }

  AccountRecord _rowToRecord(ResultRow row) {
    final sub = row[0]! as String;
    final refreshToken = utf8.decode(row[1]! as List<int>);
    final email = row[2]! as String;
    final lastWatchAt = row[3]! as DateTime;
    final lastHistoryId = row[4] as String?;
    final fcmTokens = (row[5]! as List).map((e) => e as String).toSet();
    final revoked = row[6]! as bool;
    final pocketLabelId = row[7] as String?;
    final backupPrefsRaw = row[8]! as Map<String, dynamic>;
    final budgetPrefsRaw = row[9]! as Map<String, dynamic>;
    final timezone = row[10] as String?;
    final filterRules = row[11] as String?;
    final lastSyncAt = row[12] as DateTime?;
    final lastBackupAt = row[13] as DateTime?;
    final createdAt = row[14]! as DateTime;
    final updatedAt = row[15]! as DateTime;
    return AccountRecord(
      sub: sub,
      refreshToken: refreshToken,
      email: email,
      lastWatchAt: lastWatchAt,
      lastHistoryId: lastHistoryId,
      fcmTokens: fcmTokens,
      revoked: revoked,
      pocketLabelId: pocketLabelId,
      backupPrefs: BackupPrefs.fromJson(backupPrefsRaw),
      budgetPrefs: BudgetPrefs.fromJson(budgetPrefsRaw),
      timezone: timezone,
      filterRules: filterRules,
      lastSyncAt: lastSyncAt,
      lastBackupAt: lastBackupAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  /// Lets sibling stores (`EnvelopeStore`) piggy-back on the same
  /// connection pool instead of opening their own.
  Future<Connection> ready() async {
    await init();
    return _conn!;
  }

  /// Closes the connection. Called by the server shutdown handler.
  Future<void> close() async {
    final conn = _conn;
    if (conn != null) {
      await conn.close();
      _conn = null;
      _initFuture = null;
    }
  }
}

/// Builds an [Endpoint] from the same env vars the legacy `.env`
/// expected (`PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASSWORD`).
/// Centralised here so tests can construct a similar one and prod
/// stays in lock-step with the deploy script's `.env` writer.
///
/// Sources, in precedence order (highest first):
///   1. [env] — a per-key override map. Use for tests that want to
///      stub one or two keys without rebuilding a full [DotEnv].
///      Keys absent from [env] fall through to the lower layers,
///      so a partial `{'PG_HOST': 'localhost'}` still picks up
///      PG_USER / PG_DB / etc. from the next layer.
///   2. [dotenv] — the merged `.env` + platform env map the server
///      already constructs at boot. Preferred over `Platform.environment`
///      because [DotEnv] with `includePlatformEnvironment: true`
///      transparently carries both, so prod and local converge on the
///      same code path.
///   3. `Platform.environment` — fallback when neither is provided
///      (e.g. CLI tools that want to inherit the parent shell).
///
/// Throws when a required key is missing at every layer.
Endpoint pgEndpointFromEnv({Map<String, String>? env, DotEnv? dotenv}) {
  String lookup(String key) {
    if (env != null && env.containsKey(key)) {
      return env[key]!;
    }
    if (dotenv != null) {
      final v = dotenv[key];
      if (v != null && v.isNotEmpty) return v;
    }
    final v = Platform.environment[key];
    if (v == null || v.isEmpty) {
      throw StateError('Missing required Postgres env var: $key');
    }
    return v;
  }
  return Endpoint(
    host: lookup('PG_HOST'),
    port: int.parse(lookup('PG_PORT')),
    database: lookup('PG_DB'),
    username: lookup('PG_USER'),
    password: lookup('PG_PASSWORD'),
  );
}
