/// Refresh-token storage keyed by Google account `sub`.
///
/// Interface lets us swap in a Firestore implementation later without
/// touching handlers.
abstract class TokenStore {
  Future<void> put(String sub, AccountRecord record);
  Future<AccountRecord?> get(String sub);
  Future<void> remove(String sub);

  /// Look up the account by Gmail address. Used by the Pub/Sub
  /// handler because Google publishes to our topic with `emailAddress`
  /// in the payload, not `sub`. Returns null if no match.
  Future<AccountRecord?> findByEmail(String email) async {
    // Default: scan. Implementations can override with a real query.
    return null;
  }

  /// Returns the `sub` for a known account, or null. Inverse of
  /// [findByEmail] for places that need the key.
  Future<String?> subForEmail(String email) async => null;

  /// Lists every account. Used by the watch-recovery admin tool to
  /// re-run users.watch() for accounts that missed it during the
  /// OAuth exchange (e.g. Pub/Sub topic IAM was wrong at sign-in).
  Future<List<AccountRecord>> all() async => const [];
}

/// Per-user backup schedule + notification flags. Mirrors what the
/// client shows in the Backup settings screen and what drives the
/// per-user Cloud Scheduler job.
class BackupPrefs {
  const BackupPrefs({
    this.enabled = false,
    this.hour = 22,
    this.minute = 0,
    this.frequency = 'daily',
    this.notifyComplete = false,
    this.notifyFailed = false,
    this.notifyRestoreComplete = false,
  });

  /// Whether the user has auto-backup turned on. Drives whether the
  /// per-user Cloud Scheduler job exists.
  final bool enabled;

  /// Local hour (0..23) the user picked in the Backup screen. Cloud
  /// Scheduler interprets the cron in the user's IANA timezone, so
  /// this is wall-clock local time, not UTC.
  final int hour;

  /// Local minute (0..59).
  final int minute;

  /// Backup cadence as a string ("daily" / "weekly" / "monthly").
  /// Only `daily` is wired end-to-end today; weekly/monthly surface
  /// in the UI but the cron still fires daily until the per-user job
  /// learns day-of-week / day-of-month matching. Stored as a string
  /// so the enum can grow without a schema migration.
  final String frequency;

  /// Whether to surface a local "Backup complete" notification on the
  /// device. Client-side gate (server FCM is always sent when the
  /// job fires; the device decides whether to show).
  final bool notifyComplete;

  /// Same for failures.
  final bool notifyFailed;

  /// Whether to surface a local "Restore complete" notification after
  /// "Restore from cloud" finishes loading a snapshot.
  final bool notifyRestoreComplete;

  BackupPrefs copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    String? frequency,
    bool? notifyComplete,
    bool? notifyFailed,
    bool? notifyRestoreComplete,
  }) {
    return BackupPrefs(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      frequency: frequency ?? this.frequency,
      notifyComplete: notifyComplete ?? this.notifyComplete,
      notifyFailed: notifyFailed ?? this.notifyFailed,
      notifyRestoreComplete:
          notifyRestoreComplete ?? this.notifyRestoreComplete,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'hour': hour,
        'minute': minute,
        'frequency': frequency,
        'notifyComplete': notifyComplete,
        'notifyFailed': notifyFailed,
        'notifyRestoreComplete': notifyRestoreComplete,
      };

  factory BackupPrefs.fromJson(Map<String, dynamic> j) => BackupPrefs(
        enabled: j['enabled'] as bool? ?? false,
        hour: (j['hour'] as num?)?.toInt() ?? 22,
        minute: (j['minute'] as num?)?.toInt() ?? 0,
        // 'daily' is the only cadence wired today — fall back on
        // anything we don't recognise so a future enum value being
        // added server-side doesn't crash pre-upgrade clients.
        frequency: j['frequency'] as String? ?? 'daily',
        notifyComplete: j['notifyComplete'] as bool? ?? false,
        notifyFailed: j['notifyFailed'] as bool? ?? false,
        notifyRestoreComplete:
            j['notifyRestoreComplete'] as bool? ?? false,
      );
}

