import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/ai_text.dart';
import '../../core/format/time_format.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/ai_log_entry.dart';
import '../../data/repositories/ai_log_store.dart';
import '../../providers/data_providers.dart';

/// Rolling 30-entry audit of every AI parse attempt. Each row shows
/// the merchant + amount when the row was kept, or the rejection
/// reason when dropped, plus a KEPT/DROPPED badge. Tap to expand for
/// the raw notification text, the full AI response, and (when
/// dropped) the exact reason. Pull to refresh; the clear button in
/// the app bar wipes the log. The list auto-refreshes every 3s while
/// the screen is mounted so an FCM-driven entry shows up without
/// needing a manual pull.
class AiLogScreen extends ConsumerStatefulWidget {
  const AiLogScreen({super.key});

  @override
  ConsumerState<AiLogScreen> createState() => _AiLogScreenState();
}

class _AiLogScreenState extends ConsumerState<AiLogScreen> {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    // Light poll so a fresh FCM-driven entry shows up without the
    // user pulling. 3s is a good trade between responsiveness and
    // SQLite load on this screen.
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      ref.invalidate(aiLogProvider);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = ref.watch(aiLogProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity log'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_rounded),
            onPressed: log.valueOrNull == null || log.valueOrNull!.isEmpty
                ? null
                : () => _copyAll(context, log.valueOrNull!),
          ),
          IconButton(
            tooltip: 'Clear log',
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: log.valueOrNull == null || log.valueOrNull!.isEmpty
                ? null
                : () => _confirmClear(context),
          ),
          const ThemeToggleButton(),
        ],
      ),
      body: log.when(
        data: (entries) => entries.isEmpty
            ? const _EmptyState()
            : RefreshIndicator(
                color: AppColors.indigo,
                onRefresh: () async {
                  ref.invalidate(aiLogProvider);
                  await ref
                      .read(aiLogProvider.future)
                      .catchError((_) => <AiLogEntry>[]);
                },
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.pagePadding,
                    AppSpacing.md,
                    AppSpacing.pagePadding,
                    AppSpacing.floatingBarContentPadding,
                  ),
                  itemCount: entries.length,
                  itemBuilder: (_, i) => Padding(
                    padding: EdgeInsets.only(
                      bottom: i == entries.length - 1
                          ? 0
                          : AppSpacing.sm,
                    ),
                    child: _LogRow(entry: entries[i]),
                  ),
                ),
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear activity log?'),
        content: const Text(
          'This wipes all 30 stored entries. New AI activity will start '
          'recording again immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await AiLogStore.clear();
      ref.invalidate(aiLogProvider);
    }
  }

  Future<void> _copyAll(BuildContext context, List<AiLogEntry> entries) async {
    final buf = StringBuffer();
    for (final e in entries) {
      buf.writeln('${e.ts.toIso8601String()}  ${e.decision.toUpperCase()}  '
          '${e.parsedMerchant ?? '-'} ${e.parsedAmount ?? ''}  '
          '(${e.package})');
      if (e.reason != null) buf.writeln('  reason: ${e.reason}');
      if (e.aiResponse != null) {
        buf.writeln('  ai: ${e.aiResponse}');
      }
      buf.writeln('  src: ${e.sourceText}');
      buf.writeln();
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Activity log copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
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
                Icons.manage_search_rounded,
                size: 40,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'No AI activity yet',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Once a PayPal, Google Pay, or Gmail payment notification '
              'arrives, you\'ll see what the model returned and whether '
              'Pocket kept or dropped it.',
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

class _LogRow extends StatefulWidget {
  const _LogRow({required this.entry});
  final AiLogEntry entry;

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = widget.entry;
    final isKept = e.isKept;
    final color = isKept ? AppColors.success : AppColors.danger;
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final time = TimeFormat.dateTime(e.ts);
    final packageLabel = e.package == 'com.google.android.gm'
        ? 'Gmail'
        : e.package.contains('paypal')
            ? 'PayPal'
            : e.package.contains('google')
                ? 'Google Pay'
                : e.package;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(
                      isKept
                          ? Icons.check_rounded
                          : Icons.close_rounded,
                      size: 20,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _Badge(text: isKept ? 'KEPT' : 'DROPPED', color: color),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Text(
                                isKept
                                    ? (e.parsedMerchant ?? '(no merchant)')
                                    : (e.reason ?? 'dropped'),
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '$time  ·  $packageLabel',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isKept && e.parsedAmount != null)
                    Text(
                      money.format(e.parsedAmount!.abs()),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: e.parsedAmount! < 0
                            ? AppColors.success
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Divider(height: 1),
                            const SizedBox(height: AppSpacing.md),
                            if (e.sourceText.isNotEmpty) ...[
                              _DetailLabel('Input'),
                              const SizedBox(height: 4),
                              _DetailBox(text: e.sourceText),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            if (e.aiResponse != null) ...[
                              _DetailLabel('AI response'),
                              const SizedBox(height: 4),
                              _DetailBox(text: e.aiResponse!, markdown: true),
                              const SizedBox(height: AppSpacing.md),
                            ],
                            if (e.reason != null) ...[
                              _DetailLabel('Reason'),
                              const SizedBox(height: 4),
                              _DetailBox(text: e.reason!),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              fontSize: 9,
            ),
      ),
    );
  }
}

class _DetailLabel extends StatelessWidget {
  const _DetailLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
    );
  }
}

class _DetailBox extends StatelessWidget {
  const _DetailBox({required this.text, this.markdown = false});
  final String text;
  final bool markdown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      // AI responses can contain markdown (lists, bold, code). Source
      // text is the raw notification body the user received, which we
      // keep monospace so it visually reads as "this is the input".
      child: markdown
          ? MarkdownText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
              padding: EdgeInsets.zero,
            )
          : SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
    );
  }
}
