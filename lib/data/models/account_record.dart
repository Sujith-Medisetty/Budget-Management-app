/// Per-user data: backup preferences, filter rules, last sync/backup
/// timestamps. Wire shape for `GET /accounts/<sub>` and
/// `PATCH /accounts/<sub>`. Source of truth is the Firestore
/// `accounts/{sub}` doc — this is just the Dart view of it.
///
/// Per-user config was previously mirrored into a local SQLite
/// `accounts` table so the Backup / Email-filters screens could
/// render without a cloud round trip. That mirror was dropped: every
/// read goes through Cloud Run → Firestore, every write goes through
/// Cloud Run → Firestore. Local SQLite now holds only user data
/// (transactions, budgets, AI log) and per-device flags (theme, AI
/// model choice) live in SharedPreferences.
class AccountRecord {
  const AccountRecord({
    required this.sub,
    required this.email,
    required this.backupEnabled,
    required this.backupHour,
    required this.backupMinute,
    required this.backupFrequency,
    required this.backupNotifyComplete,
    required this.backupNotifyFailed,
    required this.backupNotifyRestoreComplete,
    required this.budgetAutoMonthlyBudget,
    required this.timezone,
    required this.filterRulesJson,
    required this.lastSyncAt,
    required this.lastBackupAt,
    required this.createdAt,
    required this.updatedAt,
  });

  final String sub;
  final String email;
  final bool backupEnabled;
  final int backupHour;
  final int backupMinute;

  /// IANA timezone name captured on the device (e.g.
  /// `America/Chicago`) and sent on every BackupPrefs save. Server
  /// uses this to convert the user's local HH:MM to UTC for the
  /// per-user systemd timer's OnCalendar line. Null on legacy
  /// accounts predating the migration — server falls back to UTC.
  final String? timezone;

  /// Cadence name — "daily" / "weekly" / "monthly". Only `daily` is
  /// fully wired server-side today; weekly/monthly fall back to the
  /// daily cron until the per-user job learns day-of-week / day-of-
  /// month matching. Stored as a plain String so adding a new cadence
  /// doesn't force a schema migration.
  final String backupFrequency;

  final bool backupNotifyComplete;
  final bool backupNotifyFailed;
  final bool backupNotifyRestoreComplete;

  /// Whether the server should auto-create a "Month Expenses" budget
  /// for this user on the 1st of every month (and on sign-in if the
  /// current month's row is missing). Default true per the server's
  /// `BudgetPrefs.fromJson` shape and the JSONB column default in
  /// `schema_postgres.sql` — keeps the contract symmetric on both
  /// sides (legacy accounts that pre-date this field default to
  /// "auto ON" so they immediately get the cron path).
  final bool budgetAutoMonthlyBudget;

  final String? filterRulesJson;
  final DateTime? lastSyncAt;
  final DateTime? lastBackupAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory AccountRecord.fromServerJson(Map<String, dynamic> j) {
    final prefs = (j['backupPrefs'] as Map?)?.cast<String, dynamic>() ?? const {};
    final budgetPrefs =
        (j['budgetPrefs'] as Map?)?.cast<String, dynamic>() ?? const {};
    int? asInt(Object? v) => v is num ? v.toInt() : null;
    bool? asBool(Object? v) => v is bool ? v : null;
    DateTime? asDate(Object? v) =>
        v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true) : null;
    return AccountRecord(
      sub: j['sub'] as String,
      email: j['email'] as String,
      backupEnabled: asBool(prefs['enabled']) ?? false,
      backupHour: asInt(prefs['hour']) ?? 22,
      backupMinute: asInt(prefs['minute']) ?? 0,
      // Unknown cadence values default to "daily" so a future server
      // enum can't crash pre-upgrade clients.
      backupFrequency: prefs['frequency'] as String? ?? 'daily',
      // Notification banners default OFF. The user opts in via the
      // Backup screen; defaulting them on spammed fresh installs with
      // success/failure pings they didn't ask for.
      backupNotifyComplete: asBool(prefs['notifyComplete']) ?? false,
      backupNotifyFailed: asBool(prefs['notifyFailed']) ?? false,
      backupNotifyRestoreComplete:
          asBool(prefs['notifyRestoreComplete']) ?? false,
      // Auto-monthly-budget toggle — defaults OFF to match the
      // server-side BudgetPrefs.fromJson default and the JSONB
      // column default. Auto-create is opt-in: a fresh sign-up
      // gets OFF, and the user explicitly flips the toggle from
      // the Settings screen to enable it. The server's PATCH
      // handler runs `ensureCurrentMonthBudget` as a side-effect
      // on the false→true transition so the user gets a current-
      // month budget in the same save.
      budgetAutoMonthlyBudget:
          asBool(budgetPrefs['autoMonthlyBudget']) ?? false,
      // IANA name captured at the device on every save. Missing
      // means legacy account (server defaults to UTC for those).
      timezone: j['timezone'] as String?,
      filterRulesJson: j['filterRules'] as String?,
      lastSyncAt: asDate(j['lastSyncAt']),
      lastBackupAt: asDate(j['lastBackupAt']),
      createdAt: asDate(j['createdAt']) ?? DateTime.now().toUtc(),
      updatedAt: asDate(j['updatedAt']) ?? DateTime.now().toUtc(),
    );
  }
}