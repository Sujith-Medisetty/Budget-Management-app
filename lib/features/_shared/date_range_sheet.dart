import 'package:flutter/material.dart';

import '../../core/format/time_format.dart';
import '../../core/theme/app_theme.dart';

/// Result returned by [showDateRangeSheet]. Both fields are inclusive,
/// normalized to local midnight so date math is clean downstream.
typedef DateRange = ({DateTime from, DateTime to});

DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// Bottom sheet with "From" and "To" pickers. Returns null if the user
/// cancels, or a [DateRange] with `from <= to` on confirm. Tapping the
/// confirm button when `from > to` swaps the values rather than erroring,
/// so the user can recover without reopening the sheet.
Future<DateRange?> showDateRangeSheet(
  BuildContext context, {
  DateRange? initial,
  String confirmLabel = 'Export',
}) async {
  final now = DateTime.now();
  final initialFrom = initial?.from ?? DateTime(now.year, now.month, 1);
  final initialTo = initial?.to ?? now;

  DateTime from = initialFrom;
  DateTime to = initialTo;

  Future<void> pickFrom() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: from,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) from = _midnight(picked);
  }

  Future<void> pickTo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: to,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) to = _midnight(picked);
  }

  final result = await showModalBottomSheet<DateRange>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) {
      final dateFmt = TimeFormat.shortDateYear;
      return StatefulBuilder(
        builder: (ctx, setState) {
          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.lg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Select range',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(ctx)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.calendar_today_rounded,
                        size: 18,
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                    ),
                    title: const Text('From'),
                    subtitle: Text(dateFmt(from)),
                    onTap: () async {
                      await pickFrom();
                      setState(() {});
                    },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: Theme.of(ctx)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.calendar_today_rounded,
                        size: 18,
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                    ),
                    title: const Text('To'),
                    subtitle: Text(dateFmt(to)),
                    onTap: () async {
                      await pickTo();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: AppSpacing.md),
                  FilledButton(
                    onPressed: () {
                      if (from.isAfter(to)) {
                        final tmp = from;
                        from = to;
                        to = tmp;
                      }
                      Navigator.of(ctx).pop((from: from, to: to));
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );

  return result;
}
