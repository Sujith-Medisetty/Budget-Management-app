import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/account_record.dart';
import '../data/services/accounts_repo.dart';
import '../data/services/gmail_auth.dart';
import '../data/services/timezone_service.dart';
import 'providers.dart';

/// User preferences + last-result state for cloud backup.
///
/// Storage: every field except `lastResult` and `lastSavedAt` (both
/// in-memory only) lives in the Postgres `accounts.backupPrefs`
/// column. The Backup screen reads via `GET /accounts/<sub>` on open
/// and writes via `PATCH /accounts/<sub>` on Save — there is no local
/// SQLite mirror, no Cloud Run round-trip, no risk of drift between
/// device and cloud. The previous architecture kept a local SQLite
/// `accounts` table for fast offline reads; that mirror was dropped
/// after debugging a series of race conditions where the local copy
/// lagged the cloud and re-created scheduler jobs the user had just
/// turned off.
///
/// Edit semantics: **explicit-save**. Setters (`setEnabled`,
/// `setTime`, `setFrequency`, `setNotifyOn*`) update the in-memory
/// `state` and flip a `_dirty` flag, but do NOT touch the cloud. The
/// Save button calls [BackupPreferencesController.save] which flushes
/// the staged state to the VM (single `PATCH`). One round-trip per
/// user-intent instead of one Cloud Run pair per toggle.
///
/// Cancelling out (tapping Back without Save) discards every staged
/// change — the next screen open re-reads from the cloud and the UI
/// shows the saved state, not the in-progress edits. This is the same
/// pattern as every native Settings screen: edit-in-memory, Save
/// commits, Back discards.
class BackupPreferences {
  const BackupPreferences({
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.frequency,
    required this.lastUploadAt,
    required this.lastResult,
    required this.notifyOnBackupComplete,
    required this.notifyOnBackupFailed,
    required this.notifyOnRestoreComplete,
    this.timezone,
    this.lastSavedAt,
    this.loaded = false,
    this.loadError,
  });

  final bool enabled;
  final int hour;
  final int minute;
  final BackupFrequency frequency;
  final DateTime? lastUploadAt;
  final BackupAttempt? lastResult;
  final bool notifyOnBackupComplete;
  final bool notifyOnBackupFailed;
  final bool notifyOnRestoreComplete;

  /// IANA timezone name (e.g. `America/Chicago`) the user was in
  /// when they last saved. Captured on the device at save-time and
  /// pushed to the server so the per-user systemd timer's UTC
  /// OnCalendar line is computed against the correct local clock.
  /// Drives the "Next backup" preview row on the Backup screen.
  final String? timezone;

  final DateTime? lastSavedAt;

  /// True after the first `GET /accounts/<sub>` completed (success or
  /// failure). UI uses this to show a loading state on cold start —
  /// before this flips, the rest of the fields are just `defaults`
  /// and would render as "everything off", making the user think their
  /// saved state was lost. Lives on the model (not a separate flag)
  /// so a state change always emits and `ref.watch` rebuilds.
  final bool loaded;

  /// Human-readable reason the initial cloud fetch failed, if it did.
  /// Cleared on the next successful load. UI surfaces this in a
  /// snackbar once the loading state flips so the user knows the
  /// toggles they're looking at are *defaults*, not their saved state.
  final String? loadError;

  BackupPreferences copyWith({
    bool? enabled,
    int? hour,
    int? minute,
    BackupFrequency? frequency,
    DateTime? lastUploadAt,
    BackupAttempt? lastResult,
    bool? notifyOnBackupComplete,
    bool? notifyOnBackupFailed,
    bool? notifyOnRestoreComplete,
    String? timezone,
    DateTime? lastSavedAt,
    bool? loaded,
    String? loadError,
    bool clearLoadError = false,
    bool clearLastResult = false,
  }) {
    return BackupPreferences(
      enabled: enabled ?? this.enabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      frequency: frequency ?? this.frequency,
      lastUploadAt: lastUploadAt ?? this.lastUploadAt,
      lastResult: clearLastResult ? null : (lastResult ?? this.lastResult),
      notifyOnBackupComplete:
          notifyOnBackupComplete ?? this.notifyOnBackupComplete,
      notifyOnBackupFailed: notifyOnBackupFailed ?? this.notifyOnBackupFailed,
      notifyOnRestoreComplete:
          notifyOnRestoreComplete ?? this.notifyOnRestoreComplete,
      timezone: timezone ?? this.timezone,
      lastSavedAt: lastSavedAt ?? this.lastSavedAt,
      loaded: loaded ?? this.loaded,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
    );
  }

