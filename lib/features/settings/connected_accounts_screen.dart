import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../data/services/gmail_filter_rules.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';
import 'disconnect_sheet.dart';
import 'email_filters_screen.dart';

/// Settings screen for managing connected third-party accounts.
/// Today: Google (Gmail capture). Adding Outlook later is a new tile.
class ConnectedAccountsScreen extends ConsumerStatefulWidget {
  const ConnectedAccountsScreen({super.key});

  @override
  ConsumerState<ConnectedAccountsScreen> createState() =>
      _ConnectedAccountsScreenState();
}

class _ConnectedAccountsScreenState
    extends ConsumerState<ConnectedAccountsScreen> {
  // Per-button busy flags. Each one drives the spinner inside its
  // own LoadingButton so the user can see exactly which call is in
  // flight. Stays in this screen (not the child widgets) because the
  // sign-in → reset chain shares state across buttons.
  bool _signingIn = false;
  bool _resetting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final emailAsync = ref.watch(gmailConnectedProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Connected accounts')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.md,
          AppSpacing.pagePadding,
          AppSpacing.xl,
        ),
        children: [
          _Section(
            title: 'Gmail',
            subtitle: 'Capture transactions from any Gmail message',
            child: emailAsync.when(
              loading: () => const _Skeleton(),
              error: (e, _) => _ErrorRow(message: '$e'),
              data: (email) => email == null
                  ? _SignInBlock(
                      busy: _signingIn,
                      resetting: _resetting,
                      onSignIn: _signIn,
                      onResetAndSignIn: _resetAndSignIn,
                    )
                  : _ConnectedRow(
                      email: email,
                      onSignOut: _signOut,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Pocket reads your mail with read-only access — it can list '
            'and open messages but can\'t send, archive, or delete. '
            'Disconnect anytime and Google revokes the grant instantly.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          const _EmailFiltersTile(),
        ],
      ),
    );
  }

  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(gmailAuthProvider).signIn();
      // Auto-restore the cloud snapshot now that the new account is
      // authorized. The dashboard is still mounted with the empty
      // pre-signin rows, so invalidateDataProviders inside the helper
      // bumps the outer FutureProviders it watches to re-fetch the
      // restored rows. "No backup found" is normal for first sign-in —
      // we just confirm connection without a status change.
      final result = await autoRestoreAfterSignIn(ref);
      if (result.success) {
        messenger.showSnackBar(SnackBar(
          content: Text(
            'Restored ${result.transactions} transactions · '
            '${result.budgets} budgets',
          ),
        ));
      } else if (result.reason != 'No backup found in cloud') {
        messenger.showSnackBar(SnackBar(
          content: Text(
            'Connected, but restore failed: ${result.reason ?? "unknown"}',
          ),
        ));
      }
      ref.invalidate(gmailConnectedProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_signInErrorMessage(e)),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: _isRecoverableError(e) ? 'Reset & retry' : 'Retry',
            onPressed: () => _isRecoverableError(e)
                ? _resetAndSignIn()
                : _signIn(),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _signingIn = false);
    }
  }

  /// Wipes Google Sign-In SDK state + on-device auth tokens, then
  /// tries sign-in again. The user calls this when plain Retry keeps
  /// failing — it forces a fresh consent sheet with the current
  /// scope list instead of reusing the cached grant that no longer
  /// matches. Always safe: a successful reset → sign-in ends in the
  /// same connected state as a normal flow.
  Future<void> _resetAndSignIn() async {
    if (_resetting || _signingIn) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Resetting Google sign-in…'),
        duration: Duration(seconds: 2),
      ),
    );
    setState(() => _resetting = true);
    try {
      await ref.read(gmailAuthProvider).wipeAndReset();
    } catch (e) {
      // wipeAndReset is best-effort; even if it fails we still try
      // sign-in below because the SDK often settles on its own once
      // we re-attempt with a delay.
      debugPrint('[connected-accounts] wipeAndReset failed: $e');
    }
    if (!mounted) return;
    setState(() => _resetting = false);
    await _signIn();
  }

  /// Translates raw exceptions into user-friendly copy. We deliberately
  /// keep the underlying type/code visible to the user (small line in
  /// the snackbar action menu) so support can debug from screenshots,
  /// but lead with the human-readable reason.
  String _signInErrorMessage(Object e) {
    final s = e.toString();
    if (s.contains('providerConfigurationError') ||
        s.contains('clientConfigurationError') ||
        s.contains('unknownError')) {
      return "Google's sign-in is having trouble. "
          'Tap reset & retry to clear the cache and try again.';
    }
    if (s.contains('canceled')) {
      return 'Sign-in cancelled.';
    }
    if (s.contains('interrupted')) {
      // Common right after sign-out: the SDK's previous auth flow
      // hasn't fully settled before the new one starts, so it bails
      // with `interrupted`. Reset clears the leftover state.
      return 'Sign-in was interrupted. '
          'Tap reset & retry to start with a clean slate.';
    }
    if (s.contains('userMismatch')) {
      // Picking a different account than the one already on file.
      // Reset lets the SDK forget the prior account.
      return "That account doesn't match the one you signed in with. "
          'Tap reset & retry to switch accounts.';
    }
    if (s.contains('networkError') || s.contains('SocketException')) {
      return 'No internet connection. Check Wi-Fi or data and try again.';
    }
    if (s.contains('oauth/exchange failed')) {
      return "Couldn't reach the server. Try again in a moment.";
    }
    // Catch-all — surface a trimmed copy of the underlying reason so
    // support can debug from a screenshot, and offer reset (safer
    // than blind retry for any unknown SDK-state failure).
    return 'Sign-in failed. Tap reset & retry.\n(${_shorten(s)})';
  }

  String _shorten(String s) {
    // Trim noisy stacktraces / framework prefixes so the snackbar
    // stays one readable line. Falls back to the start of the string
    // for unknown shapes.
    final firstLine = s.split('\n').first;
    if (firstLine.length > 110) {
      return '${firstLine.substring(0, 107)}…';
    }
    return firstLine;
  }

  /// True when the underlying exception looks like stale SDK state —
  /// i.e. the kind of failure a wipeAndReset() is most likely to clear.
  /// Includes `interrupted` and `userMismatch` because both typically
  /// resolve by forgetting the prior account grant. Mirrors
  /// GmailAuth._isRecoverableError but operates on the raw string so we
  /// can route off the catch-all here without importing the auth
  /// class internals.
  bool _isRecoverableError(Object e) {
    final s = e.toString();
    return s.contains('providerConfigurationError') ||
        s.contains('clientConfigurationError') ||
        s.contains('unknownError') ||
        s.contains('interrupted') ||
        s.contains('userMismatch');
  }

  Future<void> _signOut() async {
    // Show the 3-option bottom sheet; the actual sign-out, cloud
    // operations, and snackbars all happen inside the sheet itself.
    await showDisconnectSheet(context, ref);
  }

  Future<void> _syncNow() async {
    // Manual pull is gone — Pub/Sub push + FCM now delivers every new
    // mail in real time (see docs/ADMIN_ARCHITECTURE.md §8). This
    // method stays as a one-line stub for the agent verb
    // `sync_gmail_now` so existing conversations don't blow up.
    await ref.read(gmailSyncProvider).fetchNew();
  }
}

