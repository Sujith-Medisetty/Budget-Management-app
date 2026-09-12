import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/time_format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/ai_config.dart';
import '../../providers/backup_provider.dart';
import '../../providers/budget_preferences_provider.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';
import 'ai_log_screen.dart';
import 'ai_model_screen.dart';
import 'backup_screen.dart';
import 'connected_accounts_screen.dart';
import 'delete_account_screen.dart';
import '../admin/docs_screen.dart';

/// Settings hub:
///   - Permissions (POST_NOTIFICATIONS for budget alerts)
///   - Accounts (Gmail)
///   - AI model picker
///   - Backup
///   - Budgets (auto-create new month on rollover)
///   - Diagnostics (AI log + GCP infra)
///   - Danger zone (Delete account)
///
/// Theme toggle lives in the app bar of every screen via
/// [ThemeToggleButton].
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Future<void> _requestNotifications() async {
    await ref.read(notificationServiceProvider).requestPermission();
    // Android 13+ may bounce the user to system settings if they denied
    // twice. Re-query after a beat so the tile reflects the final state.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    ref.invalidate(notificationsEnabledProvider);
  }

  @override
  Widget build(BuildContext context) {
    final aiCfg = ref.watch(aiConfigProvider);
    final notif = ref.watch(notificationsEnabledProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: const [ThemeToggleButton()],
      ),
      body: SafeArea(
        top: false,
        // bottom: true (default) so the destructive "Delete account"
        // tile at the bottom of the list never renders behind the
        // system nav bar / gesture pill on phones — same behavior as
        // iOS apps that respect the home-indicator safe area.
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pagePadding,
            AppSpacing.md,
            AppSpacing.pagePadding,
            AppSpacing.floatingBarContentPadding,
          ),
        children: [
          _AllowNotificationsTile(
            enabled: notif,
            onRequest: _requestNotifications,
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('Accounts'),
          const SizedBox(height: AppSpacing.sm),
          const _ConnectedAccountsTile(),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('AI model'),
          const SizedBox(height: AppSpacing.sm),
          _AIModelTile(
            config: aiCfg,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AiModelScreen()),
              );
            },
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('Backup'),
          const SizedBox(height: AppSpacing.sm),
          const _BackupTile(),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('Budgets'),
          const SizedBox(height: AppSpacing.sm),
          const _BudgetsTile(),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('Diagnostics'),
          const SizedBox(height: AppSpacing.sm),
          const _ActivityLogTile(),
          const _DocumentationTile(),
          const SizedBox(height: AppSpacing.sectionGap),
          const _SectionLabel('Danger zone'),
          const SizedBox(height: AppSpacing.sm),
          const _DeleteAccountTile(),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _AllowNotificationsTile extends StatelessWidget {
  const _AllowNotificationsTile({
    required this.enabled,
    required this.onRequest,
  });
  final AsyncValue<bool> enabled;
  final Future<void> Function() onRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final asyncEnabled = enabled;
    final isLoading = asyncEnabled.isLoading;
    final isEnabled = asyncEnabled.valueOrNull ?? false;
    final hasError = asyncEnabled.hasError;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: (isLoading || isEnabled) ? null : onRequest,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isLoading || hasError
                      ? theme.colorScheme.surfaceContainerHigh
                      : isEnabled
                          ? AppColors.success.withValues(alpha: 0.14)
                          : AppColors.amber.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        hasError
                            ? Icons.help_outline_rounded
                            : isEnabled
                                ? Icons.campaign_rounded
                                : Icons.notifications_off_rounded,
                        color: hasError
                            ? theme.colorScheme.onSurfaceVariant
                            : isEnabled
                                ? AppColors.success
                                : AppColors.amber,
                        size: 20,
                      ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isLoading
                          ? 'Notifications…'
                          : isEnabled
                              ? 'Showing in-app notifications'
                              : 'Show in-app notifications',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isLoading
                          ? 'Checking permission status.'
                          : isEnabled
                              ? 'Pocket pings you when a budget hits its threshold.'
                              : 'Required for budget threshold alerts to appear. '
                                  'Tap Allow when the system prompt appears.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isLoading && !isEnabled)
                TextButton(onPressed: onRequest, child: const Text('Allow')),
            ],
          ),
        ),
      ),
    );
  }
}