  /// 10 PM local — matches the server's `BackupPrefs` default. Was
  /// 3 AM before the per-user scheduler landed; 10 PM is the new
  /// quiet hour for the user to see the trigger fire (vs. 3 AM when
  /// they're asleep).
  ///
  /// Notifications default OFF — backup is a quiet background job; the
  /// user opts into the success / failure / restore banners via the
  /// Backup screen. Defaulting them on meant a freshly-installed user
  /// got a notification for every cloud-scheduled fire even if they'd
  /// never opened Backup.
  ///
  /// `loaded: false` here is the signal that no cloud fetch has
  /// happened yet — the UI must render a loading state instead of
  /// the (defaulted) toggles, otherwise the user sees "everything
  /// off" and assumes their saved state was lost.
  static const defaults = BackupPreferences(
    enabled: false,
    hour: 22,
    minute: 0,
    frequency: BackupFrequency.daily,
    lastUploadAt: null,
    lastResult: null,
    notifyOnBackupComplete: false,
    notifyOnBackupFailed: false,
    notifyOnRestoreComplete: false,
    lastSavedAt: null,
    loaded: false,
  );
}

enum BackupFrequency {
  daily,
  weekly,
  monthly;

  String get label => switch (this) {
        BackupFrequency.daily => 'Daily',
        BackupFrequency.weekly => 'Weekly',
        BackupFrequency.monthly => 'Monthly',
      };

  static BackupFrequency fromName(String? name) {
    for (final v in BackupFrequency.values) {
      if (v.name == name) return v;
    }
    return BackupFrequency.daily;
  }
}

/// One upload or restore attempt — either success with counts or
/// failure with a human-readable reason.
class BackupAttempt {
  const BackupAttempt.success({
    required this.transactions,
    required this.budgets,
    required this.at,
  })  : success = true,
        reason = null;

  const BackupAttempt.failure({required this.reason, required this.at})
      : success = false,
        transactions = 0,
        budgets = 0;

  final bool success;
  final int transactions;
  final int budgets;
  final DateTime at;
  final String? reason;
}

/// State notifier over the active user's `accounts/{sub}.backupPrefs`
/// document. Reads from the cloud on construction (one GET); holds
/// the result in memory; every setter updates the in-memory `state`
/// and flips a `_dirty` flag. [save] flushes the staged state to the
/// cloud in one request: `PATCH /accounts/<sub>` carrying every
/// `backupPrefs` field.
///
/// Two callers:
///
///   - **Backup screen**: toggles fire stage-only setters, Save calls
///     [save]. Standard explicit-save UX: one round-trip per user
///     intent, Back discards unsaved changes.
///   - **Agent widget**: each agent command (`turn auto-backup on`,
///     `set time to 9 PM`, etc.) calls the matching setter and then
///     invokes [save] once at the end so the agent's "one command =
///     one user intent" still maps to one round-trip, not the
///     old six-call churn.
class BackupPreferencesController extends StateNotifier<BackupPreferences> {
  BackupPreferencesController({
    required this._repo,
    required this._auth,
    this._timezone = const TimezoneService(),
  })  : super(BackupPreferences.defaults) {
    if (kDebugMode) {
      debugPrint('[backup-prefs] controller constructed — firing _load()');
    }
    _load();
  }

  final AccountsRepo _repo;
  final GmailAuth _auth;
  final TimezoneService _timezone;

  /// True when any setter has run since the last [save] (or initial
  /// load). UI uses this to grey the Save button when nothing has
  /// changed — no point flushing the cloud for a no-op edit session.
  bool _dirty = false;
  bool get isDirty => _dirty;

