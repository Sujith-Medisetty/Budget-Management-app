import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/time_format.dart';
import '../../core/services/share_file.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/transaction.dart';
import '../../data/services/csv_exporter.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';
import '../_shared/date_range_sheet.dart';
import '../budgets/add_expense_sheet.dart';

/// All captured payments, grouped by date with the time of each one
/// shown so the user can line the row up against the originating
/// notification.
///
/// Multi-select delete: tap the select icon in the AppBar (or
/// long-press a row) to enter selection mode. The title bar swaps to
/// a Cancel + count + delete action; each row gets a leading
/// checkbox. Tap a row to toggle, hit Delete to remove them all.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() =>
      _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  final Set<int> _selected = {};
  bool _selectionMode = false;

  void _enterSelectionMode(int firstId) {
    setState(() {
      _selectionMode = true;
      _selected.add(firstId);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(int id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selectionMode = false;
      } else {
        _selected.add(id);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete transactions?'),
        content: Text(
          'This permanently removes $count transaction${count == 1 ? '' : 's'} '
          'from your local database. Captured entries will not return via '
          'Gmail sync because the notification_key dedup happens against '
          'the underlying message — but a new transaction created from the '
          'same email would be a fresh capture.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: AppColors.danger,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ids = _selected.toList(growable: false);
    await ref.read(transactionRepoProvider).deleteByIds(ids);
    if (!mounted) return;
    _exitSelectionMode();
    ref.invalidate(transactionsProvider);
    ref.invalidate(activeBudgetProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Deleted $count transaction${count == 1 ? '' : 's'}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final txnsAsync = ref.watch(transactionsProvider);

    return Scaffold(
      appBar: _selectionMode ? _selectionAppBar() : _defaultAppBar(),
      body: SafeArea(
        top: false,
        // PageView fills the Stack underneath the floating pill, so
        // without this wrap the ListView would scroll under the nav
        // bar and content would show in the gap below it. Pushing
        // the body up by the system bottom inset keeps the scroll
        // content inside the visible area.
        child: txnsAsync.when(
        data: (txns) {
          if (txns.isEmpty) return const _EmptyState();
          final grouped = _groupByDay(txns);
          final dayFmt = TimeFormat.dateWithDay;
          return RefreshIndicator(
            color: AppColors.indigo,
            onRefresh: () async {
              // Local DB refresh is the only thing the spinner should
              // gate on — pulling transactions out of SQLite resolves
              // in a few ms. The network sync is best-effort and runs
              // in the background so a flaky / unreachable server can't
              // leave the spinner hanging for the OS TCP timeout.
              // Any new envelopes the sync fetches land via the FCM
              // bridge pipeline, which inserts into the same table —
              // we'll pick them up on the next refresh or screen mount.
              unawaited(
                ref.read(gmailSyncProvider).fetchNew().catchError((_) => 0),
              );
              invalidateDataProviders(ref);
              await ref.read(transactionsProvider.future).catchError(
                    (_) => <Transaction>[],
                  );
            },
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.pagePadding,
                AppSpacing.md,
                AppSpacing.pagePadding,
                AppSpacing.floatingBarContentPadding,
              ),
              itemCount: grouped.length,
              itemBuilder: (_, i) {
                final group = grouped[i];
                final dayTotal = group.items
                    .where((t) =>
                        t.amount > 0 && !t.ignored && !_selected.contains(t.id))
                    .fold<double>(0, (acc, t) => acc + t.amount);
                final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
                return Padding(
                  padding: EdgeInsets.only(
                    bottom: AppSpacing.lg,
                    top: i == 0 ? 0 : AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.sm,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              dayFmt(group.day),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.4,
                                  ),
                            ),
                            Text(
                              money.format(dayTotal),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                          child: Column(
                            children: [
                              for (var j = 0; j < group.items.length; j++) ...[
                                _TxnRow(
                                  transaction: group.items[j],
                                  selectionMode: _selectionMode,
                                  selected: _selected.contains(
                                      group.items[j].id),
                                  onTap: () {
                                    if (_selectionMode) {
                                      final id = group.items[j].id;
                                      if (id != null) _toggleSelected(id);
                                    } else {
                                      _openSheet(group.items[j]);
                                    }
                                  },
                                  onLongPress: () {
                                    final id = group.items[j].id;
                                    if (id == null) return;
                                    if (_selectionMode) {
                                      _toggleSelected(id);
                                    } else {
                                      _enterSelectionMode(id);
                                    }
                                  },
                                ),
                                if (j != group.items.length - 1)
                                  const Divider(height: 1),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    ),
    );
  }

  AppBar _defaultAppBar() {
    return AppBar(
      title: const Text('Transactions'),
      actions: [
        IconButton(
          tooltip: 'Select transactions',
          icon: const Icon(Icons.checklist_rounded),
          onPressed: () => setState(() => _selectionMode = true),
        ),
        IconButton(
          tooltip: 'Export CSV',
          icon: const Icon(Icons.ios_share_rounded),
          onPressed: () => _exportCsv(context, ref),
        ),
        const ThemeToggleButton(),
      ],
    );
  }

  AppBar _selectionAppBar() {
    final count = _selected.length;
    return AppBar(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      leading: IconButton(
        tooltip: 'Cancel selection',
        icon: const Icon(Icons.close_rounded),
        onPressed: _exitSelectionMode,
      ),
      title: Text('$count selected'),
      actions: [
        IconButton(
          tooltip: 'Delete selected',
          icon: Icon(
            Icons.delete_outline_rounded,
            color: count == 0
                ? Theme.of(context).colorScheme.onSurfaceVariant
                : AppColors.danger,
          ),
          onPressed: count == 0 ? null : _deleteSelected,
        ),
      ],
    );
  }

  Future<void> _openSheet(Transaction t) async {
    final result = await openExpenseSheet(
      context: context,
      ref: ref,
      existing: t,
    );
    if (result != null) {
      ref.invalidate(transactionsProvider);
      ref.invalidate(activeBudgetProvider);
    }
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    final range = await showDateRangeSheet(context);
    if (range == null) return;
    final txns = await ref
        .read(transactionRepoProvider)
        .inRange(range.from, range.to.add(const Duration(days: 1)));
    final csv = CsvExporter.transactions(txns);
    final stamp = TimeFormat.fileStamp(DateTime.now()).substring(0, 8);
    await ShareFile.shareCsv(
      filename: 'pocket-transactions-$stamp.csv',
      csvBody: csv,
    );
  }

  List<_DayGroup> _groupByDay(List<Transaction> txns) {
    final out = <_DayGroup>[];
    DateTime? currentDay;
    for (final t in txns) {
      final local = t.occurredAt.toLocal();
      final day = DateTime(local.year, local.month, local.day);
      if (currentDay == null || day != currentDay) {
        out.add(_DayGroup(day: day, items: [t]));
        currentDay = day;
      } else {
        out.last.items.add(t);
      }
    }
    return out;
  }
}

class _DayGroup {
  _DayGroup({required this.day, required this.items});
  final DateTime day;
  final List<Transaction> items;
}

class _TxnRow extends StatelessWidget {
  const _TxnRow({
    required this.transaction,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Transaction transaction;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final time = TimeFormat.shortTime(transaction.occurredAt);
    final isSpend = transaction.amount > 0;
    final color = isSpend ? AppColors.danger : AppColors.success;
    final amountText =
        (isSpend ? '-' : '+') + money.format(transaction.amount.abs());
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
    // Highlighted when in selection mode + checked. Selected rows
    // shouldn't get the "ignored" dim — the user is actively
    // looking at them.
    final rowOpacity =
        ignored && !(selectionMode && selected) ? dimmedOpacity : 1.0;
    // Indigo tint behind selected rows so the visual state is
    // obvious at a glance (the checkbox alone is easy to miss in
    // peripheral vision when scrolling a long list).
    final rowColor = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.10)
        : null;

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        decoration: rowColor == null
            ? null
            : BoxDecoration(
                color: rowColor,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
        child: Opacity(
          opacity: rowOpacity,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(
              children: [
                if (selectionMode) ...[
                  Checkbox(
                    value: selected,
                    onChanged: (_) => onTap(),
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                ] else ...[
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
                ],
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
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                Icons.receipt_long_rounded,
                size: 40,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No transactions yet',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Connect Gmail in Settings to capture payments from your '
              'inbox. Add an AI key to turn each email into a '
              'transaction automatically.',
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
}
