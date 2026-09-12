import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../providers/providers.dart';

/// Bottom sheet that asks the user what to do with their cloud
/// backup before disconnecting. Three options, one always wipes
/// local data — the device-local SQLite + SecureStorage go either
/// way. The cloud backup is what varies:
///
///   - Back up, then sign out   → uploads a fresh snapshot, then
///                                 signs out. Cloud retains the data.
///   - Delete backup, then sign out → nukes the cloud object, then
///                                     signs out. Nothing survives
///                                     in cloud; signing back in is
///                                     a clean slate.
///   - Just sign out            → today`s behaviour. Cloud untouched;
///                                 next sign-in auto-restores.
///
/// The dialog dismisses immediately when an option is picked — the
/// actual operation runs in the background so a flaky network can't
/// make the user stare at a spinner (the disconnect calls are
/// already fire-and-forget inside `GmailAuth.signOut`).
Future<void> showDisconnectSheet(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => const _DisconnectSheet(),
  );
}

class _DisconnectSheet extends ConsumerStatefulWidget {
  const _DisconnectSheet();

  @override
  ConsumerState<_DisconnectSheet> createState() => _DisconnectSheetState();
}

enum _Choice { backupAndSignOut, deleteAndSignOut, justSignOut }

class _DisconnectSheetState extends ConsumerState<_DisconnectSheet> {
  _Choice? _selected;
  bool _busy = false;

  Future<void> _run() async {
    final choice = _selected;
    if (choice == null || _busy) return;
    setState(() => _busy = true);

    final messenger = ScaffoldMessenger.of(context);
    final backup = ref.read(backupServiceProvider);
    final auth = ref.read(gmailAuthProvider);

    // All three paths share the same local cleanup; only the cloud
    // side-effect differs. We do the cloud side-effect FIRST so a
    // network blip there doesn't leave the user stranded in a state
    // where they think they wiped the cloud but actually didn't.
    String? cloudMsg;
    switch (choice) {
      case _Choice.backupAndSignOut:
        final result = await backup.upload();
        cloudMsg = result.success
            ? 'Backed up to cloud'
            : 'Backup failed: ${result.reason ?? "unknown"}';
        break;
      case _Choice.deleteAndSignOut:
        final ok = await backup.removeBackup();
        cloudMsg = ok ? 'Cloud backup deleted' : 'Could not reach cloud';
        break;
      case _Choice.justSignOut:
        // No cloud call — the backup survives untouched.
        break;
    }

    // Local sign-out happens regardless. It's already fire-and-
    // forget on the network side and parallelised internally, so
    // this returns quickly and the sheet can dismiss cleanly.
    await auth.signOut();

    if (!mounted) return;
    ref.invalidate(gmailConnectedProvider);
    Navigator.of(context).pop();
    // cloudMsg is null for the "just sign out" branch (no cloud call
    // was made). Avoid printing literal "null" — drop the suffix when
    // there's nothing cloud-side to report.
    messenger.showSnackBar(SnackBar(
      content: Text(
        cloudMsg == null ? 'Disconnected' : 'Disconnected · $cloudMsg',
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.sm,
          AppSpacing.pagePadding,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.logout_rounded, color: scheme.error, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Sign out of Pocket?',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'In every case the data on THIS device is wiped '
              '(transactions, budgets, manual entries). What changes '
              'in the cloud depends on which option you pick below.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _OptionTile(
              icon: Icons.cloud_upload_rounded,
              title: 'Back up, then sign out',
              subtitle:
                  'Saves a fresh snapshot to the cloud before '
                  'disconnecting. Local data is wiped here; '
                  'next sign-in restores from cloud.',
              selected: _selected == _Choice.backupAndSignOut,
              onTap: _busy
                  ? null
                  : () => setState(() => _selected = _Choice.backupAndSignOut),
            ),
            const SizedBox(height: AppSpacing.sm),
            _OptionTile(
              icon: Icons.cloud_off_rounded,
              title: 'Delete backup, then sign out',
              subtitle:
                  'Wipes the cloud backup object. Local data is wiped '
                  'too — no recovery on next sign-in.',
              destructive: true,
              selected: _selected == _Choice.deleteAndSignOut,
              onTap: _busy
                  ? null
                  : () => setState(() => _selected = _Choice.deleteAndSignOut),
            ),
            const SizedBox(height: AppSpacing.sm),
            _OptionTile(
              icon: Icons.logout_rounded,
              title: 'Just sign out',
              subtitle:
                  'Disconnects on this device. Cloud backup is left '
                  'untouched; next sign-in restores it automatically.',
              selected: _selected == _Choice.justSignOut,
              onTap: _busy
                  ? null
                  : () => setState(() => _selected = _Choice.justSignOut),
            ),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: LoadingButton(
                    label: _busy ? 'Working…' : 'Sign out',
                    icon: Icons.logout_rounded,
                    busy: _busy,
                    onPressed: _selected == null ? null : _run,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = destructive ? scheme.error : scheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.08)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? accent : scheme.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: accent),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: destructive ? accent : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? accent : scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