class _AIModelTile extends StatelessWidget {
  const _AIModelTile({required this.config, required this.onTap});
  final AsyncValue<AiConfig> config;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = config.valueOrNull;
    final isLoading = config.isLoading;
    final hasKey = cfg?.hasKey ?? false;
    final provider = cfg?.provider ?? CloudProvider.openai;
    final model = cfg?.model ?? provider.defaultModel;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isLoading
                      ? theme.colorScheme.surfaceContainerHigh
                      : hasKey
                          ? theme.colorScheme.primary.withValues(alpha: 0.14)
                          : theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.psychology_rounded,
                        color: hasKey
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'AI model',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isLoading
                          ? 'Loading…'
                          : hasKey
                              ? '${provider.label} · $model'
                              : 'Not configured — add a key to start parsing',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectedAccountsTile extends ConsumerWidget {
  const _ConnectedAccountsTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncEmail = ref.watch(gmailConnectedProvider);
    final isLoading = asyncEmail.isLoading;
    final email = asyncEmail.valueOrNull;
    final connected = email != null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ConnectedAccountsScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isLoading
                      ? theme.colorScheme.surfaceContainerHigh
                      : connected
                          ? AppColors.success.withValues(alpha: 0.14)
                          : theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.account_circle_rounded,
                        color: connected
                            ? AppColors.success
                            : theme.colorScheme.primary,
                        size: 20,
                      ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Connected accounts',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isLoading
                          ? 'Loading…'
                          : connected
                              ? 'Gmail: $email'
                              : 'Sign in with Google to capture Gmail transactions',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActivityLogTile extends ConsumerWidget {
  const _ActivityLogTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final log = ref.watch(aiLogProvider);
    final isLoading = log.isLoading;
    final entries = log.valueOrNull ?? const [];
    final kept = entries.where((e) => e.isKept).length;
    final dropped = entries.where((e) => !e.isKept).length;
    final total = kept + dropped;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AiLogScreen()),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: isLoading
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        Icons.manage_search_rounded,
                        color: theme.colorScheme.primary,
                        size: 20,
                      ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Activity log',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      isLoading
                          ? 'Loading…'
                          : total == 0
                              ? 'See what the AI parses, keeps, and drops'
                              : 'Last $total: $kept kept · $dropped dropped',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Admin-only tile under Diagnostics that opens the in-app rendered
/// architecture doc (see `docs/ADMIN_ARCHITECTURE.md`). Same gate as
/// [_ActivityLogTile] — the doc is bundled into the APK so there's no
/// server-side check needed, but we still hide the tile for non-
/// admins so the surface area stays small for normal users.
class _DocumentationTile extends ConsumerWidget {
  const _DocumentationTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final asyncEmail = ref.watch(gmailConnectedProvider);
    final isLoading = asyncEmail.isLoading;
    final email = asyncEmail.valueOrNull;
    final isAdmin = email == kInfraAdminEmail;
    if (!isLoading && !isAdmin) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: isAdmin
              ? () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const DocsScreen()),
                  )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: isLoading
                        ? theme.colorScheme.surfaceContainerHigh
                        : AppColors.amber.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.menu_book_rounded,
                          color: AppColors.amber,
                          size: 20,
                        ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Documentation',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        isLoading
                            ? 'Loading…'
                            : 'Architecture, services, auth flows, endpoints',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BackupTile extends ConsumerWidget {
  const _BackupTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final prefs = ref.watch(backupPreferencesProvider);
    final subtitle = prefs.enabled
        ? 'Auto-backup at ${prefs.scheduledTimeLabel}'
        : prefs.lastUploadAt != null
            ? 'Last backup ${_relTime(prefs.lastUploadAt!)}'
            : 'Off — tap to back up manually';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BackupScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: prefs.enabled
                      ? AppColors.success.withValues(alpha: 0.14)
                      : theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  prefs.enabled
                      ? Icons.cloud_done_rounded
                      : Icons.cloud_outlined,
                  color: prefs.enabled
                      ? AppColors.success
                      : theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Cloud backup',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _relTime(DateTime t) => TimeFormat.relative(t);
}

/// One boolean, no extra sub-screen needed. Mirrors the
/// "notifications" tile pattern: a Switch in the trailing slot that
/// fires a single PATCH on flip. Server stores the value in
/// `accounts.budget_prefs` (default ON) so the toggle reflects what
/// the cron + sign-in helper actually do.
///
/// The toggle is intentionally auto-save (stage-only would require
/// an explicit Save button for a binary choice), and on save failure
/// the local state reverts so the Switch always reflects what's
/// authoritative on the server.
///
/// When the flip is OFF → ON and the server mints a current-month
/// budget as a side-effect (see the comment on the PATCH handler in
/// `server/lib/accounts.dart`), we re-run the local
/// `BudgetHydrator.ensureCurrentMonth()` to mirror the new row into
/// the device's SQLite. The hydrator's (name, startDate) match
/// guard means re-running it is a no-op if the row already exists
/// locally — so this is safe to call unconditionally on every flip.
/// The flip ON → OFF side intentionally does NOT touch budgets; we
/// never want to delete or modify existing rows just because the
/// user turned the auto-create toggle off.
class _BudgetsTile extends ConsumerStatefulWidget {
  const _BudgetsTile();
  @override
  ConsumerState<_BudgetsTile> createState() => _BudgetsTileState();
}

class _BudgetsTileState extends ConsumerState<_BudgetsTile> {
  bool _saving = false;