class _EmailFiltersTile extends ConsumerWidget {
  const _EmailFiltersTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rules = ref.watch(gmailFilterRulesProvider);
    final count = rules.rules.length;
    final subtitle = !rules.enabled
        ? 'Off — every Gmail message is processed.'
        : count == 0
            ? 'On, but no rules yet.'
            : 'On — $count rule${count == 1 ? '' : 's'} '
                '(${rules.logic == Logic.or ? 'any' : 'all'} match).';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const EmailFiltersScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.filter_alt_rounded,
                  color: scheme.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Email filters',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_circle_rounded, size: 24),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        )),
                    Text(subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        )),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          child,
        ],
      ),
    );
  }
}

class _SignInBlock extends StatelessWidget {
  const _SignInBlock({
    required this.busy,
    required this.resetting,
    required this.onSignIn,
    required this.onResetAndSignIn,
  });

  final bool busy;
  final bool resetting;
  final VoidCallback onSignIn;
  final VoidCallback onResetAndSignIn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final disableReset = busy || resetting;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LoadingButton.filled(
          label: 'Sign in with Google',
          busyLabel: 'Opening Google…',
          icon: Icons.login_rounded,
          busy: busy,
          onPressed: onSignIn,
        ),
        const SizedBox(height: AppSpacing.sm),
        // Discoverable escape hatch for the recurring "having trouble"
        // failure mode that hits after OAuth scope changes. The
        // snackbar's retry button is hidden behind a 6–8s timer, so
        // users who already failed once often miss it. This stays
        // visible until they connect.
        Center(
          child: LoadingButton.text(
            label: 'Having trouble signing in? Reset',
            busyLabel: 'Resetting…',
            busy: resetting,
            onPressed: disableReset ? null : () => _confirmReset(context),
          ).copyWithOverride(scheme.onSurfaceVariant, fontSize: 12),
        ),
      ],
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Google sign-in?'),
        content: const Text(
          "This clears Google's cached sign-in on this device and "
          'forces a fresh consent sheet. You\'ll sign in with the same '
          'Google account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reset & sign in'),
          ),
        ],
      ),
    );
    if (ok == true) onResetAndSignIn();
  }
}

extension on LoadingButton {
  /// Tightens the "Having trouble signing in? Reset" affordance to
  /// the compact 12pt subdued style used here (smaller padding, no
  /// min-size, secondary color). Lives as an extension so the main
  /// LoadingButton widget stays generic.
  Widget copyWithOverride(Color color, {double fontSize = 12}) {
    return Builder(
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final textStyle = theme.textTheme.labelLarge?.copyWith(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        );
        final effectiveOnPressed = busy ? null : onPressed;
        return TextButton(
          onPressed: effectiveOnPressed,
          style: TextButton.styleFrom(
            foregroundColor: color,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.xs,
            ),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy) ...[
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: color,
                  ),
                ),
                const SizedBox(width: 8),
                Text(busyLabel ?? label, style: textStyle),
              ] else
                Text(label, style: textStyle),
            ],
          ),
        );
      },
    );
  }
}

class _ConnectedRow extends StatelessWidget {
  const _ConnectedRow({
    required this.email,
    required this.onSignOut,
  });

  final String email;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(email, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(
                'Connected',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.success,
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onSignOut,
          child: const Text('Disconnect'),
        ),
      ],
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 36,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Couldn\'t load: $message',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
      ),
    );
  }
}
