import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/time_format.dart';
import '../../core/services/share_file.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/budget.dart';
import '../../data/services/csv_exporter.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';
import '../shell/shell_fab.dart';
import 'budget_detail_screen.dart';
import 'budget_form_screen.dart';

/// All budgets. Tap to activate; tap "Open" on the active row to view
/// its detail. Edit via the trailing icon button. The active row has a
/// distinct background + ACTIVE badge.
class BudgetsScreen extends ConsumerWidget {
  const BudgetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final budgetsAsync = ref.watch(budgetsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budgets'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => _exportCsv(context, ref),
          ),
          const ThemeToggleButton(),
        ],
      ),
      body: SafeArea(
        top: false,
        // PageView fills the Stack underneath the floating pill, so
        // without this wrap the ListView would scroll under the nav
        // bar and content would show in the gap below it. Pushing
        // the body up by the system bottom inset keeps the scroll
        // content inside the visible area.
        child: Stack(
          children: [
            budgetsAsync.when(
            data: (list) {
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 84,
                          height: 84,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: Icon(
                            Icons.savings_rounded,
                            size: 40,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          'No budgets yet',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          'Create one and Pocket will track every PayPal or '
                          'Google Pay payment — alerts fire on the thresholds '
                          'you pick.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pagePadding,
                  AppSpacing.md,
                  AppSpacing.pagePadding,
                  AppSpacing.floatingBarContentPadding,
                ),
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                itemBuilder: (_, i) => _BudgetRow(budget: list[i]),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Error: $e')),
          ),
          Positioned(
            right: AppSpacing.lg,
            bottom: AppSpacing.floatingBarContentPadding,
            child: ShellFab(
              icon: Icons.add_rounded,
              label: 'Add budget',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BudgetFormScreen()),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    final list = await ref.read(budgetRepoProvider).all();
    final csv = CsvExporter.budgets(list);
    final stamp = TimeFormat.fileStamp(DateTime.now()).substring(0, 8);
    await ShareFile.shareCsv(
      filename: 'pocket-budgets-$stamp.csv',
      csvBody: csv,
    );
  }
}

class _BudgetRow extends ConsumerWidget {
  const _BudgetRow({required this.budget});
  final Budget budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final dateFmt = TimeFormat.shortDate;
    final activeBg = theme.colorScheme.primary.withValues(alpha: 0.08);
    final inactiveBg = theme.colorScheme.surface;

    return Card(
      color: budget.active ? activeBg : inactiveBg,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () async {
              await ref.read(budgetRepoProvider).activate(budget);
              if (!context.mounted) return;
              ref.invalidate(budgetsProvider);
              ref.invalidate(activeBudgetProvider);
              ref.invalidate(budgetTransactionsProvider(budget));
              showPocketSnackBar(context, '"${budget.name}" is now active');
            },
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          theme.colorScheme.primary.withValues(alpha: 0.18),
                          theme.colorScheme.primary.withValues(alpha: 0.06),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(
                      Icons.savings_rounded,
                      color: theme.colorScheme.primary,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                budget.name,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (budget.active) ...[
                              const SizedBox(width: AppSpacing.sm),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'ACTIVE',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.primary,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                    fontSize: 9,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${budget.period.label} · ${dateFmt(budget.startDate)} – ${dateFmt(budget.endDate)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    money.format(budget.amount),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              if (budget.active)
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => BudgetDetailScreen(budget: budget),
                        ),
                      );
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 18),
                    label: const Text('Open'),
                  ),
                )
              else
                Expanded(
                  child: TextButton.icon(
                    onPressed: () async {
                      await ref.read(budgetRepoProvider).activate(budget);
                      if (!context.mounted) return;
                      ref.invalidate(budgetsProvider);
                      ref.invalidate(activeBudgetProvider);
                      showPocketSnackBar(context, '"${budget.name}" is now active');
                    },
                    icon: const Icon(
                      Icons.play_circle_outline_rounded,
                      size: 18,
                    ),
                    label: const Text('Make active'),
                  ),
                ),
              const SizedBox(
                height: 44,
                child: VerticalDivider(width: 1),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            BudgetFormScreen(existing: budget),
                      ),
                    );
                  },
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}