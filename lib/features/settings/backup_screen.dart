import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/time_format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../data/services/backup_service.dart';
import '../../providers/backup_provider.dart';
import '../../providers/providers.dart';

/// Cloud backup settings:
///
///   - Master toggle for auto-backup (when off, the per-user Cloud
///     Scheduler job is removed and only manual uploads happen).
///   - Time picker for the desired daily backup time, in the user's
///     local timezone. Pushed to the server so the per-user job's
///     cron lines up.
///   - Frequency selector — only `daily` is wired end-to-end today;
///     weekly + monthly surface as options but the server treats
///     them as daily until the cron learns day-of-week / day-of-month
///     matching.
///   - Notification toggles for backup-success / backup-failure /
///     restore-complete banners.
///   - "Back up now" button — immediate upload via [BackupService].
///   - "Restore from cloud" button — destructive truncate-and-load;
///     gated behind a confirm dialog so the user can't tap it by
///     accident and lose local transactions.
///
/// Edit semantics: explicit-save. Toggling any control updates the
/// in-memory `state` and flips a dirty flag — no Firestore writes
/// happen until the user taps Save. Back without Save discards
/// every staged edit; the next screen open re-reads from the cloud
/// and shows the saved state.
///
/// Status row at the bottom shows the most recent attempt's outcome
/// (success with counts, or failure with reason). Successful manual
/// uploads also fire a snackbar.
class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _uploading = false;
  bool _restoring = false;
  bool _saving = false;
  // Guards against re-firing the load-failure snackbar on every
  // rebuild — we want it once per session.
  String? _shownLoadError;

  Future<void> _pickTime(int currentHour, int currentMinute) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: currentHour, minute: currentMinute),
      helpText: 'Backup time',
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false),
        child: child!,
      ),
    );
    if (picked != null) {
      // Stage-only — nothing hits the cloud until the user taps Save.
      ref
          .read(backupPreferencesProvider.notifier)
          .setTime(picked.hour, picked.minute);
    }
  }

  Future<void> _onUpload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    final svc = ref.read(backupServiceProvider);
    final result = await svc.upload();
    if (!mounted) return;
    setState(() => _uploading = false);

    final prefs = ref.read(backupPreferencesProvider);
    if (result.success) {
      await ref.read(backupPreferencesProvider.notifier).recordSuccess(
            transactions: result.transactions,
            budgets: result.budgets,
            at: result.uploadedAt ?? DateTime.now(),
          );
      if (!mounted) return;
      showPocketSnackBar(
        context,
        'Backed up ${result.transactions} transactions, '
        '${result.budgets} budgets',
      );
      if (prefs.notifyOnBackupComplete) {
        await svc.notifySuccess(
          transactions: result.transactions,
          budgets: result.budgets,
        );
      }
    } else {
      await ref
          .read(backupPreferencesProvider.notifier)
          .recordFailure(result.reason ?? 'Unknown error');
      if (!mounted) return;
      showPocketSnackBar(
        context,
        'Backup failed: ${result.reason ?? "unknown"}',
      );
      if (prefs.notifyOnBackupFailed) {
        await svc.notifyFailure(result.reason ?? 'Unknown error');
      }
    }
  }

  Future<void> _onSave() async {
    if (_saving) return;
    setState(() => _saving = true);

    final controller = ref.read(backupPreferencesProvider.notifier);
    final prefs = ref.read(backupPreferencesProvider);
    // Single save() flush covers both paths: the Firestore PATCH
    // writes every staged `backupPrefs` field; the scheduler POST
    // creates / updates / deletes `pocket-backup-{sub}` based on
    // `state.enabled`. One round-trip pair per user intent, regardless
    // of how many toggles were flipped.
    final result = await controller.save();
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.success) {
      showPocketSnackBar(
        context,
        'Backup saved — ${_scheduleLabel(prefs)}',
      );
    } else {
      // Loud + actionable: the user clicked Save and it didn't land.
      // We keep the staged state (don't pop) so they can retry once
      // the network recovers.
      showPocketSnackBar(
        context,
        'Save failed — ${result.reason ?? "cloud save failed"}. '
        'Your changes are still staged; tap Save again to retry.',
      );
    }
  }

  Future<void> _onRestore() async {
    if (_restoring) return;
    final theme = Theme.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from cloud?'),
        content: Text(
          'This will replace every transaction and budget on this device '
          'with the snapshot from your last backup. Anything captured '
          'since then is lost.\n\n'
          'Are you sure?',
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _restoring = true);
    final svc = ref.read(backupServiceProvider);
    final result = await svc.restore();
    if (!mounted) return;
    setState(() => _restoring = false);

    // Restore wipes the local tables — the dashboard, transactions
    // list, and budget view all rely on the same DB so they need to
    // re-read. Invalidating every provider that touches those tables
    // is the safest reset; cheaper than tracking exactly which
    // providers saw the wiped rows.
    if (result.success) {
      ref.invalidate(transactionRepoProvider);
      ref.invalidate(budgetRepoProvider);
      showPocketSnackBar(
        context,
        'Restored ${result.transactions} transactions, '
        '${result.budgets} budgets',
      );
      if (ref.read(backupPreferencesProvider).notifyOnRestoreComplete) {
        await svc.notifyRestoreComplete(
          transactions: result.transactions,
          budgets: result.budgets,
        );
      }
    } else {
      showPocketSnackBar(
        context,
        'Restore failed: ${result.reason ?? "unknown"}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = ref.watch(backupPreferencesProvider);
    final controller = ref.read(backupPreferencesProvider.notifier);
    // Disabled when nothing has changed — saves a round-trip pair on
    // the "opened the screen, looked, backed out" case. Re-enabled
    // instantly when any toggle / picker mutates `state`.
    final canSave = controller.isDirty;

    // Surface a load failure once. The controller populates
    // `prefs.loadError` when the initial GET /accounts/<sub> throws
    // (network/5xx/etc.); null-record (no doc / not signed in) is not
    // treated as an error so we don't false-alarm on first launch.
    // We track `_shownLoadError` to dedupe across rebuilds — without
    // it, every ref.watch rebuild fires the snackbar again.
    if (prefs.loaded &&
        prefs.loadError != null &&
        prefs.loadError != _shownLoadError) {
      _shownLoadError = prefs.loadError;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showPocketSnackBar(
          context,
          'Couldn\'t load backup settings — showing defaults. '
          '(${prefs.loadError})',
        );
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Backup'),
        actions: [
          LoadingButton.text(
            label: 'Save',
            busyLabel: 'Saving…',
            busy: _saving,
            onPressed: canSave ? _onSave : null,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      // Until the controller's first `GET /accounts/<sub>` resolves,
      // every toggle in `state` is just `BackupPreferences.defaults`
      // — rendering them as "off" makes the user think their saved
      // state was lost on app restart. Show a spinner until
      // `prefs.loaded` flips so the screen never lies about the
      // cloud's view.
      body: prefs.loaded
          ? _buildContent(theme, prefs, controller)
          : const _LoadingState(),
    );
  }

  Widget _buildContent(
    ThemeData theme,
    BackupPreferences prefs,
    BackupPreferencesController controller,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.md,
        AppSpacing.pagePadding,
        AppSpacing.lg,
      ),
      children: [
        _StatusCard(prefs: prefs),
        const SizedBox(height: AppSpacing.md),
        _AutoBackupCard(
          enabled: prefs.enabled,
          hour: prefs.hour,
          minute: prefs.minute,
          frequency: prefs.frequency,
          nextFireLabel: prefs.nextFireLabel,
          timezone: prefs.timezone,
          onToggle: controller.setEnabled,
          onPickTime: () => _pickTime(prefs.hour, prefs.minute),
          onPickFrequency: () async {
            final picked = await showModalBottomSheet<BackupFrequency>(
              context: context,
              builder: (_) => _FrequencySheet(current: prefs.frequency),
            );
            if (picked != null) {
              // Stage-only — nothing hits the cloud until Save.
              controller.setFrequency(picked);
            }
          },
        ),
        const SizedBox(height: AppSpacing.md),
        _NotificationsCard(
          notifyOnBackupComplete: prefs.notifyOnBackupComplete,
          notifyOnBackupFailed: prefs.notifyOnBackupFailed,
          notifyOnRestoreComplete: prefs.notifyOnRestoreComplete,
          onToggleBackupComplete: controller.setNotifyOnBackupComplete,
          onToggleBackupFailed: controller.setNotifyOnBackupFailed,
          onToggleRestoreComplete: controller.setNotifyOnRestoreComplete,
        ),
        const SizedBox(height: AppSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text(
            'Backups store your transactions + budgets as a single '
            'snapshot in Firestore. AI logs stay on this device — they '
            'describe parser decisions, not your data.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _SaveStatusRow(prefs: prefs),
        const SizedBox(height: AppSpacing.lg),
        LoadingButton.outlined(
          label: 'Back up now',
          busyLabel: 'Uploading…',
          busy: _uploading,
          icon: Icons.cloud_upload_rounded,
          onPressed: _onUpload,
        ),
        const SizedBox(height: AppSpacing.sm),
        LoadingButton.outlined(
          label: 'Restore from cloud',
          busyLabel: 'Restoring…',
          busy: _restoring,
          icon: Icons.cloud_download_rounded,
          onPressed: _onRestore,
        ),
      ],
    );
  }
}

/// Shown while the controller's initial `GET /accounts/<sub>` is in
/// flight. Renders a centered spinner + caption so the user knows the
/// screen is fetching their saved state from the cloud, not stuck or
/// reset. Once `prefs.loaded` flips, the screen swaps in the real
/// content.
class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2.5),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Loading your backup settings…',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.prefs});
  final BackupPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final attempt = prefs.lastResult;
    final lastUploadAt = prefs.lastUploadAt;

    // Determine the headline state: error > recent success > idle.
    final Color iconBg;
    final Color iconColor;
    final IconData icon;
    final String title;
    final String? subtitle;

    if (attempt is BackupAttempt && !attempt.success) {
      iconBg = AppColors.danger.withValues(alpha: 0.14);
      iconColor = AppColors.danger;
      icon = Icons.error_outline_rounded;
      title = 'Last backup failed';
      subtitle = attempt.reason;
    } else if (lastUploadAt != null) {
      iconBg = AppColors.success.withValues(alpha: 0.14);
      iconColor = AppColors.success;
      icon = Icons.cloud_done_rounded;
      final relTime = _relativeTime(lastUploadAt);
      title = 'Last backup $relTime';
      subtitle = attempt is BackupAttempt && attempt.success
          ? '${attempt.transactions} transactions · ${attempt.budgets} budgets'
          : null;
    } else {
      iconBg = scheme.surfaceContainerHigh;
      iconColor = scheme.onSurfaceVariant;
      icon = Icons.cloud_outlined;
      title = 'No backup yet';
      subtitle = 'Tap "Back up now" to create your first snapshot.';
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeTime(DateTime t) => TimeFormat.relative(t);
}

class _AutoBackupCard extends StatelessWidget {
  const _AutoBackupCard({
    required this.enabled,
    required this.hour,
    required this.minute,
    required this.frequency,
    required this.nextFireLabel,
    required this.timezone,
    required this.onToggle,
    required this.onPickTime,
    required this.onPickFrequency,
  });

  final bool enabled;
  final int hour;
  final int minute;
  final BackupFrequency frequency;
  final String? nextFireLabel;
  final String? timezone;
  final void Function(bool) onToggle;
  final VoidCallback onPickTime;
  final VoidCallback onPickFrequency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: enabled,
            onChanged: (v) {
              onToggle(v);
            },
            title: Text(
              'Auto-backup',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            subtitle: Text(
              enabled
                  ? 'A snapshot is uploaded each day around '
                      '${_formatTime(hour, minute, context)} local time'
                  : 'Only manual backups run while this is off',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (enabled) const Divider(height: 1),
          if (enabled)
            ListTile(
              leading: const Icon(Icons.schedule_rounded, size: 20),
              title: const Text('Time'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(hour, minute, context),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: onPickTime,
            ),
          if (enabled) const Divider(height: 1),
          if (enabled)
            ListTile(
              leading: const Icon(Icons.repeat_rounded, size: 20),
              title: const Text('Frequency'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    frequency.label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
              onTap: onPickFrequency,
            ),
          if (enabled) const Divider(height: 1),
          if (enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.md,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.event_available_rounded,
                    size: 18,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      nextFireLabel == null
                          ? 'Computing next backup…'
                          : 'Next backup — $nextFireLabel'
                              '${timezone == null ? '' : ' ($timezone)'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _formatTime(int h, int m, BuildContext context) {
    // The stored hour + minute are local (the picker uses TimeOfDay,
    // which is always device-local). Render them as a wall-clock
    // string in the user's timezone so the value matches what they
    // tapped — including minute precision, since the picker returns
    // both.
    final now = DateTime.now();
    final dt = DateTime(now.year, now.month, now.day, h, m);
    return TimeFormat.shortTime(dt);
  }
}

class _FrequencySheet extends StatelessWidget {
  const _FrequencySheet({required this.current});
  final BackupFrequency current;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          for (final f in BackupFrequency.values)
            ListTile(
              title: Text(f.label),
              trailing: f == current
                  ? Icon(
                      Icons.check_rounded,
                      color: Theme.of(context).colorScheme.primary,
                    )
                  : null,
              onTap: () => Navigator.of(context).pop(f),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

/// Persists below the footer text once the user has changed a
/// preference and tap-saved. Hidden until the first save lands so the
/// UI doesn't show a stale "saved at" from a previous session (the
/// timestamp lives only in memory — intentional, see
/// `BackupPreferences.lastSavedAt`).
class _SaveStatusRow extends StatelessWidget {
  const _SaveStatusRow({required this.prefs});
  final BackupPreferences prefs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (prefs.lastSavedAt == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 14,
            color: AppColors.success,
          ),
          const SizedBox(width: 6),
          Text(
            'Saved — ${_scheduleLabel(prefs)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Human-readable summary of what the user just persisted: either
/// "Auto-backup off" or "Daily at 3:00 AM". Used by both the Save
/// snackbar and the inline status row so the two messages always
/// describe the same state — the user reads off the same description
/// they saw on screen.
String _scheduleLabel(BackupPreferences p) {
  if (!p.enabled) return 'Auto-backup off';
  return '${p.frequency.label} at ${p.scheduledTimeLabel}';
}

/// Card of toggle switches that let the user opt in/out of each
/// distinct backup/restore system notification. Defaults are all OFF
/// so a fresh install starts quiet; the user opts in via the toggles
/// and saves. Toggles stage locally — Save flushes them to Firestore.
class _NotificationsCard extends StatelessWidget {
  const _NotificationsCard({
    required this.notifyOnBackupComplete,
    required this.notifyOnBackupFailed,
    required this.notifyOnRestoreComplete,
    required this.onToggleBackupComplete,
    required this.onToggleBackupFailed,
    required this.onToggleRestoreComplete,
  });

  final bool notifyOnBackupComplete;
  final bool notifyOnBackupFailed;
  final bool notifyOnRestoreComplete;
  final void Function(bool) onToggleBackupComplete;
  final void Function(bool) onToggleBackupFailed;
  final void Function(bool) onToggleRestoreComplete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget tile({
      required IconData icon,
      required String title,
      required String subtitle,
      required bool value,
      required void Function(bool) onChanged,
    }) {
      return SwitchListTile.adaptive(
        value: value,
        onChanged: onChanged,
        secondary: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
        title: Text(
          title,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.notifications_active_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Notifications',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          tile(
            icon: Icons.cloud_done_rounded,
            title: 'Backup complete',
            subtitle: 'Heads-up when any backup finishes successfully.',
            value: notifyOnBackupComplete,
            onChanged: onToggleBackupComplete,
          ),
          const Divider(height: 1),
          tile(
            icon: Icons.error_outline_rounded,
            title: 'Backup failed',
            subtitle:
                'Heads-up when a backup fails — independent of success so '
                'you can mute the OK pings but keep failures loud.',
            value: notifyOnBackupFailed,
            onChanged: onToggleBackupFailed,
          ),
          const Divider(height: 1),
          tile(
            icon: Icons.cloud_download_rounded,
            title: 'Restore complete',
            subtitle:
                'Heads-up when "Restore from cloud" finishes loading '
                'your snapshot.',
            value: notifyOnRestoreComplete,
            onChanged: onToggleRestoreComplete,
          ),
        ],
      ),
    );
  }
}
