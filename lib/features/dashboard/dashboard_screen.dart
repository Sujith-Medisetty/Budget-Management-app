import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/time_format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/budget.dart';
import '../../data/models/transaction.dart';
import '../../providers/data_providers.dart';
import '../budgets/budget_detail_screen.dart';
import '../budgets/budget_form_screen.dart';
import '../budgets/budgets_screen.dart';

/// Home tab: shows the single active budget with its progress and a peek
/// at the most recent activity. If there are no budgets, prompts to
/// create one. If there are budgets but none active, prompts to pick one.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeAsync = ref.watch(activeBudgetProvider);
    final allAsync = ref.watch(budgetsProvider);
    final txnsAsync = ref.watch(transactionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    AppColors.indigo,
                    AppColors.indigo.withValues(alpha: 0.7),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.account_balance_wallet_rounded,
                color: Colors.white,
                size: 16,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            const Text('Pocket'),
          ],
        ),
        actions: [
          const ThemeToggleButton(),
        ],
      ),
      body: SafeArea(
        top: false,
        // PageView fills the Stack underneath the floating pill, so
        // without this wrap scroll content would render all the way
        // down to the system bottom inset and show in the gap below
        // the nav bar. Pushing the body up by the inset keeps the
        // ListView inside the visible area — the gap then naturally
        // shows the Scaffold background, not scrollable content.
        child: RefreshIndicator(
          color: AppColors.indigo,
          onRefresh: () async {
            // Re-fetch from SQLite so the spinner hides as soon as the
            // local DB settles. The network sync is fire-and-forget so
            // a flaky server can't hang the spinner — any new envelopes
            // land via FCM or the next pull.
            invalidateDataProviders(ref);
            await ref.read(activeBudgetProvider.future).catchError((_) => null);
          },
          child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pagePadding,
            AppSpacing.sm,
            AppSpacing.pagePadding,
            AppSpacing.floatingBarContentPadding,
          ),
          children: [
            activeAsync.when(
              data: (b) {
                if (b != null) {
                  return _ActiveBudgetCard(budget: b, txnsAsync: txnsAsync);
                }
                // No active budget. Don't paint the wrong hint while
                // budgets is still resolving — fall through to the
                // skeleton. Without this the user briefly sees "No
                // budgets yet" before it snaps to "No active pick"
                // (or vice-versa) when budgetsProvider settles.
                if (allAsync.isLoading) {
                  return const _Skeleton(height: 140);
                }
                final hasBudgets =
                    allAsync.valueOrNull?.isNotEmpty ?? false;
                return hasBudgets
                    ? const _NoActivePickHint()
                    : const _NoBudgetsHint();
              },
              loading: () => const _Skeleton(height: 140),
              error: (e, _) => _ErrorTile(message: '$e'),
            ),
            const SizedBox(height: AppSpacing.sectionGap),
            txnsAsync.when(
              data: (txns) {
                if (txns.isEmpty) return const _EmptyTxnHint();
                final recent = txns.take(6).toList();
                return Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Recent activity',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          'Last ${recent.length}',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        child: Column(
                          children: [
                            for (var j = 0; j < recent.length; j++) ...[
                              _TxnRow(transaction: recent[j]),
                              if (j != recent.length - 1) const Divider(height: 1),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
              loading: () => const _Skeleton(),
              error: (e, _) => _ErrorTile(message: '$e'),
            ),
          ],
        ),
      ),
    ),
    );
  }
}

class _ActiveBudgetCard extends StatelessWidget {
  const _ActiveBudgetCard({required this.budget, required this.txnsAsync});
  final Budget budget;
  final AsyncValue<List<Transaction>> txnsAsync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
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
    final rangeLabel =
        '${TimeFormat.shortDate(start)} – ${TimeFormat.shortDate(end)}';

