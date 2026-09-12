import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../providers/providers.dart';

/// User-driven nuclear wipe.
///
///   1. Probe `GET /backup/current` for the last-backup timestamp.
///   2. If the user has no backup, or the last one is >24 h old,
///      block them with a "take a fresh backup first" gate. The rule
///      protects against the most common accidental-data-loss path:
///      "I deleted my account last Tuesday" → only whatever was in the
///      Monday backup survives, all transactions since then are gone.
///   3. After the gate is clear, the user has to type the literal
///      `DELETE` to enable the final button. This is a deliberate
///      bump beyond the confirm-dialog pattern (which trips when
///      people tap "OK" reflexively) and matches what GitHub,
///      Stripe, etc. do for equally-irreversible actions.
///   4. On confirm, hit `POST /account/delete`, then locally wipe
///      SQLite + SecureStorage. After that the user is on the login
///      screen with no Pocket data anywhere on the device.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  /// Local gate state machine:
  ///   `loading` — initial probe of backup freshness.
  ///   `fresh`   — last backup is <24h old, can proceed.
  ///   `stale`   — last backup >24h OR missing; must back up first.
  ///   `confirmed` — user typed "DELETE"; final confirm is enabled.
  _GateState _state = _GateState.loading;

  /// Force the gate back to "fresh" without re-probing — used after
  /// the user takes a backup via the inline "Backup now" action so
  /// the screen snaps forward without another network round-trip.
  bool _userJustBackedUp = false;

  String _typed = '';

  static const _staleAfter = Duration(hours: 24);
  static const _confirmWord = 'DELETE';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_userJustBackedUp) {
      setState(() {
        _state = _GateState.fresh;
        _userJustBackedUp = false;
      });
      return;
    }
    setState(() => _state = _GateState.loading);
    final info = await ref.read(backupServiceProvider).getBackupInfo();
    if (!mounted) return;
    if (info == null) {
      setState(() => _state = _GateState.stale);
      return;
    }
    final age = DateTime.now().toUtc().difference(info.uploadedAt.toUtc());
    setState(() => _state =
        age <= _staleAfter ? _GateState.fresh : _GateState.stale);
  }

  Future<void> _onBackupNow() async {
    final svc = ref.read(backupServiceProvider);
    final result = await svc.upload();
    if (!mounted) return;
    if (result.success) {
      _userJustBackedUp = true;
      showPocketSnackBar(
        context,
        'Backed up ${result.transactions} transactions · '
        '${result.budgets} budgets',
      );
      await _refresh();
    } else {
      showPocketSnackBar(
        context,
        'Backup failed: ${result.reason ?? "unknown"}',
      );
    }
  }

  Future<void> _onConfirm() async {
    final svc = ref.read(accountServiceProvider);
    final result = await svc.deleteAccount();
    if (!mounted) return;
    // Whether the call landed on the server or got rate-limited by
    // the network, the user wanted out — push them off the Settings
    // stack and back to the login screen. The login flow already
    // detects the missing-account case and renders a "your account
    // was deleted" snackbar on next attempt.
    if (result.success) {
      showPocketSnackBar(context, 'Your account has been deleted.');
    } else {
      showPocketSnackBar(
        context,
        'Local data cleared. ${result.reason ?? ""}',
      );
    }
    if (!mounted) return;
    // Pop everything until we're back at the auth/welcome screen.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Delete account')),
      body: SafeArea(
        // bottom: true (default) so the red "Delete account" confirm
        // button at the bottom never renders behind the system nav
        // bar / gesture pill — same safe-area respect iOS apps give
        // the home indicator area.
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pagePadding,
            AppSpacing.md,
            AppSpacing.pagePadding,
            AppSpacing.floatingBarContentPadding,
          ),
          children: [
            Card(
              color: scheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded, color: scheme.error),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          'Permanent',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      'Deletes your Pocket account, every backup stored '
                      'in the cloud, and the Gmail filter Pocket set up. '
                      'This cannot be undone.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _BackupGate(
              state: _state,
              onBackupNow: _onBackupNow,
            ),
            const SizedBox(height: AppSpacing.lg),
            _ConfirmPanel(
              enabled: _state == _GateState.fresh,
              typed: _typed,
              expected: _confirmWord,
              onChanged: (v) => setState(() => _typed = v),
              onConfirm: _onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}

enum _GateState { loading, fresh, stale }

class _BackupGate extends StatelessWidget {
  const _BackupGate({required this.state, required this.onBackupNow});

  final _GateState state;
  final Future<void> Function() onBackupNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: switch (state) {
          _GateState.loading => Row(
              children: [
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  'Checking your last backup…',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          _GateState.fresh => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_rounded, color: scheme.primary),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    'Your last backup is recent — safe to delete.',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          _GateState.stale => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.cloud_off_rounded, color: scheme.error),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'You don\'t have a recent backup. If you delete '
                        'now, only whatever was in your last backup '
                        'survives — everything since then is gone.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                LoadingButton(
                  label: 'Back up now',
                  icon: Icons.cloud_upload_rounded,
                  busy: false,
                  onPressed: onBackupNow,
                ),
              ],
            ),
        },
      ),
    );
  }
}

class _ConfirmPanel extends StatelessWidget {
  const _ConfirmPanel({
    required this.enabled,
    required this.typed,
    required this.expected,
    required this.onChanged,
    required this.onConfirm,
  });

  final bool enabled;
  final String typed;
  final String expected;
  final ValueChanged<String> onChanged;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canDelete = enabled && typed.trim() == expected;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Type $expected to confirm',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              enabled: enabled,
              autofocus: enabled,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'Type $expected',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  letterSpacing: 4,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
              ),
              style: theme.textTheme.bodyLarge?.copyWith(
                letterSpacing: 4,
                fontWeight: FontWeight.w700,
              ),
              onChanged: onChanged,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => canDelete ? onConfirm() : null,
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                  disabledBackgroundColor:
                      scheme.error.withValues(alpha: 0.4),
                ),
                onPressed: canDelete ? onConfirm : null,
                child: const Text('Delete account'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
