import 'dart:io';

import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'accounts_repo.dart';
import 'token_store.dart';

/// Per-user auto-backup scheduler. Reads the user's
/// `accounts.backup_prefs` + `accounts.timezone`, converts their local
/// HH:MM to UTC, and writes (or deletes) a systemd timer unit
/// `pocket-backup-{sub}.timer` that fires `pocket-backup-{sub}.service`
/// at the chosen cadence.
///
/// The `pocket_schedules` Postgres row is the **readable** source of
/// truth (`SELECT * FROM pocket_schedules WHERE sub=X` answers "what's
/// scheduled for this user?"). The systemd unit is the **executor**
/// — they're kept in lock-step by [sync]. Drift between the two is a
/// bug; every state transition logs `synced (db|systemd)` lines so
/// `journalctl -u pocket-server | grep scheduler` makes drift visible.
///
/// State transitions:
///   - enabled=true (new)            → write units, daemon-reload,
///                                     enable timer, INSERT schedule row
///   - enabled=true (prefs changed)  → rewrite units, daemon-reload,
///                                     restart timer, UPDATE schedule row
///   - enabled=false                 → disable timer, delete unit
///                                     files, UPDATE row (unit_name=NULL)
///   - account deleted               → CASCADE drops schedule row;
///                                     caller is responsible for tearing
///                                     down the unit (see
///                                     `accountDeleteHandler`).
class BackupScheduler {
  BackupScheduler({required this.accounts});

  final AccountsRepo accounts;
  final _log = Logger('scheduler');

  static const _systemdDir = '/etc/systemd/system';

  /// Public so callers (and tests) can read the convention.
  static String unitNameForSub(String sub) => 'pocket-backup-$sub';

  /// Idempotent — call after every PATCH /accounts/<sub> that touched
  /// `backupPrefs` or `timezone`. Computes the desired state from the
  /// persisted row and reconciles both the DB schedule row and the
  /// systemd unit(s) in one shot.
  ///
  /// [prefs] — the user's just-persisted [BackupPrefs].
  /// [timezone] — IANA name (e.g. `America/Chicago`). Required when
  /// enabled=true; ignored when enabled=false. Null + enabled=true
  /// falls back to UTC (rare; only if the mobile client hasn't sent
  /// one yet — the mobile captures it at sign-in and sends on every
  /// save, so missing means the client is genuinely stale).
  Future<void> sync({
    required String sub,
    required BackupPrefs prefs,
    required String? timezone,
  }) async {
    tzdata.initializeTimeZones();
    final tzName = (timezone != null && timezone.isNotEmpty)
        ? timezone
        : 'UTC';
    final loc = _safeLocation(tzName);

    final unitName = unitNameForSub(sub);
    final serviceName = '$unitName.service';
    final timerName = '$unitName.timer';

    if (!prefs.enabled) {
      await _disable(sub: sub, timerName: timerName, serviceName: serviceName);
      await _updateScheduleRow(
        sub: sub,
        enabled: false,
        frequency: prefs.frequency,
        hour: prefs.hour,
        minute: prefs.minute,
        nextFireUtc: null,
        unitName: null,
      );
      _log.info('synced sub=$sub disabled (db + systemd)');
      return;
    }

    // Compute the user's local fire time, then convert to UTC for the
    // OnCalendar= line. We pick the *next* occurrence (today if HH:MM
    // hasn't passed in their timezone yet, otherwise tomorrow) and
    // emit the matching cron spec for the systemd unit.
    final utcFire = _nextFireUtc(
      location: loc,
      hour: prefs.hour,
      minute: prefs.minute,
      frequency: prefs.frequency,
    );
    final onCalendar = _onCalendarFor(
      utcFire: utcFire,
      frequency: prefs.frequency,
    );

    await _writeUnits(
      sub: sub,
      timerName: timerName,
      serviceName: serviceName,
      onCalendar: onCalendar,
    );
    await _systemctl(['daemon-reload']);
    await _systemctl(['enable', '--now', timerName]);

    await _updateScheduleRow(
      sub: sub,
      enabled: true,
      frequency: prefs.frequency,
      hour: prefs.hour,
      minute: prefs.minute,
      nextFireUtc: utcFire,
      unitName: unitName,
    );
    _log.info('synced sub=$sub enabled '
        '(local=${prefs.hour.toString().padLeft(2, '0')}:'
        '${prefs.minute.toString().padLeft(2, '0')} '
        '$tzName → utc=${utcFire.toIso8601String()}, '
        'unit=$timerName)');
  }

  /// Tear-down helper for `accountDeleteHandler`. Drops both the DB
  /// row (CASCADE does this when the account row goes) and the systemd
  /// unit. Idempotent — safe to call on an already-disabled user.
  Future<void> disableForDeletedSub(String sub) async {
    final unitName = unitNameForSub(sub);
    await _disable(
      sub: sub,
      timerName: '$unitName.timer',
      serviceName: '$unitName.service',
    );
  }

  // ── private ───────────────────────────────────────────────────────

  Future<void> _disable({
    required String sub,
    required String timerName,
    required String serviceName,
  }) async {
    // `disable --now` returns non-zero if the unit doesn't exist — we
    // don't care: a missing unit is the desired post-state.
    await _systemctl(['disable', '--now', timerName], allowFail: true);
    await _deleteIfExists('$_systemdDir/$timerName');
    await _deleteIfExists('$_systemdDir/$serviceName');
    await _systemctl(['daemon-reload']);
  }

