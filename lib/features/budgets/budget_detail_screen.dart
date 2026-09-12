import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/time_format.dart';
import '../../core/services/share_file.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/budget.dart';
import '../../data/models/transaction.dart';
import '../../data/services/csv_exporter.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';
import '../shell/shell_fab.dart';
import 'add_expense_sheet.dart';

/// Opens when the user taps the active budget card on the dashboard.
/// Shows the current period's range, total spent, and every transaction
/// (auto-captured + manual). Floating action button opens
/// [AddExpenseSheet] for a manual entry.
class BudgetDetailScreen extends ConsumerWidget {
  const BudgetDetailScreen({super.key, required this.budget});
  final Budget budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final txnsAsync = ref.watch(budgetTransactionsProvider(budget));
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Budget'),
        actions: [
          IconButton(
            tooltip: 'Export CSV',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => _exportCsv(context, ref),
          ),
          const ThemeToggleButton(),
        ],
      ),
      body: Stack(
        children: [
          txnsAsync.when(
        data: (txns) {
          final now = DateTime.now();
          final range = budget.period.range(
            now,
            customRange: (start: budget.startDate, end: budget.endDate),
          );
          final start = budget.startDate.isAfter(range.start)
              ? budget.startDate
              : range.start;
          final end = budget.endDate.isBefore(range.end)
              ? budget.endDate
              : range.end;
          final spent = txns
              .where((t) => t.amount > 0 && !t.ignored)
              .fold<double>(0, (acc, t) => acc + t.amount);
          final pct = budget.amount == 0
              ? 0.0
              : (spent / budget.amount).clamp(0.0, 2.0);
          final color = _progressColor(theme, pct);

          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pagePadding,
                  AppSpacing.sm,
                  AppSpacing.pagePadding,
                  AppSpacing.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: _Header(
                    budget: budget,
                    spent: spent,
                    pct: pct,
                    color: color,
                    money: money,
                    rangeLabel:
                        '${TimeFormat.shortDate(start)} – ${TimeFormat.shortDate(end)}',
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.pagePadding,
                  AppSpacing.md,
                  AppSpacing.pagePadding,
                  AppSpacing.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Activity',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        '${txns.length} entries',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (txns.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyState(),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pagePadding,
                    0,
                    AppSpacing.pagePadding,
                    AppSpacing.floatingBarContentPadding,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        child: Column(
                          children: [
                            for (var j = 0; j < txns.length; j++) ...[
                              _TxnRow(transaction: txns[j], budget: budget),
                              if (j != txns.length - 1)
                                const Divider(height: 1),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
          ),
          Positioned(
            right: AppSpacing.lg,
            bottom: AppSpacing.xxxl,
            child: ShellFab(
              icon: Icons.add_rounded,
              label: 'Add expense',
              onPressed: () => _addExpense(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final range = budget.period.range(
      now,
      customRange: (start: budget.startDate, end: budget.endDate),
    );
    final start = budget.startDate.isAfter(range.start)
        ? budget.startDate
        : range.start;
    final end = budget.endDate.isBefore(range.end) ? budget.endDate : range.end;
    final txns = await ref
        .read(transactionRepoProvider)
        .inRange(start, end.add(const Duration(days: 1)));
    final csv = CsvExporter.transactions(txns);
    final stamp = TimeFormat.fileStamp(DateTime.now()).substring(0, 8);
    await ShareFile.shareCsv(
      filename: 'pocket-${budget.name.toLowerCase().replaceAll(RegExp(r"\s+"), "-")}-$stamp.csv',
      csvBody: csv,
    );
  }

  Future<void> _addExpense(BuildContext context, WidgetRef ref) async {
    final result = await openExpenseSheet(
      context: context,
      ref: ref,
      existing: null,
    );
    if (result != null) {
      ref.invalidate(budgetTransactionsProvider(budget));
      ref.invalidate(transactionsProvider);
    }
  }

  Color _progressColor(ThemeData theme, double pct) {
    if (pct >= 1) return AppColors.danger;
    if (pct >= 0.8) return AppColors.amber;
    return theme.colorScheme.primary;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.budget,
    required this.spent,
    required this.pct,
    required this.color,
    required this.money,
    required this.rangeLabel,
  });
  final Budget budget;
  final double spent;
  final double pct;
  final Color color;
  final NumberFormat money;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = budget.amount - spent;
    final remainingLabel = remaining >= 0
        ? '${money.format(remaining)} left'
        : '${money.format(remaining.abs())} over';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.14),
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
                      Text(
                        budget.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${budget.period.label} · $rangeLabel',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              money.format(spent),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -0.4,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'of ${money.format(budget.amount)} · $remainingLabel',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: pct.clamp(0.0, 1.0).toDouble(),
                minHeight: 10,
                backgroundColor: color.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TxnRow extends ConsumerWidget {
  const _TxnRow({required this.transaction, required this.budget});
  final Transaction transaction;
  final Budget budget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final time = TimeFormat.shortTime(transaction.occurredAt);
    final isSpend = transaction.amount > 0;
    final color = isSpend ? AppColors.danger : AppColors.success;
    final amountText = (isSpend ? '-' : '+') +
        money.format(transaction.amount.abs());

    final isManual = transaction.source == 'manual';
    final sourceLabel = Transaction.labelFor(transaction.source);

    final merchantLabel = transaction.merchant.isEmpty
        ? sourceLabel
        : transaction.merchant;
    final ignored = transaction.ignored;
    final strike = TextStyle(
      decoration: ignored ? TextDecoration.lineThrough : null,
      decorationColor: theme.colorScheme.onSurfaceVariant,
    );
    final dimmedOpacity = ignored ? 0.55 : 1.0;

    return InkWell(
      onTap: () async {
        final result = await openExpenseSheet(
          context: context,
          ref: ref,
          existing: transaction,
        );
        if (result != null) {
          ref.invalidate(budgetTransactionsProvider(budget));
          ref.invalidate(transactionsProvider);
        }
      },
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Opacity(
        opacity: dimmedOpacity,
        child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: isManual
                    ? theme.colorScheme.secondary.withValues(alpha: 0.14)
                    : (isSpend
                        ? AppColors.danger.withValues(alpha: 0.10)
                        : AppColors.success.withValues(alpha: 0.10)),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                isManual
                    ? Icons.edit_note_rounded
                    : (isSpend
                        ? Icons.arrow_outward_rounded
                        : Icons.south_west_rounded),
                size: 18,
                color: isManual
                    ? theme.colorScheme.secondary
                    : color,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    merchantLabel,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ).merge(strike),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    transaction.reason != null
                        ? '${transaction.reason} · $sourceLabel'
                        : sourceLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ).merge(strike),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  amountText,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ).merge(strike),
                ),
                const SizedBox(height: 2),
                Text(
                  time,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ).merge(strike),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_rounded,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Nothing in this period yet',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Tap "Add expense" to log something, or make a PayPal / '
              'Google Pay payment.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}