import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../providers/data_providers.dart';
import '../../providers/onboarding_provider.dart';
import '../../providers/providers.dart';
import '../settings/ai_model_screen.dart';
import 'default_budget.dart';

/// First-launch guided setup. Five steps in a PageView:
///
///   1. Welcome
///   2. Gmail — connect a Google account so Pocket can read transaction
///      emails
///   3. AI model (skippable)
///   4. POST_NOTIFICATIONS permission (skippable)
///   5. Done — auto-creates the default "[Month] Expenses" budget
///
/// Every setup step is optional. The bottom button advances one page
/// at a time — "Skip for now" skips *that step*, never the whole
/// wizard — so the user always sees what they're turning down.
///
/// Each step's copy states the benefit AND the drawback of skipping
/// so the user can make an informed choice instead of just tapping
/// through.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_index < _kStepCount - 1) {
      await _controller.nextPage(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    await _finish();
  }

  Future<void> _finish() async {
    // Create the default budget so the dashboard isn't dead on first
    // open. Idempotent — no-op if a budget already exists.
    await ensureDefaultBudget(ref.read(budgetRepoProvider));
    await markOnboardingCompleted();
    ref.invalidate(onboardingCompletedProvider);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Watch the three completion signals here so the bottom bar can
    // switch its label from "Skip for now" to "Next" the moment any
    // step is done. The per-page buttons already do this on the page
    // itself; the bottom bar used to ignore the state and made the
    // user think they still had to skip.
    final gmailConnected =
        ref.watch(gmailConnectedProvider).valueOrNull != null;
    final hasAiKey = ref.watch(aiConfigProvider).maybeWhen(
          data: (c) => c.hasKey,
          orElse: () => false,
        );
    // Notification permission is async — `_granted` lives inside the
    // page widget because it needs a one-shot refresh on mount. The
    // page exposes it via a provider so we can read it here too.
    final notifGranted = ref.watch(_notifGrantedProvider);
    final stepDone = switch (_index) {
      1 => gmailConnected,
      2 => hasAiKey,
      3 => notifGranted,
      _ => false,
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Welcome'),
        actions: const [ThemeToggleButton()],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: AppSpacing.md),
            _ProgressDots(
              count: _kStepCount,
              current: _index,
              color: scheme.primary,
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                physics: const BouncingScrollPhysics(),
                onPageChanged: (i) => setState(() => _index = i),
                children: const [
                  _WelcomePage(),
                  _GmailPage(),
                  _AIPage(),
                  _BudgetAlertsPage(),
                  _AllSetPage(),
                ],
              ),
            ),
            _BottomBar(
              index: _index,
              onPrimary: _next,
              stepDone: stepDone,
            ),
          ],
        ),
      ),
    );
  }
}

/// Mirror of the `_granted` flag inside `_BudgetAlertsPageState`, lifted
/// into a provider so the parent `OnboardingScreen` can read it without
/// owning the lifecycle (the page widget still does the actual
/// `requestPermission` call + one-shot refresh on mount).
final _notifGrantedProvider = StateProvider<bool>((_) => false);

const _kStepCount = 5;