  /// Re-fetch from Firestore and rebuild in-memory state. Called on
  /// construction (cold start) and exposed so callers (the hydrator,
  /// a manual "pull to refresh" button, etc.) can force a refresh.
  ///
  /// Error policy: fetch-throws (network, permission denied, etc.) →
  /// `loadError` is populated so the Backup screen can show a snackbar
  /// explaining that what's on screen is *defaults*, not their saved
  /// state. fetch-returns-null (not signed in or no doc yet) → no
  /// error — defaults are the right display in that case and a
  /// snackbar would just be noise.
  Future<void> _load() async {
    if (kDebugMode) {
      debugPrint('[backup-prefs] _load() start');
    }
    try {
      // Probe the apiToken separately so we can distinguish
      // "not signed in" (silent — defaults are fine) from
      // "signed in but Firestore read failed" (snackbar — defaults
      // lie).
      final apiToken = await _auth.tryRestore();
      if (kDebugMode) {
        debugPrint('[backup-prefs] _load: apiToken present=${apiToken != null} '
            'len=${apiToken?.length ?? 0}');
      }
      if (apiToken == null) {
        if (kDebugMode) {
          debugPrint('[backup-prefs] _load: no apiToken — not signed in, '
              'leaving defaults');
        }
        state = state.copyWith(loaded: true, clearLoadError: true);
        return;
      }
      final sub = GmailAuth.subFromApiToken(apiToken);
      if (kDebugMode) {
        debugPrint('[backup-prefs] _load: sub=$sub');
      }
      final record = await _repo.fetch();
      if (kDebugMode) {
        debugPrint('[backup-prefs] _load: record=${record == null ? 'null' : 'present'} '
            'enabled=${record?.backupEnabled} '
            'hour=${record?.backupHour} '
            'notifyComplete=${record?.backupNotifyComplete} '
            'notifyFailed=${record?.backupNotifyFailed} '
            'notifyRestore=${record?.backupNotifyRestoreComplete} '
            'frequency=${record?.backupFrequency}');
      }
      if (record != null) {
        _applyRecord(record);
      } else {
        if (kDebugMode) {
          debugPrint('[backup-prefs] _load: no record — signed in but doc missing');
        }
        state = state.copyWith(
          loaded: true,
          loadError: 'Signed in but no saved settings in the cloud.',
        );
      }
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[backup-prefs] _load failed: $e\n$st');
      }
      state = state.copyWith(loaded: true, loadError: e.toString());
    }
  }

  void _applyRecord(AccountRecord r) {
    state = BackupPreferences(
      enabled: r.backupEnabled,
      hour: r.backupHour,
      minute: r.backupMinute,
      frequency: BackupFrequency.fromName(r.backupFrequency),
      lastUploadAt: r.lastBackupAt,
      lastResult: state.lastResult,
      notifyOnBackupComplete: r.backupNotifyComplete,
      notifyOnBackupFailed: r.backupNotifyFailed,
      notifyOnRestoreComplete: r.backupNotifyRestoreComplete,
      timezone: r.timezone,
      loaded: true,
    );
    _dirty = false;
  }

  // -- Stage-only setters ------------------------------------------------
  // Each updates `state` and flips `_dirty`. No network until [save].

  void setEnabled(bool v) {
    state = state.copyWith(enabled: v);
    _dirty = true;
  }

  void setTime(int hour, int minute) {
    final h = hour.clamp(0, 23);
    final m = minute.clamp(0, 59);
    state = state.copyWith(hour: h, minute: m);
    _dirty = true;
  }

  void setFrequency(BackupFrequency f) {
    state = state.copyWith(frequency: f);
    _dirty = true;
  }

  void setNotifyOnBackupComplete(bool v) {
    state = state.copyWith(notifyOnBackupComplete: v);
    _dirty = true;
  }

  void setNotifyOnBackupFailed(bool v) {
    state = state.copyWith(notifyOnBackupFailed: v);
    _dirty = true;
  }

  void setNotifyOnRestoreComplete(bool v) {
    state = state.copyWith(notifyOnRestoreComplete: v);
    _dirty = true;
  }

  // -- Cloud flush -------------------------------------------------------

  /// Flush staged state to Firestore. Returns success / failure; UI
  /// surfaces this in the Save snackbar. No-op when nothing has
  /// changed since the last save (or initial load) — saves a write
  /// when the user opens the screen, toggles nothing, and taps Save
  /// anyway.
  ///
  /// On success, `_dirty` clears and `lastSavedAt` updates. On
  /// failure, `_dirty` stays set so a retry can pick up the same
  /// staged state.
  ///
  /// The per-user Cloud Scheduler job is kept in lockstep by the
  /// Eventarc trigger on `accounts/{sub}` writes — no separate
  /// scheduler POST from the client. One Firestore write per
  /// user-intent; the trigger does the rest.
  Future<BackupSaveResult> save() async {
    if (!_dirty) return BackupSaveResult.success();

    // Re-probe the timezone on every save so a user who travelled
    // (CST → PST) immediately picks up the new zone without having
    // to remember to also re-save. Cheap (single-digit ms) and the
    // alternative — caching on app start — would silently misfire
    // for hours after a flight.
    final tz = await _timezone.getLocalIanaName();

    final body = <String, Object?>{
      'backupPrefs': {
        'enabled': state.enabled,
        'hour': state.hour,
        'minute': state.minute,
        'frequency': state.frequency.name,
        'notifyComplete': state.notifyOnBackupComplete,
        'notifyFailed': state.notifyOnBackupFailed,
        'notifyRestoreComplete': state.notifyOnRestoreComplete,
      },
      // Timezone lives at the top level of the PATCH body — the
      // server's PATCH handler reads `body['timezone']` (sibling of
      // `backupPrefs`, not nested). Sending it inside backupPrefs
      // meant the server silently ignored it and the scheduler fell
      // back to UTC, so a 1:45 AM CST user got a timer that fired
      // at 1:45 AM UTC = 8:45 PM CST.
      'timezone': tz,
    };

    try {
      await _repo.patch(body);
    } catch (e) {
      return BackupSaveResult.failure(
          'cloud save failed: ${e.toString()}');
    }

    state = state.copyWith(lastSavedAt: DateTime.now(), timezone: tz);
    _dirty = false;
    return BackupSaveResult.success();
  }

  // -- Backup-attempt bookkeeping (not staged; always live) --------------

  Future<void> recordSuccess({
    required int transactions,
    required int budgets,
    DateTime? at,
  }) async {
    final ts = at ?? DateTime.now();
    state = state.copyWith(
      lastUploadAt: ts,
      lastResult: BackupAttempt.success(
        transactions: transactions,
        budgets: budgets,
        at: ts,
      ),
    );
    // Server tracks `lastBackupAt` itself (see /backup/upload
    // handler) — we don't PATCH it here. The next /accounts fetch
    // picks up the new value.
  }

  Future<void> recordFailure(String reason) async {
    state = state.copyWith(
      lastResult: BackupAttempt.failure(reason: reason, at: DateTime.now()),
    );
  }

  /// Clears the last-result row (used when the user navigates away
  /// after a successful manual upload so a stale "failed" banner
  /// doesn't linger if the next auto-trigger hasn't landed yet).
  void clearLastResult() {
    state = state.copyWith(clearLastResult: true);
  }
}