class AccountRecord {
  const AccountRecord({
    required this.sub,
    required this.refreshToken,
    required this.email,
    required this.lastWatchAt,
    required this.lastHistoryId,
    this.fcmTokens = const {},
    this.revoked = false,
    this.pocketLabelId,
    this.backupPrefs = const BackupPrefs(),
    this.budgetPrefs = const BudgetPrefs(),
    this.timezone,
    this.filterRules,
    this.lastSyncAt,
    this.lastBackupAt,
    this.createdAt,
    this.updatedAt,
  });

  /// Google's immutable user ID. Used as the Firestore doc id and as
  /// the FCM topic suffix (`gmail-sync-{sub}`).
  final String sub;
  final String refreshToken;
  final String email;
  final DateTime lastWatchAt;
  final String? lastHistoryId;
  final Set<String> fcmTokens;
  final bool revoked;

  /// Gmail label id for the "Pocket/Keep" label we own. Created on
  /// first sign-in via `users.labels.create`, persisted here so
  /// `users.watch` and filter actions can reference it. When non-null,
  /// Gmail-side filters add this label to matching emails, and our
  /// watch listens only for changes to this label — Pub/Sub never
  /// fires for non-matching mail. Null for legacy accounts that
  /// haven't re-signed-in since the label scheme was introduced;
  /// `pubsub_handler` self-heals them on the next push.
  final String? pocketLabelId;

  /// User's backup schedule + notify flags. Source of truth for the
  /// per-user Cloud Scheduler job `pocket-backup-{sub}`. Defaults to
  /// "disabled, 10 PM, notify on" — see [BackupPrefs].
  final BackupPrefs backupPrefs;

  /// Auto-monthly-budget prefs. The phone writes here when the user
  /// toggles the "create a new budget on the 1st of every month"
  /// setting; the server's 1st-of-month cron and the sign-in
  /// `ensureCurrentMonthBudget` helper both read this to decide
  /// whether to mint a row in the server-side `budgets` table.
  /// Defaults to ON (matches the JSONB default in
  /// `schema_postgres.sql`) so first-time sign-ups immediately get
  /// the auto-create flow without a migration PATCH.
  final BudgetPrefs budgetPrefs;

  /// IANA timezone name (e.g. `America/Chicago`) captured on the
  /// device and sent on every BackupPrefs save. Drives the
  /// local-HH:MM → UTC conversion that the per-user systemd timer
  /// needs. Null for legacy accounts; the scheduler falls back to
  /// UTC in that case.
  final String? timezone;

  /// JSON-encoded [FilterRuleSet] (or null = no rules). Lives here
  /// (not in a separate `filter_rules/{sub}` doc) so a single GET
  /// on the account hydrates every per-user setting in one round
  /// trip. The legacy `filter_rules/{sub}` collection is read once
  /// on first access and copied into this field, then dropped.
  final String? filterRules;

  /// Timestamp the device last ran a successful Gmail sync. Read by
  /// `/sync?since=` to compute the high-water mark without
  /// round-tripping the device's local clock.
  final DateTime? lastSyncAt;

  /// Timestamp the device last completed a backup upload. Read by
  /// the Backup settings screen to show "Last backup: 2h ago".
  final DateTime? lastBackupAt;

  /// Set on first OAuth exchange. Null for legacy accounts that
  /// existed before the consolidated schema — the next write fills
  /// it in.
  final DateTime? createdAt;

  /// Updated on every PATCH. Null for legacy accounts.
  final DateTime? updatedAt;