class _ProgressDots extends StatelessWidget {
  const _ProgressDots({
    required this.count,
    required this.current,
    required this.color,
  });
  final int count;
  final int current;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final isCurrent = i == current;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 6,
          width: isCurrent ? 22 : 6,
          decoration: BoxDecoration(
            color: isCurrent
                ? color
                : Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.index,
    required this.onPrimary,
    required this.stepDone,
  });
  final int index;
  final VoidCallback onPrimary;
  final bool stepDone;

  @override
  Widget build(BuildContext context) {
    // Three buckets:
    //   - first page → "Get started"
    //   - last page  → "Open Dashboard"
    //   - middle page + step done   → "Next"
    //   - middle page + step not done → "Skip for now"
    final String label;
    final String? hint;
    if (index == 0) {
      label = 'Get started';
      hint = null;
    } else if (index == _kStepCount - 1) {
      label = 'Open Dashboard';
      hint = null;
    } else if (stepDone) {
      label = 'Next';
      hint = 'Step done — move on to the next one.';
    } else {
      label = 'Skip for now';
      hint = 'Skips this step only — you can set it up later in Settings.';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.md,
        AppSpacing.pagePadding,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(onPressed: onPrimary, child: Text(label)),
          if (hint != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shared scaffold for the four setup pages — hero icon, title, body
/// (with a benefit line and a drawback line), then a per-page action.
class _OnboardingScaffold extends StatelessWidget {
  const _OnboardingScaffold({
    required this.icon,
    required this.title,
    required this.benefit,
    required this.drawback,
    this.actionLabel,
    this.onAction,
    this.child,
  }) : assert(
          (actionLabel != null && onAction != null) || child != null,
          'Provide either actionLabel+onAction, or a child widget',
        );

  final IconData icon;
  final String title;
  final String benefit;
  final String drawback;

  /// Default action button — an outlined button with this label. Used
  /// by every step except Gmail sign-in, which swaps in a richer
  /// LoadingButton via [child].
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Custom action slot. Takes precedence over [actionLabel]/[onAction]
  /// when supplied.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.xxl,
        AppSpacing.pagePadding,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: Icon(icon, color: scheme.primary, size: 32),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(title, style: theme.textTheme.headlineMedium),
          const SizedBox(height: AppSpacing.lg),
          _Bullet(
            icon: Icons.check_circle_rounded,
            color: AppColors.success,
            text: benefit,
          ),
          const SizedBox(height: AppSpacing.md),
          _Bullet(
            icon: Icons.info_outline_rounded,
            color: scheme.onSurfaceVariant,
            text: drawback,
          ),
          const SizedBox(height: AppSpacing.xxl),
          if (child != null)
            child!
          else
            OutlinedButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 18),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.xxl,
        AppSpacing.pagePadding,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: const Icon(
              Icons.savings_rounded,
              color: Colors.white,
              size: 36,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Welcome to Pocket', style: theme.textTheme.displayMedium),
          const SizedBox(height: AppSpacing.md),
          Text(
            'A budget app that reads your alerts — payment apps, emails, '
            'bank apps, anything that tells you money moved. Never your '
            'bank login, never your account password.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          const _WelcomeRow(
            icon: Icons.notifications_active_rounded,
            title: 'Automatic',
            body: 'Transactions appear when an alert from an app you '
                'enabled fires.',
          ),
          const SizedBox(height: AppSpacing.lg),
          const _WelcomeRow(
            icon: Icons.lock_outline_rounded,
            title: 'Private',
            body: 'AI parsing runs on your key. Nothing leaves your '
                'phone without a tap.',
          ),
          const SizedBox(height: AppSpacing.lg),
          const _WelcomeRow(
            icon: Icons.tune_rounded,
            title: 'Adjustable',
            body: 'Every choice below can be changed later in Settings.',
          ),
        ],
      ),
    );
  }
}

class _WelcomeRow extends StatelessWidget {
  const _WelcomeRow({
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Icon(icon, color: scheme.primary, size: 18),
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
              const SizedBox(height: 2),
              Text(
                body,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GmailPage extends ConsumerStatefulWidget {
  const _GmailPage();

  @override
  ConsumerState<_GmailPage> createState() => _GmailPageState();
}

class _GmailPageState extends ConsumerState<_GmailPage> {
  bool _busy = false;

  Future<void> _signIn() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(gmailAuthProvider).signIn();
      // Auto-restore the cloud snapshot so the freshly-connected
      // device matches the user's authoritative state. First-time
      // sign-ins return "No backup found" — silently ignored.
      await autoRestoreAfterSignIn(ref);
      ref.invalidate(gmailConnectedProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_gmailSignInError(e)),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = ref.watch(gmailConnectedProvider).valueOrNull;
    final connected = email != null;
    if (connected) {
      return const _OnboardingScaffold(
        icon: Icons.mail_rounded,
        title: 'Connect Gmail?',
        benefit: 'Capture transactions from any Gmail message — even ones '
            'Gmail doesn\'t notify you about (Promotions, Updates, batched '
            'alerts). Pocket fetches each email via Google\'s API and runs '
            'it through your AI parser on-device.',
        drawback: 'Google sees that Pocket accessed your mailbox. We '
            'extract the body, parse it on your phone, then drop it. '
            'Nothing is sent anywhere else.',
        actionLabel: 'Connected ✓',
        onAction: _noop,
      );
    }
    return _OnboardingScaffold(
      icon: Icons.mail_rounded,
      title: 'Connect Gmail?',
      benefit: 'Capture transactions from any Gmail message — even ones '
          'Gmail doesn\'t notify you about (Promotions, Updates, batched '
          'alerts). Pocket fetches each email via Google\'s API and runs '
          'it through your AI parser on-device.',
      drawback: 'Google sees that Pocket accessed your mailbox. We '
          'extract the body, parse it on your phone, then drop it. '
          'Nothing is sent anywhere else.',
      child: LoadingButton.filled(
        label: 'Sign in with Google',
        busyLabel: 'Opening Google…',
        icon: Icons.login_rounded,
        busy: _busy,
        onPressed: _signIn,
      ),
    );
  }
}

void _noop() {}

/// Translates raw exceptions into user-friendly copy for the
/// onboarding sign-in flow. Kept in sync with the same helper in
/// ConnectedAccountsScreen — when you edit one, update both.
String _gmailSignInError(Object e) {
  final s = e.toString();
  if (s.contains('providerConfigurationError') ||
      s.contains('clientConfigurationError') ||
      s.contains('unknownError')) {
    return "Google's sign-in is having trouble. "
        'Close the app fully and try again.';
  }
  if (s.contains('canceled')) {
    return 'Sign-in cancelled.';
  }
  if (s.contains('networkError') || s.contains('SocketException')) {
    return 'No internet connection. Check Wi-Fi or data and try again.';
  }
  if (s.contains('oauth/exchange failed')) {
    return "Couldn't reach the server. Try again in a moment.";
  }
  return 'Sign-in failed. Please try again.';
}

class _AIPage extends ConsumerWidget {
  const _AIPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasKey = ref.watch(aiConfigProvider).maybeWhen(
          data: (c) => c.hasKey,
          orElse: () => false,
        );
    return _OnboardingScaffold(
      icon: Icons.psychology_rounded,
      title: 'Add an AI key?',
      benefit: 'AI parses alerts from any source — including messy '
          'emails, bank notifications, and unusual merchant names. '
          'Everything runs on your phone; your key never leaves the device.',
      drawback: 'Without a key, notifications come in but never become '
          'transactions. You can still add expenses manually.',
      actionLabel: hasKey ? 'AI key saved ✓' : 'Set up AI',
      onAction: () {
        if (hasKey) return;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const AiModelScreen()),
        );
      },
    );
  }
}