  Future<void> _writeUnits({
    required String sub,
    required String timerName,
    required String serviceName,
    required String onCalendar,
  }) async {
    final timerBody = '''
[Unit]
Description=Pocket auto-backup timer for $sub

[Timer]
# Generated by backup_scheduler.sync. Do not edit by hand.
OnCalendar=$onCalendar
# If the VM was off at the scheduled fire, run once on next boot.
Persistent=true
# Tiny jitter so back-to-back units don't all hit the dispatcher at
# the same wall-clock second.
RandomizedDelaySec=30s
Unit=${serviceName.replaceFirst('.service', '')}

[Install]
WantedBy=timers.target
''';
    final serviceBody = '''
[Unit]
Description=Pocket auto-backup publisher for $sub

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dart --disable-analytics run /opt/pocket/server/tool/trigger_backup.dart --sub $sub
WorkingDirectory=/opt/pocket/server
EnvironmentFile=/opt/pocket/server/.env
StandardOutput=journal
StandardError=journal
TimeoutStartSec=60s
''';
    await File('$_systemdDir/$timerName').writeAsString(timerBody);
    await File('$_systemdDir/$serviceName').writeAsString(serviceBody);
  }

  Future<void> _updateScheduleRow({
    required String sub,
    required bool enabled,
    required String frequency,
    required int hour,
    required int minute,
    required DateTime? nextFireUtc,
    required String? unitName,
  }) async {
    final conn = await accounts.ready();
    await conn.execute(
      Sql.named('''
      INSERT INTO pocket_schedules (
        sub, enabled, frequency, hour, minute, next_fire_at_utc, unit_name,
        created_at, updated_at
      ) VALUES (
        @sub, @enabled, @frequency, @hour, @minute,
        @nextFire::timestamptz, @unitName,
        NOW(), NOW()
      )
      ON CONFLICT (sub) DO UPDATE SET
        enabled          = EXCLUDED.enabled,
        frequency        = EXCLUDED.frequency,
        hour             = EXCLUDED.hour,
        minute           = EXCLUDED.minute,
        next_fire_at_utc = EXCLUDED.next_fire_at_utc,
        unit_name        = EXCLUDED.unit_name,
        updated_at       = NOW()
      '''),
      parameters: {
        'sub': sub,
        'enabled': enabled,
        'frequency': frequency,
        'hour': hour,
        'minute': minute,
        'nextFire': nextFireUtc,
        'unitName': unitName,
      },
    );
  }

  // ── cron translation ──────────────────────────────────────────────

  /// Returns the *next* UTC instant matching the user's local HH:MM
  /// on the chosen cadence. Used for both the [next_fire_at_utc] DB
  /// column (informational) and for computing the [OnCalendar] line
  /// below.
  DateTime _nextFireUtc({
    required tz.Location location,
    required int hour,
    required int minute,
    required String frequency,
  }) {
    final nowLocal = tz.TZDateTime.now(location);
    var candidate = tz.TZDateTime(
      location,
      nowLocal.year,
      nowLocal.month,
      nowLocal.day,
      hour,
      minute,
    );
    if (!candidate.isAfter(nowLocal)) {
      // Already passed today — roll forward to tomorrow.
      candidate = candidate.add(const Duration(days: 1));
    }
    if (frequency == 'weekly') {
      // Roll forward to the next Sunday (or today if today is Sunday).
      while (candidate.weekday != DateTime.sunday) {
        candidate = candidate.add(const Duration(days: 1));
      }
    } else if (frequency == 'monthly') {
      // Roll forward to the next 1st-of-month (or today if today is the 1st).
      while (candidate.day != 1) {
        candidate = candidate.add(const Duration(days: 1));
      }
    }
    return candidate.toUtc();
  }

  /// systemd OnCalendar line that fires daily/weekly/monthly at the
  /// given UTC instant. We use the UTC clock fields because systemd
  /// interprets OnCalendar in the unit's timezone (and the VM is UTC
  /// — converting to UTC and writing UTC keeps the math obvious).
  String _onCalendarFor({
    required DateTime utcFire,
    required String frequency,
  }) {
    final hh = utcFire.hour.toString().padLeft(2, '0');
    final mm = utcFire.minute.toString().padLeft(2, '0');
    switch (frequency) {
      case 'daily':
        return '*-*-* $hh:$mm:00';
      case 'weekly':
        // Sunday = day-of-week 7 in systemd's notation. We converted
        // already, so emit the literal.
        return 'Sun *-*-* $hh:$mm:00';
      case 'monthly':
        return '*-*-01 $hh:$mm:00';
      default:
        // Defensive: schema CHECK rejects unknowns, but a future enum
        // addition shouldn't crash the scheduler.
        _log.warning('unknown frequency=$frequency — falling back to daily');
        return '*-*-* $hh:$mm:00';
    }
  }

  tz.Location _safeLocation(String name) {
    try {
      return tz.getLocation(name);
    } catch (_) {
      _log.warning('unknown timezone "$name" — falling back to UTC');
      return tz.getLocation('UTC');
    }
  }

  Future<void> _systemctl(
    List<String> args, {
    bool allowFail = false,
  }) async {
    try {
      final res = await Process.run('systemctl', args);
      if (res.exitCode != 0 && !allowFail) {
        _log.warning('systemctl ${args.join(' ')} exited ${res.exitCode}: '
            '${res.stderr}');
      }
    } on ProcessException catch (e) {
      // Don't fail the PATCH because systemctl couldn't run — log and
      // move on. The DB row is the source of truth; the unit can be
      // reconciled out of band.
      _log.warning('systemctl ${args.join(' ')} failed: $e');
    }
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      // Already gone — fine.
    }
  }
}