  AccountRecord copyWith({
    String? refreshToken,
    String? email,
    DateTime? lastWatchAt,
    String? lastHistoryId,
    Set<String>? fcmTokens,
    bool? revoked,
    String? pocketLabelId,
    BackupPrefs? backupPrefs,
    BudgetPrefs? budgetPrefs,
    String? timezone,
    String? filterRules,
    DateTime? lastSyncAt,
    DateTime? lastBackupAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return AccountRecord(
      sub: sub,
      refreshToken: refreshToken ?? this.refreshToken,
      email: email ?? this.email,
      lastWatchAt: lastWatchAt ?? this.lastWatchAt,
      lastHistoryId: lastHistoryId ?? this.lastHistoryId,
      fcmTokens: fcmTokens ?? this.fcmTokens,
      revoked: revoked ?? this.revoked,
      pocketLabelId: pocketLabelId ?? this.pocketLabelId,
      backupPrefs: backupPrefs ?? this.backupPrefs,
      budgetPrefs: budgetPrefs ?? this.budgetPrefs,
      timezone: timezone ?? this.timezone,
      // `filterRules` is nullable AND clearable; `clearFilterRules`
      // resets to null. copyWith's named-arg defaults can't tell
      // "not passed" from "passed as null", so callers that want to
      // clear it must use [copyWithFilterRules] below.
      filterRules: filterRules ?? this.filterRules,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastBackupAt: lastBackupAt ?? this.lastBackupAt,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Variant of [copyWith] that lets callers explicitly clear the
  /// filterRules field (since `null` is ambiguous with "not passed").
  AccountRecord copyWithFilterRules({String? filterRules, bool clear = false}) {
    return copyWith(filterRules: clear ? null : filterRules);
  }
}

/// Auto-monthly-budget prefs. When [autoMonthlyBudget] is true the
/// server mints a new row in the `budgets` table on the 1st of every
/// month (named like `"October Expenses"`, copying the amount from
/// the previous month's auto-created budget), and the sign-in path
/// also runs `ensureCurrentMonthBudget` so a brand-new account that
/// lands mid-month still gets an `"October Expenses"` row
/// immediately. Defaults to OFF — auto-create is opt-in, and the
/// PATCH handler runs `ensureCurrentMonthBudget` as a side-effect
/// when the toggle flips ON for a user who hasn't already got a row
/// for the current month. Toggling OFF is intentionally non-
/// destructive: pre-existing budgets (server-side mirrors or device-
/// side rows) are never deleted or modified.
class BudgetPrefs {
  const BudgetPrefs({this.autoMonthlyBudget = false});

  /// Whether to auto-create a new monthly budget on the 1st of every
  /// month (server-side cron) and on sign-in / PATCH-flip if the
  /// current month's row is missing. The phone is still the editor —
  /// toggling this OFF doesn't delete already-created budgets, just
  /// stops new ones from being minted server-side.
  final bool autoMonthlyBudget;

  BudgetPrefs copyWith({bool? autoMonthlyBudget}) {
    return BudgetPrefs(
      autoMonthlyBudget: autoMonthlyBudget ?? this.autoMonthlyBudget,
    );
  }

  Map<String, dynamic> toJson() => {
        'autoMonthlyBudget': autoMonthlyBudget,
      };

  factory BudgetPrefs.fromJson(Map<String, dynamic> j) => BudgetPrefs(
        autoMonthlyBudget: j['autoMonthlyBudget'] as bool? ?? false,
      );
}

/// Server-side record for a monthly budget row. Mirrors the phone's
/// local SQLite `budgets` table — the phone remains the editor /
/// source of truth for user-visible state. Server rows exist so:
///   1. A user who doesn't sign in during the first day of a new
///      month still gets next month's budget created (cron path).
///   2. Future restore-from-server flows have a place to pull
///      historical budgets from.
///
/// `id` is a UUID-ish string the server mints; we don't reuse the
/// phone-side int autoincrement because the server has no way to
/// predict the next local id on the device.
class Budget {
  const Budget({
    required this.sub,
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

  /// Owning Google `sub`.
  final String sub;

  /// Server-minted UUID-ish id. Stable across sync back to the phone
  /// so the device-side row can match it on insert.
  final String id;

  /// Display name. Auto-created rows use the pattern
  /// `MonthName Expenses` (e.g. `"October Expenses"`).
  final String name;

  /// Cap value. Auto-created rows copy the amount from the previous
  /// month's auto-created budget; manual rows keep whatever the user
  /// chose on the device.
  final double amount;

  /// One of: daily / weekly / monthly / yearly / custom.
  /// Auto-created rows are always 'monthly'.
  final String period;

  /// Inclusive first day of the budget window.
  final DateTime startDate;

  /// Exclusive (or inclusive-last, matching the phone's convention)
  /// last day of the budget window. Same convention as the device
  /// SQLite so a round-trip doesn't lose days.
  final DateTime endDate;

  /// Whether this is the user's currently-active budget. Invariant:
  /// at most one budget per sub can be active at a time — guaranteed
  /// by `BudgetsRepo.activate` (transactionally clears other rows).
  final bool active;

  /// `'auto'` for cron / sign-in / rollover creations, `'manual'`
  /// for user-created (rare; the phone normally creates manual
  /// budgets without telling the server, but a future "share budget"
  /// feature could route through here).
  final String source;

  /// Per-budget alert toggle from the device-side AlertConfig.
  /// Stored so a future restore-from-server path doesn't lose it.
  final bool? alertEvery;

  /// Comma-separated alert thresholds (e.g. "25,50,75,100") for the
  /// multi-threshold variant of [BudgetPrefs.alertEvery]. Null when
  /// [alertEvery] is null or the user picked the simple-every-change
  /// toggle.
  final String? alertThresholds;

  /// Server-side creation timestamp (UTC).
  final DateTime createdAt;

  Budget copyWith({
    String? name,
    double? amount,
    String? period,
    DateTime? startDate,
    DateTime? endDate,
    bool? active,
    String? source,
    bool? alertEvery,
    String? alertThresholds,
  }) {
    return Budget(
      sub: sub,
      id: id,
      name: name ?? this.name,
      amount: amount ?? this.amount,
      period: period ?? this.period,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      active: active ?? this.active,
      source: source ?? this.source,
      alertEvery: alertEvery ?? this.alertEvery,
      alertThresholds: alertThresholds ?? this.alertThresholds,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'amount': amount,
        'period': period,
        'startDate': startDate.toIso8601String().substring(0, 10),
        'endDate': endDate.toIso8601String().substring(0, 10),
        'active': active,
        'source': source,
        if (alertEvery != null) 'alertEvery': alertEvery,
        if (alertThresholds != null) 'alertThresholds': alertThresholds,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory Budget.fromRow({
    required String sub,
    required String id,
    required String name,
    required double amount,
    required String period,
    required DateTime startDate,
    required DateTime endDate,
    required bool active,
    required String source,
    required DateTime createdAt,
    bool? alertEvery,
    String? alertThresholds,
  }) =>
      Budget(
        sub: sub,
        id: id,
        name: name,
        amount: amount,
        period: period,
        startDate: startDate,
        endDate: endDate,
        active: active,
        source: source,
        createdAt: createdAt,
        alertEvery: alertEvery,
        alertThresholds: alertThresholds,
      );
}

class InMemoryTokenStore implements TokenStore {
  final Map<String, AccountRecord> _records = {};

  @override
  Future<void> put(String sub, AccountRecord record) async {
    _records[sub] = record;
  }

  @override
  Future<AccountRecord?> get(String sub) async => _records[sub];

  @override
  Future<void> remove(String sub) async {
    _records.remove(sub);
  }

  @override
  Future<AccountRecord?> findByEmail(String email) async {
    for (final r in _records.values) {
      if (r.email == email) return r;
    }
    return null;
  }

  @override
  Future<String?> subForEmail(String email) async {
    for (final entry in _records.entries) {
      if (entry.value.email == email) return entry.key;
    }
    return null;
  }

  @override
  Future<List<AccountRecord>> all() async => _records.values.toList();
}