class _BudgetAlertsPage extends ConsumerStatefulWidget {
  const _BudgetAlertsPage();

  @override
  ConsumerState<_BudgetAlertsPage> createState() => _BudgetAlertsPageState();
}

class _BudgetAlertsPageState extends ConsumerState<_BudgetAlertsPage> {
  bool _busy = false;
  bool? _granted;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final enabled =
        await ref.read(notificationServiceProvider).areNotificationsEnabled();
    if (!mounted) return;
    setState(() => _granted = enabled);
    // Mirror the result into the top-level provider so the bottom bar
    // can flip its label from "Skip for now" to "Next" the moment the
    // user grants (or has already granted) the permission.
    ref.read(_notifGrantedProvider.notifier).state = enabled;
  }

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      // requestPermission() triggers the Android 13+ prompt. Safe to
      // call even when init() has already run during app boot —
      // otherwise this step would no-op and the user couldn't grant
      // permission from the onboarding screen.
      await ref.read(notificationServiceProvider).requestPermission();
      await _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final granted = _granted ?? false;
    final label = _busy
        ? 'Requesting…'
        : granted
            ? 'Allowed ✓'
            : 'Allow notifications';
    return _OnboardingScaffold(
      icon: Icons.notifications_rounded,
      title: 'Budget alerts?',
      benefit: 'Pocket pings you based on what you set per budget: '
          'notify on every transaction, or only when spending crosses '
          'thresholds you pick (50% / 80% / 100% / over budget).',
      drawback: 'You\'ll have to open the app to check your budget '
          'status. Adjust per budget anytime in the Budgets tab.',
      actionLabel: label,
      onAction: granted || _busy ? () {} : _request,
    );
  }
}

class _AllSetPage extends StatelessWidget {
  const _AllSetPage();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.pagePadding,
        AppSpacing.xxl,
        AppSpacing.pagePadding,
        AppSpacing.xxl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.xl),
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              color: AppColors.success,
              size: 36,
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text("You're all set", style: theme.textTheme.displayMedium),
          const SizedBox(height: AppSpacing.md),
          Text(
            'To make the app useful right away, we create a default '
            'budget so the dashboard is alive. Rename it, change the '
            'amount, or swap the period anytime — your call.',
            style: theme.textTheme.bodyLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          const _Bullet(
            icon: Icons.bookmark_added_rounded,
            color: AppColors.success,
            text: 'A monthly budget named "[current month] Expenses" '
                'starts at \$500 with alerts at 80% and 100%.',
          ),
          const SizedBox(height: AppSpacing.md),
          _Bullet(
            icon: Icons.swap_horiz_rounded,
            color: scheme.primary,
            text: 'Activate other budgets, change the name, or delete '
                'it from the Budgets tab — Pocket always keeps exactly '
                'one budget active.',
          ),
        ],
      ),
    );
  }
}
