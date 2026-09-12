import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/data_providers.dart';
import '../agent/agent_screen.dart';
import '../dashboard/dashboard_screen.dart';
import '../budgets/budgets_screen.dart';
import '../transactions/transactions_screen.dart';
import '../settings/settings_screen.dart';

/// Bottom-nav shell with five tabs: Dashboard, Budgets, Agent,
/// Transactions, Settings. The tabs live in a custom floating pill —
/// built directly from a Row of [Icon] + label pairs rather than
/// `NavigationBar`, because NavigationBar's internal layout forces a
/// taller chrome than we want for the Apple Music-style look. Content
/// scrolls under the pill; each scrollable screen adds
/// `AppSpacing.floatingBarContentPadding` to its bottom padding so the
/// last row clears the bar.
final selectedTabProvider = StateProvider<int>((ref) => 0);

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    // Refresh providers whenever the app comes back to the foreground.
    // The background FCM isolate writes to SQLite but can't reach the
    // Riverpod container in the main isolate — without this, a push
    // that arrives while the app is killed/in-background inserts the
    // row but the dashboard still shows stale numbers until the user
    // pull-to-refreshes. See main.dart:_onBackgroundEntry for the
    // matching write path.
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      invalidateDataProviders(ref);
      // Catch up on any envelopes that piled up in Firestore while
      // the phone was offline — FCM can't deliver without a live
      // connection, but the server-side envelope queue is durable.
      // Idempotent + fire-and-forget; no UI to surface errors on.
      syncGmailOnResume(ref);
    }
  }

  static const _tabs = <Widget>[
    DashboardScreen(),
    BudgetsScreen(),
    AgentScreen(),
    TransactionsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final idx = ref.watch(selectedTabProvider);
    final controller = PageController(initialPage: idx);

    void goToTab(int i) {
      ref.read(selectedTabProvider.notifier).state = i;
      controller.jumpToPage(i);
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: PageView(
              controller: controller,
              physics: const BouncingScrollPhysics(),
              onPageChanged: (i) =>
                  ref.read(selectedTabProvider.notifier).state = i,
              children: _tabs,
            ),
          ),
          Positioned(
            left: AppSpacing.sm,
            right: AppSpacing.sm,
            // Tight gap above the gesture pill — iOS-style. The
            // SafeArea below still pushes the nav bar up by the
            // system bottom inset, so on a 24 px home-indicator
            // device the nav bar bottom sits ~32 px above the very
            // bottom (8 px gap + 24 px inset).
            bottom: AppSpacing.sm,
            child: SafeArea(
              top: false,
              child: _FloatingNavBar(
                selectedIndex: idx,
                onDestinationSelected: goToTab,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavSpec {
  const _NavSpec(this.icon, this.label);
  final IconData icon;
  final String label;
}

const _navItems = <_NavSpec>[
  _NavSpec(Icons.dashboard_rounded, 'Dashboard'),
  _NavSpec(Icons.savings_rounded, 'Budgets'),
  _NavSpec(Icons.auto_awesome_rounded, 'Agent'),
  _NavSpec(Icons.receipt_long_rounded, 'Transactions'),
  _NavSpec(Icons.settings_rounded, 'Settings'),
];

/// Compact pill: 56 dp tall, true pill radius (height / 2), explicit
/// Row of icon + label so the height is exactly what we ask for (no
/// NavigationBar internal padding creeping in).
class _FloatingNavBar extends StatelessWidget {
  const _FloatingNavBar({
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = isDark ? AppColors.indigoDarkDeep : AppColors.indigo;

    return Container(
      height: 62,
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(31),
        border: Border.all(color: scheme.outlineVariant, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.35)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(31),
        child: Row(
          children: [
            for (int i = 0; i < _navItems.length; i++)
              Expanded(
                child: _NavTab(
                  item: _navItems[i],
                  selected: i == selectedIndex,
                  primary: primary,
                  inactive: scheme.onSurfaceVariant,
                  onTap: () => onDestinationSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.primary,
    required this.inactive,
    required this.onTap,
  });

  final _NavSpec item;
  final bool selected;
  final Color primary;
  final Color inactive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? primary : inactive;
    return InkWell(
      onTap: onTap,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(item.icon, size: 24, color: color),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
                letterSpacing: 0.2,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}