  Future<void> _flip(bool next) async {
    if (_saving) return;
    final controller = ref.read(budgetPreferencesProvider.notifier);
    final wasOn = ref.read(budgetPreferencesProvider).autoMonthlyBudget;
    if (next == wasOn) return;
    setState(() => _saving = true);
    // Stage first so the optimistic UI matches the user's gesture
    // — flipping the Switch back if the PATCH fails is much more
    // obvious than a flicker through "the click did nothing".
    controller.setAutoMonthlyBudget(next);
    final result = await controller.save();
    if (!mounted) return;
    setState(() => _saving = false);
    if (!result.success) {
      // Revert. Without this the Switch would say "off" while the
      // server still has the user marked "on" — and a refresh /
      // second device would disagree, surprising the user on the
      // next sign-in.
      controller.setAutoMonthlyBudget(!next);
      showPocketSnackBar(
        context,
        'Couldn\'t update setting: ${result.reason}',
      );
      return;
    }
    // Mirror any budget the server may have just minted as a
    // side-effect of the OFF → ON flip. The hydrator's match guard
    // short-circuits when a current-month row already exists
    // locally, so this is safe on every success path (ON → OFF
    // flips land in the hydrator's userOptedOut branch which is
    // also a no-op).
    await ref.read(budgetHydratorProvider).ensureCurrentMonth();
    if (!mounted) return;
    ref.invalidate(activeBudgetProvider);
    ref.invalidate(budgetsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prefs = ref.watch(budgetPreferencesProvider);
    // Loaded-vs-not drives the disabled state so we don't render
    // the user-toggled Switch reflecting defaults (a freshly-installed
    // user would otherwise see "ON" for both prefs.copyWith() defaults
    // AND something they set during onboarding — a small but real
    // source of "did my toggle save?" confusion).
    final enabled = prefs.loaded && !_saving;
    final on = prefs.autoMonthlyBudget;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled ? () => _flip(!on) : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: on
                      ? AppColors.success.withValues(alpha: 0.14)
                      : theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  on
                      ? Icons.event_repeat_rounded
                      : Icons.event_busy_rounded,
                  color: on ? AppColors.success : theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto-create monthly budget',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      on
                          ? 'A new "<MonthName> Expenses" budget is added on '
                              'the 1st of every month and on sign-in'
                          : 'Off — you create budgets manually from the '
                              'Budgets tab',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Switch(
                value: on,
                onChanged: enabled ? (v) => _flip(v) : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Permanent, destructive account action. Lives in the "Danger zone"
/// section of Settings (mirrors the GitHub pattern — red label, red
/// card). The tile itself looks like the other nav tiles so it
/// doesn't visually shout, but the section header + the destination
/// screen make the consequence obvious before the user even taps
/// through.
class _DeleteAccountTile extends ConsumerWidget {
  const _DeleteAccountTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: scheme.error.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.delete_forever_rounded,
                  color: scheme.error,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Delete account',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: scheme.error,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Removes account, every cloud backup, and the '
                      'Gmail filter. Cannot be undone.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