/// Result of [BackupPreferencesController.save]. The Backup screen
/// renders the `reason` in the snackbar when the user clicks Save so
/// they can tell a Firestore PATCH failure from a scheduler-update
/// warning — the two failure modes are different in practice (the
/// first means nothing persisted; the second means prefs persisted but
/// the next Cloud Scheduler fire may be off-schedule).
class BackupSaveResult {
  const BackupSaveResult._({required this.success, this.reason});
  factory BackupSaveResult.success() => const BackupSaveResult._(success: true);
  factory BackupSaveResult.failure(String reason) =>
      BackupSaveResult._(success: false, reason: reason);

  final bool success;
  final String? reason;
}

/// `flutter_local_notifications` doesn't expose a `TimeOfDay` type, so
/// we keep just the integer hour + minute on the model. The picker
/// UI builds a [TimeOfDay] from these two ints on demand.
extension BackupPreferencesTime on BackupPreferences {
  TimeOfDay get scheduledTime => TimeOfDay(hour: hour, minute: minute);

  /// Pretty-printed "10:00 PM" — used in the settings tile so the
  /// user can read the schedule at a glance without opening the
  /// screen. Local time, matching what the user picked.
  String get scheduledTimeLabel {
    final h = hour % 12 == 0 ? 12 : hour % 12;
    final period = hour >= 12 ? 'PM' : 'AM';
    final mm = minute.toString().padLeft(2, '0');
    return '$h:$mm $period';
  }

  /// The next instant a backup would fire, computed in the device's
  /// current local timezone using the staged hour + minute +
  /// frequency. Drives the "Next backup" preview row on the Backup
  /// screen so the user can see what Save will produce before
  /// committing.
  ///
  /// Daily  → next occurrence of `hour:minute` (today if not yet
  ///          passed, else tomorrow).
  /// Weekly → next Sunday at `hour:minute`.
  /// Monthly → next 1st-of-month at `hour:minute`.
  ///
  /// Returns null when disabled — the preview row hides in that case.
  DateTime? get nextFireLocal {
    if (!enabled) return null;
    final now = DateTime.now();
    var candidate = DateTime(now.year, now.month, now.day, hour, minute);
    if (!candidate.isAfter(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    switch (frequency) {
      case BackupFrequency.daily:
        return candidate;
      case BackupFrequency.weekly:
        while (candidate.weekday != DateTime.sunday) {
          candidate = candidate.add(const Duration(days: 1));
        }
        return candidate;
      case BackupFrequency.monthly:
        while (candidate.day != 1) {
          candidate = candidate.add(const Duration(days: 1));
        }
        return candidate;
    }
  }

  /// "Sun, Mar 15 at 10:00 PM" — human-readable preview. Null when
  /// the schedule is off (the UI hides the row in that case).
  String? get nextFireLabel {
    final fire = nextFireLocal;
    if (fire == null) return null;
    const weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    // weekday is 1=Mon..7=Sun; map into the names array.
    final wd = weekdayNames[fire.weekday - 1];
    return '$wd at $scheduledTimeLabel';
  }
}

final backupPreferencesProvider =
    StateNotifierProvider<BackupPreferencesController, BackupPreferences>(
  (ref) {
    final repo = ref.watch(accountsRepoProvider);
    final auth = ref.watch(gmailAuthProvider);
    return BackupPreferencesController(
      repo: repo,
      auth: auth,
    );
  },
);