import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/budget.dart';
import '../../data/services/budgets_api.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';

/// Create or edit a single budget. Pass [existing] for the edit flow —
/// it pre-fills the form and switches the save action to update.
class BudgetFormScreen extends ConsumerStatefulWidget {
  const BudgetFormScreen({super.key, this.existing});
  final Budget? existing;

  @override
  ConsumerState<BudgetFormScreen> createState() => _BudgetFormScreenState();
}

class _BudgetFormScreenState extends ConsumerState<BudgetFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late BudgetPeriod _period;
  late DateTime _customStart;
  late DateTime _customEnd;
  late bool _alertEvery;
  late Set<int> _alertThresholds;

  @override
  void initState() {
    super.initState();
    final b = widget.existing;
    _name = TextEditingController(text: b?.name ?? '');
    _amount = TextEditingController(
      text: b == null ? '' : b.amount.toStringAsFixed(2),
    );
    _period = b?.period ?? BudgetPeriod.monthly;
    _customStart = b?.startDate ?? DateTime.now();
    _customEnd = b?.endDate ?? DateTime.now().add(const Duration(days: 30));
    _alertEvery = b?.alertEvery ?? false;
    _alertThresholds = {...?b?.alertThresholds};
    if (_alertThresholds.isEmpty) _alertThresholds.addAll([80, 100]);
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _pickCustomStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customStart,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _customStart = picked;
        if (_customEnd.isBefore(_customStart)) {
          _customEnd = _customStart.add(const Duration(days: 7));
        }
      });
    }
  }

  Future<void> _pickCustomEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customEnd,
      firstDate: _customStart,
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _customEnd = picked);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_alertEvery && _alertThresholds.isEmpty) {
      showPocketSnackBar(
        context,
        'Pick at least one milestone or switch to "Every change".',
      );
      return;
    }
    final amount = double.parse(_amount.text.trim());
    final now = DateTime.now();
    final start = _period == BudgetPeriod.custom
        ? DateTime(_customStart.year, _customStart.month, _customStart.day)
        : _period.range(now).start;
    final end = _period == BudgetPeriod.custom
        ? DateTime(_customEnd.year, _customEnd.month, _customEnd.day)
        : _period.range(now).end;

    final b = widget.existing == null
        ? Budget(
            id: null,
            name: _name.text.trim(),
            amount: amount,
            period: _period,
            startDate: start,
            endDate: end,
            alertEvery: _alertEvery,
            alertThresholds: _alertThresholds.toList()..sort(),
            active: false,
            createdAt: now,
          )
        : widget.existing!.copyWith(
            name: _name.text.trim(),
            amount: amount,
            period: _period,
            startDate: start,
            endDate: end,
            alertEvery: _alertEvery,
            alertThresholds: _alertThresholds.toList()..sort(),
          );

    final repo = ref.read(budgetRepoProvider);
    if (widget.existing != null) {
      await repo.update(b);
    } else {
      final created = await repo.insert(b);
      // First budget ever? Auto-activate so the dashboard isn't dead.
      if (created != null && (await repo.all()).length == 1) {
        await repo.activate(created);
      }
    }
    // Mirror alert prefs server-side; 404 means locally-only budget.
    try {
      await BudgetsApi(auth: ref.read(gmailAuthProvider)).patchAlertPrefs(
        name: b.name,
        startDate: b.startDate,
        alertEvery: b.alertEvery,
        alertThresholds: b.alertThresholds,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[budget-form] alert-prefs sync failed: $e');
      }
    }
    ref.invalidate(budgetsProvider);
    ref.invalidate(activeBudgetProvider);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null || existing.id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DeleteBudgetDialog(
        budgetName: existing.name,
        willReactivate: existing.active,
      ),
    );
    if (ok != true) return;
    final reactivated = await ref
        .read(budgetRepoProvider)
        .deleteAndReactivateNext(existing.id!);
    ref.invalidate(budgetsProvider);
    ref.invalidate(activeBudgetProvider);
    if (!mounted) return;
    if (reactivated != null) {
      showPocketSnackBar(context, '"${reactivated.name}" is now active');
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEdit ? 'Edit budget' : 'New budget'),
        actions: [
          if (isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: _delete,
            ),
          const ThemeToggleButton(),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pagePadding,
            AppSpacing.lg,
            AppSpacing.pagePadding,
            AppSpacing.floatingBarContentPadding,
          ),
          children: [
            _SectionLabel('Details'),
            const SizedBox(height: AppSpacing.sm),
            RepaintBoundary(
              child: _DetailsCard(
                nameController: _name,
                amountController: _amount,
              ),
            ),
            const SizedBox(height: AppSpacing.sectionGap),
            _SectionLabel('Period'),
            const SizedBox(height: AppSpacing.sm),
            RepaintBoundary(
              child: _PeriodCard(
                period: _period,
                onPeriodChanged: (p) => setState(() => _period = p),
                customStart: _customStart,
                customEnd: _customEnd,
                onPickStart: _pickCustomStart,
                onPickEnd: _pickCustomEnd,
              ),
            ),
            const SizedBox(height: AppSpacing.sectionGap),
            _SectionLabel('Notify me'),
            const SizedBox(height: AppSpacing.sm),
            RepaintBoundary(
              child: _NotifyCard(
                everyChange: _alertEvery,
                thresholds: _alertThresholds,
                onEveryChanged: (v) => setState(() => _alertEvery = v),
                onThresholdToggled: (t) => setState(() {
                  if (_alertThresholds.contains(t)) {
                    _alertThresholds.remove(t);
                  } else {
                    _alertThresholds.add(t);
                    // Selecting "Over" (101) cascades to also select
                    // 50/80/100 so the user has full milestone coverage.
                    if (t == 101) {
                      for (final other in const [50, 80, 100]) {
                        _alertThresholds.add(other);
                      }
                    }
                  }
                }),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton(
              onPressed: _save,
              child: Text(isEdit ? 'Save changes' : 'Create budget'),
            ),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _DetailsCard extends StatelessWidget {
  const _DetailsCard({
    required this.nameController,
    required this.amountController,
  });
  final TextEditingController nameController;
  final TextEditingController amountController;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          children: [
            TextFormField(
              controller: nameController,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Food, Transport',
              ),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Give it a name' : null,
            ),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '\$ ',
              ),
              validator: (v) {
                final parsed = double.tryParse(v?.trim() ?? '');
                if (parsed == null || parsed <= 0) {
                  return 'Enter a positive amount';
                }
                return null;
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    required this.period,
    required this.onPeriodChanged,
    required this.customStart,
    required this.customEnd,
    required this.onPickStart,
    required this.onPickEnd,
  });
  final BudgetPeriod period;
  final ValueChanged<BudgetPeriod> onPeriodChanged;
  final DateTime customStart;
  final DateTime customEnd;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<BudgetPeriod>(
              segments: const [
                ButtonSegment(
                  value: BudgetPeriod.weekly,
                  label: Text('Weekly'),
                  icon: Icon(Icons.view_week_rounded, size: 16),
                ),
                ButtonSegment(
                  value: BudgetPeriod.monthly,
                  label: Text('Monthly'),
                  icon: Icon(Icons.calendar_view_month_rounded, size: 16),
                ),
                ButtonSegment(
                  value: BudgetPeriod.custom,
                  label: Text('Custom'),
                  icon: Icon(Icons.tune_rounded, size: 16),
                ),
              ],
              selected: {period},
              onSelectionChanged: (s) => onPeriodChanged(s.first),
            ),
            if (period == BudgetPeriod.custom) ...[
              const SizedBox(height: AppSpacing.lg),
              _DateField(
                label: 'Starts',
                value: customStart,
                onTap: onPickStart,
              ),
              const SizedBox(height: AppSpacing.md),
              _DateField(
                label: 'Ends',
                value: customEnd,
                onTap: onPickEnd,
              ),
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                child: Text(
                  '${_daysBetween(customStart, customEnd)} day budget',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  int _daysBetween(DateTime a, DateTime b) {
    final aDay = DateTime(a.year, a.month, a.day);
    final bDay = DateTime(b.year, b.month, b.day);
    return bDay.difference(aDay).inDays + 1;
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.label,
    required this.value,
    required this.onTap,
  });
  final String label;
  final DateTime value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: theme.colorScheme.outline,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatDate(value),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.calendar_today_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }
}

class _NotifyCard extends StatelessWidget {
  const _NotifyCard({
    required this.everyChange,
    required this.thresholds,
    required this.onEveryChanged,
    required this.onThresholdToggled,
  });
  final bool everyChange;
  final Set<int> thresholds;
  final ValueChanged<bool> onEveryChanged;
  final ValueChanged<int> onThresholdToggled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          children: [
            _ModeTile(
              selected: everyChange,
              icon: Icons.notifications_active_rounded,
              title: 'Every change',
              subtitle: 'Get a notification for every transaction.',
              onTap: () => onEveryChanged(!everyChange),
            ),
            const SizedBox(height: AppSpacing.sm),
            _ModeTile(
              selected: !everyChange,
              icon: Icons.flag_rounded,
              title: 'Milestones',
              subtitle: 'Pick the percentages you care about.',
              onTap: () => onEveryChanged(false),
            ),
            if (!everyChange) ...[
              const SizedBox(height: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                child: Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    for (final t in budgetAlertThresholdChoices)
                      _ThresholdChip(
                        value: t,
                        selected: thresholds.contains(t),
                        onTap: () => onThresholdToggled(t),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                child: Text(
                  'Selecting "Over" auto-enables 50%, 80% and 100%.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = selected
        ? scheme.primary.withValues(alpha: 0.10)
        : scheme.surfaceContainerLow;
    final border = selected
        ? scheme.primary.withValues(alpha: 0.6)
        : scheme.outlineVariant;
    final fg = selected ? scheme.primary : scheme.onSurface;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: border,
              width: selected ? 1.4 : 0.8,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: selected
                      ? scheme.primary.withValues(alpha: 0.16)
                      : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: fg,
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
              const SizedBox(width: AppSpacing.sm),
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? scheme.primary : scheme.outline,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThresholdChip extends StatelessWidget {
  const _ThresholdChip({
    required this.value,
    required this.selected,
    required this.onTap,
  });
  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isOver = value == 101;
    final bg = selected ? scheme.primary : scheme.surfaceContainerLow;
    final borderColor = selected
        ? Colors.transparent
        : (isOver
            ? AppColors.danger.withValues(alpha: 0.5)
            : scheme.outline);
    final fg = selected ? scheme.onPrimary : scheme.onSurface;

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: Border.all(color: borderColor, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isOver) ...[
                Icon(
                  Icons.warning_amber_rounded,
                  size: 14,
                  color: selected ? scheme.onPrimary : AppColors.danger,
                ),
                const SizedBox(width: 4),
              ],
              Text(
                budgetAlertThresholdLabel(value),
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog before deleting a budget. Single Delete action —
/// tapping outside the dialog is implicit cancel.
class _DeleteBudgetDialog extends StatelessWidget {
  const _DeleteBudgetDialog({
    required this.budgetName,
    required this.willReactivate,
  });
  final String budgetName;
  final bool willReactivate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      icon: Icon(
        Icons.delete_outline_rounded,
        size: 28,
        color: AppColors.danger,
      ),
      title: const Text('Delete this budget?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            budgetName,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            willReactivate
                ? 'It is currently active — the next budget will '
                    'automatically take its place.'
                : 'Its alert history will be removed too. '
                    'Transactions you already captured stay.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: Colors.white,
          ),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
