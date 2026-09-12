import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/transaction.dart';
import '../../providers/providers.dart';

/// Result returned from the sheet. Either:
///   - [AddExpenseResult.insert] — a brand-new transaction to be inserted
///   - [AddExpenseResult.update] — an edit to an existing row
///   - [AddExpenseResult.delete] — the existing row should be deleted
///   - null — user dismissed without changes
sealed class AddExpenseResult {
  const AddExpenseResult();
}

class InsertExpense extends AddExpenseResult {
  const InsertExpense(this.transaction);
  final Transaction transaction;
}

class UpdateExpense extends AddExpenseResult {
  const UpdateExpense(this.transaction);
  final Transaction transaction;
}

class DeleteExpense extends AddExpenseResult {
  const DeleteExpense(this.transactionId);
  final int transactionId;
}

/// Modal bottom sheet for adding or editing an expense. Pass [existing]
/// to enter edit mode — the form pre-fills, the title changes, and a
/// Delete button appears in the header.
class AddExpenseSheet extends StatefulWidget {
  const AddExpenseSheet({super.key, this.existing});
  final Transaction? existing;

  @override
  State<AddExpenseSheet> createState() => _AddExpenseSheetState();
}

class _AddExpenseSheetState extends State<AddExpenseSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _amount;
  late final TextEditingController _merchant;
  late final TextEditingController _reason;
  late bool _isSpend;
  late bool _ignored;
  late DateTime _occurredAt;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _isSpend = e == null ? true : e.amount > 0;
    _ignored = e?.ignored ?? false;
    _amount = TextEditingController(
      text: e == null ? '' : e.amount.abs().toStringAsFixed(2),
    );
    _merchant = TextEditingController(text: e?.merchant ?? '');
    _reason = TextEditingController(text: e?.reason ?? '');
    _occurredAt = e?.occurredAt ?? DateTime.now();
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool get _isEdit => widget.existing != null;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      // Preserve the current time-of-day across date changes — picking
      // "Sep 5" shouldn't reset the time to 00:00 unless the user
      // explicitly picked a fresh time too.
      setState(() {
        _occurredAt = DateTime(
          picked.year, picked.month, picked.day,
          _occurredAt.hour, _occurredAt.minute,
        );
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (picked != null && mounted) {
      setState(() {
        _occurredAt = DateTime(
          _occurredAt.year, _occurredAt.month, _occurredAt.day,
          picked.hour, picked.minute,
        );
      });
    }
  }

  /// Resets the date and time back to the current local moment. Wired
  /// to the "Now" button on each row — users sometimes want to
  /// override an edited expense back to "just now" without having to
  /// open the picker again.
  void _resetToNow() {
    setState(() => _occurredAt = DateTime.now());
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final amount = double.parse(_amount.text.trim());
    final signedAmount = _isSpend ? amount : -amount;
    final existing = widget.existing;
    final tx = existing == null
        ? Transaction(
            id: null,
            notificationKey: '',
            source: 'manual',
            amount: signedAmount,
            merchant: _merchant.text.trim(),
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            occurredAt: _occurredAt,
          )
        : existing.copyWith(
            amount: signedAmount,
            merchant: _merchant.text.trim(),
            reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
            occurredAt: _occurredAt,
            ignored: _ignored,
          );
    Navigator.of(context).pop(
      existing == null
          ? InsertExpense(tx)
          : UpdateExpense(tx),
    );
  }

  Future<void> _confirmDelete() async {
    final existing = widget.existing;
    final id = existing?.id;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        icon: Icon(
          Icons.delete_outline_rounded,
          size: 28,
          color: AppColors.danger,
        ),
        title: const Text('Delete this entry?'),
        content: Text(
          existing!.merchant.isEmpty ? 'Manual entry' : existing.merchant,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
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
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop(DeleteExpense(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.pagePadding,
            AppSpacing.md,
            AppSpacing.pagePadding,
            AppSpacing.xl,
          ),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: AppSpacing.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _isEdit ? 'Edit expense' : 'Add expense',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (_isEdit)
                      IconButton(
                        onPressed: _confirmDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                        tooltip: 'Delete',
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: true,
                      label: Text('Spent'),
                      icon: Icon(Icons.arrow_outward_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text('Received'),
                      icon: Icon(Icons.south_west_rounded, size: 16),
                    ),
                  ],
                  selected: {_isSpend},
                  onSelectionChanged: (s) =>
                      setState(() => _isSpend = s.first),
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _amount,
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
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _merchant,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Merchant or source',
                    hintText: 'e.g. Coffee shop, Friend refund',
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Add a label' : null,
                ),
                const SizedBox(height: AppSpacing.md),
                TextFormField(
                  controller: _reason,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'e.g. for the team',
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Date',
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDate(_occurredAt),
                          style: theme.textTheme.bodyMedium,
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
                const SizedBox(height: AppSpacing.md),
                InkWell(
                  onTap: _pickTime,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Time',
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatTime(_occurredAt),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Icon(
                          Icons.schedule_rounded,
                          size: 18,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                if (!_isAtNow(_occurredAt)) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton.icon(
                      onPressed: _resetToNow,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Reset to now'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                        ),
                      ),
                    ),
                  ),
                ],
                if (_isEdit) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: SwitchListTile.adaptive(
                      value: _ignored,
                      onChanged: (v) => setState(() => _ignored = v),
                      title: const Text('Ignore from spending'),
                      subtitle: Text(
                        _ignored
                            ? 'Won\'t count toward budgets or day totals. '
                                'Stays visible (struck through).'
                            : 'Counts toward budgets and day totals.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      secondary: Icon(
                        _ignored
                            ? Icons.visibility_off_rounded
                            : Icons.visibility_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
                FilledButton(
                  onPressed: _save,
                  child: Text(_isEdit ? 'Save changes' : 'Save expense'),
                ),
              ],
            ),
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

  /// 12-hour "h:mm a" matching the rest of the app's time displays
  /// (`TimeFormat.shortTime`). Kept inline to avoid dragging
  /// `core/format/time_format.dart` into a feature that only needs
  /// the one helper.
  String _formatTime(DateTime d) {
    final h = d.hour;
    final m = d.minute.toString().padLeft(2, '0');
    final period = h < 12 ? 'AM' : 'PM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$h12:$m $period';
  }

  /// True when the picked date/time is within ±60 seconds of now. The
  /// 60-second window absorbs the seconds-precision gap (a row saved
  /// at 14:23:45 should still count as "now" when reopened at
  /// 14:24:10). Used to hide the "Reset to now" button when it would
  /// be a no-op.
  bool _isAtNow(DateTime d) {
    final delta = DateTime.now().difference(d).abs();
    return delta.inSeconds < 60;
  }
}

/// Opens the [AddExpenseSheet] for add or edit, applies the user's
/// choice to the database, and returns the result so the caller can
/// invalidate the relevant providers. Returns null if dismissed.
Future<AddExpenseResult?> openExpenseSheet({
  required BuildContext context,
  required WidgetRef ref,
  Transaction? existing,
}) async {
  final repo = ref.read(transactionRepoProvider);
  final result = await showModalBottomSheet<AddExpenseResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) => AddExpenseSheet(existing: existing),
  );
  if (result == null || !context.mounted) return null;
  switch (result) {
    case InsertExpense(:final transaction):
      await repo.insertManual(transaction);
    case UpdateExpense(:final transaction):
      await repo.update(transaction);
    case DeleteExpense(:final transactionId):
      await repo.deleteById(transactionId);
  }
  return result;
}