    return txnsAsync.maybeWhen(
      data: (txns) {
        final spent = txns
            .where(
              (t) =>
                  t.amount > 0 &&
                  !t.ignored &&
                  !t.occurredAt.isBefore(start) &&
                  !t.occurredAt.isAfter(end),
            )
            .fold<double>(0, (acc, t) => acc + t.amount);
        final rawPct = budget.amount == 0 ? 0.0 : spent / budget.amount;
        final displayPct = (rawPct * 100).clamp(0, 999).round();
        final remaining = budget.amount - spent;
        final daysLeft = _daysInclusive(now, end);
        final perDay = (daysLeft > 0 && remaining > 0)
            ? remaining / daysLeft
            : (daysLeft > 0 && remaining < 0
                ? remaining / daysLeft
                : 0.0);
        final color = _progressColor(theme, rawPct);

        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BudgetDetailScreen(budget: budget),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Header(
                    name: budget.name,
                    periodLabel: budget.period.label,
                    rangeLabel: rangeLabel,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        money.format(spent),
                        style: theme.textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          color: color,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'of ${money.format(budget.amount)} · $displayPct% used',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: rawPct.clamp(0.0, 1.0).toDouble(),
                      minHeight: 10,
                      backgroundColor: color.withValues(alpha: 0.12),
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    children: [
                      Expanded(
                        child: _StatBlock(
                          label: 'LEFT',
                          value: remaining >= 0
                              ? money.format(remaining)
                              : '-${money.format(remaining.abs())}',
                          sub: remaining >= 0 ? 'available' : 'over',
                          color: remaining < 0 ? AppColors.danger : null,
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 36,
                        color: theme.colorScheme.outlineVariant,
                      ),
                      Expanded(
                        child: _StatBlock(
                          label: 'PER DAY',
                          value: perDay == 0
                              ? '—'
                              : money.format(perDay.abs()),
                          sub: _perDaySub(perDay, daysLeft),
                          color: perDay < 0 ? AppColors.danger : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
      orElse: () => const _Skeleton(height: 180),
    );
  }

  String _perDaySub(double perDay, int daysLeft) {
    if (perDay < 0) return 'over pace';
    if (perDay == 0) {
      if (daysLeft <= 0) return 'period ended';
      return 'no budget left';
    }
    return daysLeft == 1 ? 'for 1 day' : 'for $daysLeft days';
  }

  int _daysInclusive(DateTime from, DateTime to) {
    final f = DateTime(from.year, from.month, from.day);
    final t = DateTime(to.year, to.month, to.day);
    final diff = t.difference(f).inDays;
    return diff < 0 ? 0 : diff + 1;
  }

  Color _progressColor(ThemeData theme, double pct) {
    if (pct >= 1) return AppColors.danger;
    if (pct >= 0.8) return AppColors.amber;
    return theme.colorScheme.primary;
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.name,
    required this.periodLabel,
    required this.rangeLabel,
  });
  final String name;
  final String periodLabel;
  final String rangeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.14),
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
              ),
              const SizedBox(height: 4),
              Text(
                '$periodLabel · $rangeLabel',
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
    );
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({
    required this.label,
    required this.value,
    required this.sub,
    this.color,
  });
  final String label;
  final String value;
  final String sub;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              color: fg,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _TxnRow extends StatelessWidget {
  const _TxnRow({required this.transaction});
  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
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

    return Opacity(
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
                color: isManual ? theme.colorScheme.secondary : color,
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
    );
  }
}

class _NoBudgetsHint extends StatelessWidget {
  const _NoBudgetsHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.savings_rounded,
                    color: theme.colorScheme.primary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'No budgets yet',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Create one and Pocket will track every PayPal or '
                        'Google Pay payment — alerts fire on the thresholds '
                        'you pick.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BudgetFormScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Create budget'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoActivePickHint extends StatelessWidget {
  const _NoActivePickHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.amber.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    color: AppColors.amber,
                    size: 24,
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'No active budget',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Open the Budgets tab and tap "Make active" on '
                        'whichever one you want Pocket to track right now.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BudgetsScreen(),
                  ),
                );
              },
              icon: const Icon(Icons.list_alt_rounded, size: 18),
              label: const Text('Pick a budget'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyTxnHint extends StatelessWidget {
  const _EmptyTxnHint();
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Text(
          'No transactions yet. Make a payment with PayPal or Google Pay, '
          'or tap your active budget to add a manual expense.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton({this.height = 80});
  final double height;
  @override
  Widget build(BuildContext context) => Card(
    child: SizedBox(
      height: height,
      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ),
  );
}

class _ErrorTile extends StatelessWidget {
  const _ErrorTile({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Text(
        'Something went wrong: $message',
        style: const TextStyle(color: AppColors.danger),
      ),
    ),
  );
}