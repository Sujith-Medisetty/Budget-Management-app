import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format/ai_text.dart';
import '../../core/format/time_format.dart';
import '../../core/services/share_file.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/agent_message.dart';
import '../../data/models/agent_response.dart';
import '../../data/models/ai_config.dart';
import '../../data/models/budget.dart';
import '../../data/models/transaction.dart';
import '../../data/repositories/ai_log_store.dart';
import '../../data/services/csv_exporter.dart';
import '../../data/services/fact_ledger.dart';
import '../../data/services/gmail_filter_rules.dart';
import '../../features/settings/ai_model_screen.dart';
import '../../providers/agent_providers.dart';
import '../../providers/backup_provider.dart';
import '../../providers/data_providers.dart';
import '../../providers/providers.dart';

/// Renders any [AgentResponse] inline in the chat. Picks the right
/// widget based on the runtime type — keeps the chat list dumb.
class AgentResponseBubble extends ConsumerWidget {
  const AgentResponseBubble({
    super.key,
    required this.response,
    required this.index,
    required this.actionConfirmed,
  });

  final AgentResponse response;
  final int index;
  final AgentActionStatus? actionConfirmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final text = response.text.trim();

    // Actions render the AI's prose INSIDE the action card so the
    // description and the confirm UI read as one thing. Everything else
    // shows the text as a regular chat bubble above the widget.
    if (response is AgentAction) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pagePadding,
          vertical: AppSpacing.xs,
        ),
        child: _ActionWidget(
          action: response as AgentAction,
          index: index,
          status: actionConfirmed,
        ),
      );
    }
    if (response is AgentActionPlan) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pagePadding,
          vertical: AppSpacing.xs,
        ),
        child: _PlanWidget(
          plan: response as AgentActionPlan,
          index: index,
          status: actionConfirmed,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.pagePadding,
        vertical: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (text.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: MarkdownText(
                text,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          if (text.isNotEmpty) const SizedBox(height: AppSpacing.sm),
          switch (response) {
            AgentChart r => _ChartWidget(chart: r),
            AgentTable r => _TableWidget(table: r),
            AgentClarify() => const SizedBox.shrink(),
            AgentAnswer() => const SizedBox.shrink(),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

class _ChartWidget extends StatelessWidget {
  const _ChartWidget({required this.chart});
  final AgentChart chart;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (chart.buckets.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: SizedBox(
          height: 200,
          child: switch (chart.chartKind) {
            AgentChartKind.pie => _pie(theme),
            AgentChartKind.line => _line(theme),
            AgentChartKind.bar => _bar(theme),
          },
        ),
      ),
    );
  }

  Widget _bar(ThemeData theme) {
    final maxVal = chart.buckets
        .map((b) => b.value)
        .fold<double>(0, (a, b) => a > b ? a : b);
    final primary = theme.brightness == Brightness.dark
        ? AppColors.indigoDark
        : AppColors.indigo;

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxVal <= 0 ? 1 : maxVal * 1.15,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                '\$${v.toStringAsFixed(0)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= chart.buckets.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    chart.buckets[i].label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: [
          for (int i = 0; i < chart.buckets.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: chart.buckets[i].value,
                  color: primary,
                  width: 12,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(4),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _line(ThemeData theme) {
    final maxVal = chart.buckets
        .map((b) => b.value)
        .fold<double>(0, (a, b) => a > b ? a : b);
    final primary = theme.brightness == Brightness.dark
        ? AppColors.indigoDark
        : AppColors.indigo;
    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxVal <= 0 ? 1 : maxVal * 1.15,
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (v, _) => Text(
                '\$${v.toStringAsFixed(0)}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= chart.buckets.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    chart.buckets[i].label,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (int i = 0; i < chart.buckets.length; i++)
                FlSpot(i.toDouble(), chart.buckets[i].value),
            ],
            isCurved: true,
            color: primary,
            barWidth: 2.5,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pie(ThemeData theme) {
    final palette = [
      theme.colorScheme.primary,
      theme.colorScheme.secondary,
      AppColors.success,
      AppColors.amber,
      AppColors.danger,
      AppColors.indigoDark,
    ];
    final total = chart.buckets
        .map((b) => b.value)
        .fold<double>(0, (a, b) => a + b);
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: 32,
              sections: [
                for (int i = 0; i < chart.buckets.length; i++)
                  PieChartSectionData(
                    color: palette[i % palette.length],
                    value: chart.buckets[i].value,
                    title: total > 0
                        ? '${(chart.buckets[i].value / total * 100).round()}%'
                        : '',
                    titleStyle: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                    radius: 38,
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (int i = 0; i < chart.buckets.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: palette[i % palette.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          chart.buckets[i].label,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TableWidget extends StatelessWidget {
  const _TableWidget({required this.table});
  final AgentTable table;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final money = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (table.columns.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    for (int i = 0; i < table.columns.length; i++)
                      Expanded(
                        flex: i == 0 ? 2 : 1,
                        child: Text(
                          table.columns[i],
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (table.columns.isNotEmpty)
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
            for (int r = 0; r < table.rows.length; r++) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Row(
                  children: [
                    for (int i = 0; i < table.rows[r].length; i++)
                      Expanded(
                        flex: i == 0 ? 2 : 1,
                        child: Text(
                          _formatCell(table.columns, i, table.rows[r][i], money),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (r != table.rows.length - 1)
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
            ],
          ],
        ),
      ),
    );
  }

  String _formatCell(
    List<String> cols,
    int col,
    String raw,
    NumberFormat money,
  ) {
    if (raw.isEmpty) return '';
    // Format as money only when the COLUMN HEADER explicitly looks
    // like money (amount / cost / spent / MTD / fee / price / revenue /
    // USD / € / £, or the bare word "total"). Position alone (col > 0)
    // is wrong: tables like the GCP infra snapshot have a "Total
    // services" or "Services in use" column whose values are integers
    // and must NOT pick up a "$" prefix.
    final header = col < cols.length ? cols[col].toLowerCase().trim() : '';
    final looksMoney = header == 'total' ||
        RegExp(
          r'amount|cost|price|spent|fee|charge|revenue|mtd|usd|eur|gbp|\$|€|£',
        ).hasMatch(header);
    if (looksMoney) {
      final v = double.tryParse(raw);
      if (v != null) return money.format(v);
    }
    return raw;
  }
}

class _ActionWidget extends ConsumerStatefulWidget {
  const _ActionWidget({
    required this.action,
    required this.index,
    required this.status,
  });

  final AgentAction action;
  final int index;
  final AgentActionStatus? status;

  @override
  ConsumerState<_ActionWidget> createState() => _ActionWidgetState();
}

class _ActionWidgetState extends ConsumerState<_ActionWidget> {
  bool _busy = false;
  String? _result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = widget.status;
    final spec = widget.action.action;
    final description = widget.action.body.trim();
    final fallback = description.isEmpty ? _iconFallback(spec.name) : description;

    if (status == AgentActionStatus.confirmed || _result != null) {
      return _CompactCard(
        accent: AppColors.success,
        icon: Icons.check_rounded,
        text: _result ?? fallback,
        subtle: _result == null,
      );
    }
    if (status == AgentActionStatus.cancelled) {
      return _CompactCard(
        accent: theme.colorScheme.outline,
        icon: Icons.close_rounded,
        text: fallback,
        subtle: true,
        strikethrough: true,
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.sm,
          AppSpacing.xs,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 4, right: 6),
                  child: Icon(
                    _iconFor(spec.name),
                    size: 14,
                    color: theme.colorScheme.primary,
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: MarkdownText(
                      fallback,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => ref
                      .read(agentConversationProvider.notifier)
                      .setActionStatus(
                        widget.index,
                        AgentActionStatus.cancelled,
                      ),
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            _detailStrip(spec: spec),
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Align(
                alignment: Alignment.centerRight,
                child: _PillButton(
                  label: 'Confirm',
                  busy: _busy,
                  onPressed: _confirm,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String name) => switch (name) {
    'create_budget' || 'update_budget' || 'set_active_budget' =>
      Icons.savings_rounded,
    'delete_budget' => Icons.delete_outline_rounded,
    'create_expense' || 'update_transaction' => Icons.receipt_long_rounded,
    'delete_expense' || 'delete_transaction' => Icons.delete_outline_rounded,
    'bulk_delete_transactions' => Icons.delete_sweep_rounded,
    'set_ignored' => Icons.visibility_off_rounded,
    'clear_ai_log' || 'delete_activity_log_entry' =>
      Icons.delete_sweep_rounded,
    'export_csv' => Icons.ios_share_rounded,
    'update_ai_config' => Icons.auto_awesome_rounded,
    'manage_ai_api_key' => Icons.key_rounded,
    'add_filter_rule' ||
    'update_filter_rule' =>
      Icons.rule_rounded,
    'delete_filter_rule' => Icons.rule_rounded,
    'set_filter_mode' => Icons.tune_rounded,
    'replace_filter_rules' => Icons.rule_rounded,
    'sync_gmail_now' => Icons.sync_rounded,
    'disconnect_gmail' => Icons.logout_rounded,
    'sign_in_gmail' => Icons.login_rounded,
    'reset_gmail_signin' => Icons.restart_alt_rounded,
    'request_notification_permission' => Icons.notifications_active_rounded,
    'update_backup_preferences' => Icons.cloud_sync_rounded,
    'backup_now' => Icons.cloud_upload_rounded,
    'restore_now' => Icons.cloud_download_rounded,
    _ => Icons.auto_awesome_rounded,
  };

  String _iconFallback(String name) => switch (name) {
    'create_budget' => 'Create a new budget',
    'update_budget' => 'Update a budget',
    'delete_budget' => 'Delete a budget',
    'set_active_budget' => 'Switch active budget',
    'create_expense' => 'Add an expense',
    'update_transaction' => 'Update a transaction',
    'delete_expense' => 'Delete an expense',
    'delete_transaction' => 'Delete a transaction',
    'bulk_delete_transactions' => 'Bulk-delete transactions',
    'set_ignored' => 'Ignore from spending',
    'clear_ai_log' => 'Clear the activity log',
    'delete_activity_log_entry' => 'Delete an activity log entry',
    'export_csv' => 'Export a CSV',
    'update_ai_config' => 'Update AI settings',
    'manage_ai_api_key' => 'Open AI model settings',
    'add_filter_rule' => 'Add a Gmail filter rule',
    'update_filter_rule' => 'Update a Gmail filter rule',
    'delete_filter_rule' => 'Delete a Gmail filter rule',
    'set_filter_mode' => 'Update Gmail filter mode',
    'replace_filter_rules' => 'Replace all Gmail filter rules',
    'sync_gmail_now' => 'Sync Gmail now',
    'disconnect_gmail' => 'Disconnect Gmail',
    'sign_in_gmail' => 'Sign in with Google',
    'reset_gmail_signin' => 'Reset Google sign-in',
    'request_notification_permission' => 'Enable notifications',
    'update_backup_preferences' => 'Update backup settings',
    'backup_now' => 'Back up now',
    'restore_now' => 'Restore from cloud',
    _ => 'Confirm action',
  };

  /// Verbs that, after the user taps Confirm on the action card, get a
  /// SECOND modal asking them to type-confirm before anything runs.
  /// Matches the [DESTRUCTIVE] tags in the system prompt — keep them
  /// in sync when adding a new verb.
  static const _destructiveVerbs = {
    'delete_budget',
    'delete_expense',
    'delete_transaction',
    'bulk_delete_transactions',
    'clear_ai_log',
    'delete_activity_log_entry',
    'replace_filter_rules',
    'disconnect_gmail',
    'reset_gmail_signin',
    'restore_now',
  };

  /// Subtle row of small chips for the actually-present params. Empty if
  /// the AI already named everything in the prose [description].
  Widget _detailStrip({required AgentActionSpec spec}) {
    final p = spec.params;
    final chips = <_Chip>[];

    void addIfPresent(String key, String label) {
      if (p.containsKey(key)) chips.add(_Chip(label: '$key · $label'));
    }

    switch (spec.name) {
      case 'create_budget':
        addIfPresent('period', (p['period'] as String?) ?? '');
        addIfPresent('start_date', (p['start_date'] as String?) ?? '');
        addIfPresent('end_date', (p['end_date'] as String?) ?? '');
      case 'update_budget':
        final updates = (p['updates'] as Map<String, Object?>?) ?? const {};
        for (final entry in updates.entries) {
          chips.add(_Chip(
            label: '${entry.key} · ${_stringify(entry.value)}',
          ));
        }
      case 'set_active_budget':
        addIfPresent('name', (p['name'] as String?) ?? '');
      case 'create_expense':
        if ((p['kind'] as String?) == 'refund') {
          chips.add(const _Chip(label: 'kind · refund'));
        }
        if (p['reason'] is String && (p['reason'] as String).isNotEmpty) {
          chips.add(_Chip(label: 'reason · ${p['reason']}'));
        }
        if (p['occurred_at'] is String) {
          final parsed = _parseOccurredAt(p['occurred_at'] as String?);
          if (parsed != null) {
            chips.add(_Chip(label: 'at · ${TimeFormat.dateTime(parsed)}'));
          }
        }
      case 'update_transaction':
        final updates = (p['updates'] as Map<String, Object?>?) ?? const {};
        for (final entry in updates.entries) {
          if (entry.key == 'occurred_at') {
            final parsed = _parseOccurredAt(entry.value as String?);
            if (parsed != null) {
              chips.add(_Chip(label: 'at · ${TimeFormat.dateTime(parsed)}'));
              continue;
            }
          }
          chips.add(_Chip(
            label: '${entry.key} · ${_stringify(entry.value)}',
          ));
        }
        final match = p['match'] as Map<String, Object?>?;
        if (match != null) {
          if (match.containsKey('id')) {
            chips.add(_Chip(label: 'id · ${match['id']}'));
          } else {
            if (match['merchant'] is String) {
              chips.add(_Chip(label: 'match · ${match['merchant']}'));
            }
            if (match.containsKey('amount')) {
              final v = (match['amount'] as num?)?.toDouble();
              if (v != null) {
                chips.add(_Chip(label: 'amount · \$${v.toStringAsFixed(2)}'));
              }
            }
          }
        }
      case 'delete_expense':
      case 'delete_transaction':
        if (p.containsKey('amount')) {
          final v = (p['amount'] as num?)?.toDouble();
          if (v != null) chips.add(_Chip(label: 'amount · \$${v.toStringAsFixed(2)}'));
        }
        if (p.containsKey('match')) {
          chips.add(_Chip(label: 'match · ${p['match']}'));
        }
        if (p.containsKey('id')) {
          chips.add(_Chip(label: 'id · ${p['id']}'));
        }
      case 'set_ignored':
        chips.add(_Chip(label: 'ignored · ${p['ignored']}'));
        final match = p['match'] as Map<String, Object?>?;
        if (match != null) {
          if (match.containsKey('id')) {
            chips.add(_Chip(label: 'id · ${match['id']}'));
          }
          if (match['merchant'] is String) {
            chips.add(_Chip(label: 'merchant · ${match['merchant']}'));
          }
          if (match.containsKey('amount')) {
            final v = (match['amount'] as num?)?.toDouble();
            if (v != null) {
              chips.add(_Chip(label: 'amount · \$${v.toStringAsFixed(2)}'));
            }
          }
        }
      case 'clear_ai_log':
        if (p.containsKey('keep_last')) {
          chips.add(_Chip(label: 'keep_last · ${p['keep_last']}'));
        }
      case 'export_csv':
        addIfPresent('kind', (p['kind'] as String?) ?? '');
        if (p.containsKey('from')) {
          chips.add(_Chip(label: 'from · ${p['from']}'));
        }
        if (p.containsKey('to')) {
          chips.add(_Chip(label: 'to · ${p['to']}'));
        }
      case 'update_ai_config':
        if (p.containsKey('provider')) {
          chips.add(_Chip(label: 'provider · ${p['provider']}'));
        }
        if (p.containsKey('model')) {
          chips.add(_Chip(label: 'model · ${p['model']}'));
        }
        if (p.containsKey('base_url')) {
          chips.add(_Chip(label: 'base_url · ${p['base_url']}'));
        }
        if (p['clear_base_url'] == true) {
          chips.add(const _Chip(label: 'clear_base_url · true'));
        }
      case 'add_filter_rule':
        final r = p['rule'] as Map<String, Object?>?;
        if (r != null) {
          for (final entry in r.entries) {
            final inner = entry.value as Map<String, Object?>?;
            if (inner != null) {
              chips.add(_Chip(
                label:
                    '${entry.key} · ${inner['value']} (${inner['match'] ?? 'contains'})',
              ));
            }
          }
        }
        addIfPresent('enabled', '${p['enabled']}');
        addIfPresent('logic', (p['logic'] as String?) ?? '');
      case 'update_filter_rule':
        addIfPresent('index', '${p['index']}');
      case 'delete_filter_rule':
        addIfPresent('index', '${p['index']}');
      case 'set_filter_mode':
        addIfPresent('enabled', '${p['enabled']}');
        addIfPresent('logic', (p['logic'] as String?) ?? '');
      case 'sync_gmail_now':
        if (p['force'] == true) {
          chips.add(const _Chip(label: 'force · true'));
        }
      case 'bulk_delete_transactions':
        addIfPresent('source', (p['source'] as String?) ?? '');
        addIfPresent('merchant_contains', (p['merchant_contains'] as String?) ?? '');
        if (p.containsKey('before')) {
          chips.add(_Chip(label: 'before · ${p['before']}'));
        }
        if (p.containsKey('after')) {
          chips.add(_Chip(label: 'after · ${p['after']}'));
        }
        if (p.containsKey('min_amount')) {
          final v = (p['min_amount'] as num?)?.toDouble();
          if (v != null) {
            chips.add(_Chip(label: 'min_amount · \$${v.toStringAsFixed(2)}'));
          }
        }
        if (p.containsKey('max_amount')) {
          final v = (p['max_amount'] as num?)?.toDouble();
          if (v != null) {
            chips.add(_Chip(label: 'max_amount · \$${v.toStringAsFixed(2)}'));
          }
        }
        if (p['include_ignored'] == true) {
          chips.add(const _Chip(label: 'include_ignored · true'));
        }
      case 'delete_activity_log_entry':
        addIfPresent('id', '${p['id']}');
      case 'replace_filter_rules':
        final raw = (p['rules'] as List?) ?? const [];
        chips.add(_Chip(label: 'rules · ${raw.length} supplied'));
      case 'update_backup_preferences':
        if (p.containsKey('enabled')) {
          chips.add(_Chip(label: 'enabled · ${p['enabled']}'));
        }
        if (p.containsKey('hour') || p.containsKey('minute')) {
          final h = p['hour'] ?? '?';
          final m = p['minute'] ?? '?';
          chips.add(_Chip(label: 'time · $h:$m'));
        }
        addIfPresent('frequency', (p['frequency'] as String?) ?? '');
        for (final entry in p.entries) {
          if (entry.key.startsWith('notify_on_')) {
            chips.add(_Chip(label: '${entry.key} · ${entry.value}'));
          }
        }
    }

    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final c in chips)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 3,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                c.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  String _stringify(Object? v) {
    if (v is num) return v.toString();
    if (v is List) return v.join(', ');
    return v?.toString() ?? '';
  }
  Future<void> _confirm() async {
    // Destructive verbs get a second confirm AFTER the action card
    // itself — the system prompt guarantees the user already saw a
    // clear description on the card, so the modal just re-asks with
    // a stronger visual + a "type DELETE to confirm" input. Keeps the
    // common path (non-destructive) at one tap, while still gating
    // anything that can't be undone.
    if (_destructiveVerbs.contains(widget.action.action.name)) {
      final proceed = await _showDestructiveConfirm(
        context: context,
        actionName: widget.action.action.name,
        description: widget.action.body.trim(),
      );
      if (proceed != true) return;
      if (!mounted) return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await _execute(widget.action.action);
      if (!mounted) return;
      // Drop the cached snapshot so the user's next chat message
      // (e.g. "now show me my budgets") rebuilds it from current state
      // instead of returning the pre-mutation view. Runs for every
      // successful action — read-only verbs are no-ops here since
      // their cache contents don't shift.
      _invalidateAgentSnapshot();
      ref
          .read(agentConversationProvider.notifier)
          .setActionStatus(widget.index, AgentActionStatus.confirmed);
      setState(() => _result = result);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Modal that gates destructive verbs. User must type the verb's
  /// short label (e.g. "delete") to proceed. Returns true only on a
  /// exact, case-sensitive match. Keeps the common path (one tap to
  /// Confirm on the action card) but stops the "fat-fingered tap"
  /// path on anything that nukes data.
  Future<bool?> _showDestructiveConfirm({
    required BuildContext context,
    required String actionName,
    required String description,
  }) {
    final theme = Theme.of(context);
    final expected = _destructiveToken(actionName);
    final controller = TextEditingController();

    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final typed = controller.text;
            final canProceed = typed == expected;
            return AlertDialog(
              icon: Icon(
                Icons.warning_amber_rounded,
                color: AppColors.danger,
                size: 32,
              ),
              title: const Text('Are you sure?'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    "This can't be undone. Type $expected below to confirm.",
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Type to confirm',
                      isDense: true,
                    ),
                    onChanged: (_) => setLocal(() {}),
                    onSubmitted: (v) {
                      if (v == expected) Navigator.of(ctx).pop(true);
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.danger,
                  ),
                  onPressed: canProceed
                      ? () => Navigator.of(ctx).pop(true)
                      : null,
                  child: const Text('Confirm'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The literal string the user must type to confirm. Per-verb so
  /// "delete" works for delete_* and "disconnect" works for
  /// disconnect_gmail — keeps the input short and the intent specific.
  String _destructiveToken(String verb) {
    if (verb.startsWith('delete_') || verb.startsWith('bulk_delete')) {
      return 'delete';
    }
    if (verb == 'clear_ai_log') return 'clear';
    if (verb == 'disconnect_gmail') return 'disconnect';
    if (verb == 'reset_gmail_signin') return 'reset';
    if (verb == 'replace_filter_rules') return 'replace';
    if (verb == 'restore_now') return 'restore';
    return 'confirm';
  }

  Future<String> _execute(AgentActionSpec spec) async {
    return executeAgentAction(ref, context, spec);
  }

  /// Resolves a user description ("the Amazon charge", "the $5 coffee")
  /// into one or more transaction ids. Read-only — never mutates. The
  /// model is told to call this BEFORE update_transaction or
  /// delete_transaction when the user describes a transaction by name
  /// instead of citing an id, because mutations only accept ids.
  ///
  /// Params: {
  ///   merchant?: string  (substring match, case-insensitive),
  ///   amount?: number    (exact within $0.01),
  ///   days_back?: number (defaults to 90),
  ///   limit?: number     (defaults to 10, max 25),
  ///   min_amount?: number, max_amount?: number (filter by absolute amount),
  ///   ignored?: bool (defaults to false — exclude ignored rows)
  /// }.
  ///
  /// Returns an answer-formatted string with a small table. The text
  /// form ("id 42 · Amazon · 2026-09-07 · $5.00") is what the LLM and
  /// the user both see; the rows are used by the UI.






  // ============================================================
  // NEW MUTATION HANDLERS (added for full CRUD coverage)
  // ============================================================



  /// Resolves a transaction by id. The id-first standard is enforced by
  /// requiring id at the call sites — see _execDeleteExpense,
  /// _execUpdateTransaction, _execSetIgnored. Use [find_transaction]
  /// (verb) to resolve a user description (merchant, amount, date) to
  /// an id, then pass the id here.
  ///
  /// Accepts id at top level OR nested under `match` — the LLM is
  /// inconsistent about which it picks, so both work.
  /// [search] (max 5000 rows) covers long-running users with deeper
  /// history than the default 200 in `TransactionRepository.recent`.













  // ============================================================
  // NEW VERB HANDLERS — added for full coverage of the app surface
  // (settings, account, infrastructure). See the system prompt in
  // agent_service.dart for the per-verb param shapes the model uses.
  // ============================================================

  /// Wipes every transaction that matches ALL the supplied criteria.
  /// Reads from the full local DB (not just the visible window) since
  /// the user might say "delete everything before August". The card
  /// description should have stated the exact criteria + count; this
  /// handler just trusts them and runs.

  /// Deletes a single AI log row by id. No-op if the id doesn't exist
  /// (e.g. another call cleared the log between propose and confirm).

  /// Pushes the user to the AI model screen so they can paste a new
  /// key (or replace an existing one). The key itself NEVER travels
  /// through this verb — it stays on-device. The system prompt
  /// enforces this — the model is told to call manage_ai_api_key for
  /// key management questions, never to invent key text.

  /// Fetches the GCP infra snapshot and returns a short summary for
  /// the chat bubble. Admin-only — the snapshot is null for everyone
  /// else (the server enforces this; the client just reads what it
  /// gets). On 403/network failure we surface a friendly message so
  /// the agent can rephrase.

  /// Clears the cached AgentData snapshot so the user's next chat
  /// message rebuilds it from current local state. Called from every
  /// mutation handler — without this, a "create a Food budget, now
  /// tell me about my budgets" follow-up would see stale data until
  /// the 30s TTL elapses.
  void _invalidateAgentSnapshot() => invalidateAgentSnapshot(ref);
}
Future<Transaction> _findTransaction(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(transactionRepoProvider);
  final match = p['match'] as Map<String, Object?>? ?? const {};
  final idNum = (match['id'] as num?)?.toInt() ?? (p['id'] as num?)?.toInt();
  if (idNum == null) {
    throw ArgumentError(
      'Need a transaction id (not merchant). Call find_transaction '
      'first to resolve the description to an id, then pass '
      '{"id": <number>}.',
    );
  }
  final all = await repo.recent(limit: 5000);
  final found = all.where((t) => t.id == idNum).toList();
  if (found.isEmpty) {
    throw ArgumentError(
      'No transaction with id $idNum (already deleted, or local data out of sync)',
    );
  }
  return found.first;
}

RuleField? _parseRuleField(Object? raw) {
  if (raw is! Map) return null;
  final value = (raw['value'] as String?)?.trim() ?? '';
  if (value.isEmpty) return null;
  final match = (raw['match'] as String?) ?? 'contains';
  final mt = MatchType.values.firstWhere(
    (m) => m.name == match,
    orElse: () => MatchType.contains,
  );
  return RuleField(value: value, matchType: mt);
}

FilterRule _parseRule(Map<String, Object?> raw) {
  return FilterRule(
    sender: _parseRuleField(raw['sender']),
    subject: _parseRuleField(raw['subject']),
    body: _parseRuleField(raw['body']),
  );
}

Future<Budget> _findBudget(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(budgetRepoProvider);
  final budgets = await repo.all();
  if (budgets.isEmpty) {
    throw ArgumentError('No budgets yet');
  }
  final id = (p['id'] as num?)?.toInt();
  if (id != null) {
    final match = budgets.where((b) => b.id == id).toList();
    if (match.isEmpty) {
      throw ArgumentError('No budget with id $id');
    }
    return match.first;
  }
  final name = ((p['name'] as String?) ?? '').trim().toLowerCase();
  if (name.isEmpty) {
    throw ArgumentError('Need a budget name or id');
  }
  final exact = budgets
    .where((b) => b.name.toLowerCase() == name)
    .toList();
  if (exact.length == 1) return exact.first;
  if (exact.isEmpty) {
    // Try fuzzy contains match (e.g. user said "Food" but budget is "Food Budget").
    final contains = budgets
      .where((b) => b.name.toLowerCase().contains(name))
      .toList();
    if (contains.length == 1) return contains.first;
    throw ArgumentError(
      contains.isEmpty
          ? 'No budget matches "$name"'
          : 'Multiple budgets match "$name": ${contains.map((b) => b.name).join(", ")}',
    );
  }
  throw ArgumentError(
    'Multiple budgets match "$name": ${exact.map((b) => b.name).join(", ")}',
  );
}



class _Chip {
  const _Chip({required this.label});
  final String label;
}

/// Verbs that, after the user taps Confirm on the action card, get a
/// SECOND modal asking them to type-confirm before anything runs.
/// Matches the [DESTRUCTIVE] tags in the system prompt — keep them
/// in sync when adding a new verb. Hoisted to top-level so the plan
/// widget can reuse it.
const _kDestructiveVerbs = {
  'delete_budget',
  'delete_expense',
  'delete_transaction',
  'bulk_delete_transactions',
  'clear_ai_log',
  'delete_activity_log_entry',
  'replace_filter_rules',
  'disconnect_gmail',
  'reset_gmail_signin',
};

bool _isDestructive(String verb) => _kDestructiveVerbs.contains(verb);

/// The literal string the user must type to confirm. Per-verb so
/// "delete" works for delete_* and "disconnect" works for
/// disconnect_gmail — keeps the input short and the intent specific.
String _destructiveTokenFor(String verb) {
  if (verb.startsWith('delete_') || verb.startsWith('bulk_delete')) {
    return 'delete';
  }
  if (verb == 'clear_ai_log') return 'clear';
  if (verb == 'replace_filter_rules') return 'replace';
  if (verb == 'restore_now') return 'restore';
  return 'confirm';
}

/// Clears the cached AgentData snapshot so the user's next chat
/// message rebuilds it from current local state. Called from every
/// mutation handler — without this, a "create a Food budget, now
/// tell me about my budgets" follow-up would see stale data until
/// the 30s TTL elapses. Best-effort: if the agent provider isn't
/// ready, there's no cache to clear.
void invalidateAgentSnapshot(WidgetRef ref) {
  try {
    final svcAsync = ref.read(agentServiceProvider);
    svcAsync.whenData((svc) => svc.invalidateSnapshotCache());
  } catch (_) {/* no agent available — nothing to invalidate */}
}

/// Append a structured fact to the agent's memory ledger. Called
/// from mutation handlers after a successful operation so the next
/// turn can reference the result verbatim ("the budget you just
/// created", "the expense you just deleted"). Best-effort: if the
/// agent service isn't wired (no API key set), the whenData callback
/// is a no-op.
void recordAgentFact(WidgetRef ref, AgentFact fact) {
  try {
    ref.read(agentServiceProvider).whenData((svc) => svc.facts.add(fact));
  } catch (_) {/* no agent available — fact dropped silently */}
}

/// Shared dispatch for both single-action and plan-step execution.
/// Lives at the top level so [_PlanWidget] can run its steps through
/// the same code path the single-action card uses — keeps the verb
/// list in one place and avoids a private bridge on a State class
/// (States can't be instantiated directly).
Future<String> executeAgentAction(
  WidgetRef ref,
  BuildContext context,
  AgentActionSpec spec,
) async {
  final p = spec.params;
  switch (spec.name) {
    case 'create_budget':
      return _execCreateBudget(ref, p);
    case 'update_budget':
      return _execUpdateBudget(ref, p);
    case 'delete_budget':
      return _execDeleteBudget(ref, p);
    case 'set_active_budget':
      return _execSetActiveBudget(ref, p);
    case 'create_expense':
      return _execCreateExpense(ref, p);
    case 'update_transaction':
      return _execUpdateTransaction(ref, p);
    case 'delete_expense':
    case 'delete_transaction':
      return _execDeleteExpense(ref, p);
    case 'bulk_delete_transactions':
      return _execBulkDeleteTransactions(ref, p);
    case 'set_ignored':
      return _execSetIgnored(ref, p);
    case 'clear_ai_log':
      return _execClearAiLog(ref, p);
    case 'delete_activity_log_entry':
      return _execDeleteActivityLogEntry(ref, p);
    case 'export_csv':
      return _execExportCsv(ref, p);
    case 'update_ai_config':
      return _execUpdateAiConfig(ref, p);
    case 'manage_ai_api_key':
      return _execManageAiApiKey(ref, context, p);
    case 'add_filter_rule':
      return _execAddFilterRule(ref, p);
    case 'update_filter_rule':
      return _execUpdateFilterRule(ref, p);
    case 'delete_filter_rule':
      return _execDeleteFilterRule(ref, p);
    case 'set_filter_mode':
      return _execSetFilterMode(ref, p);
    case 'replace_filter_rules':
      return _execReplaceFilterRules(ref, p);
    case 'sync_gmail_now':
      return _execSyncGmailNow(ref, p);
    case 'disconnect_gmail':
      return _execDisconnectGmail(ref, p);
    case 'sign_in_gmail':
      return _execSignInGmail(ref, p);
    case 'reset_gmail_signin':
      return _execResetGmailSignin(ref, p);
    case 'request_notification_permission':
      return _execRequestNotificationPermission(ref, p);
    case 'find_transaction':
      return _execFindTransaction(ref, p);
    case 'update_backup_preferences':
      return _execUpdateBackupPreferences(ref, p);
    case 'backup_now':
      return _execBackupNow(ref);
    case 'restore_now':
      return _execRestoreNow(ref);
    default:
      throw ArgumentError('Unsupported action: ${spec.name}');
  }
}

/// Slim card used for terminal action states (confirmed / cancelled).
class _CompactCard extends StatelessWidget {
  const _CompactCard({
    required this.accent,
    required this.icon,
    required this.text,
    this.subtle = false,
    this.strikethrough = false,
  });

  final Color accent;
  final IconData icon;
  final String text;
  final bool subtle;
  final bool strikethrough;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 4, right: 6),
              child: Icon(icon, size: 14, color: accent),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: MarkdownText(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.35,
                    color: subtle
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                    decoration: strikethrough
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact indigo pill button. Smaller than a normal FilledButton so the
/// action card stays compact.
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primary,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: Colors.white,
                  ),
                )
              else
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<String> _execFindTransaction(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(transactionRepoProvider);
  final merchantQ = (p['merchant'] as String?)?.trim();
  final amount = (p['amount'] as num?)?.toDouble();
  final daysBack = (p['days_back'] as num?)?.toInt() ?? 90;
  final limit = ((p['limit'] as num?)?.toInt() ?? 10).clamp(1, 25);
  final minAmt = (p['min_amount'] as num?)?.toDouble();
  final maxAmt = (p['max_amount'] as num?)?.toDouble();
  final includeIgnored = p['ignored'] == true;

  final cutoff = DateTime.now().subtract(Duration(days: daysBack));
  final all = await repo.recent(limit: 5000);
  final matches = all.where((t) {
    if (!includeIgnored && t.ignored) return false;
    if (t.occurredAt.isBefore(cutoff)) return false;
    if (merchantQ != null && merchantQ.isNotEmpty) {
      if (!t.merchant.toLowerCase().contains(merchantQ.toLowerCase())) {
        return false;
      }
    }
    if (amount != null && (t.amount - amount).abs() >= 0.01) {
      return false;
    }
    final absAmt = t.amount.abs();
    if (minAmt != null && absAmt < minAmt) return false;
    if (maxAmt != null && absAmt > maxAmt) return false;
    return true;
  }).toList()
    ..sort((a, b) => b.occurredAt.compareTo(a.occurredAt))
    ..take(limit);

  if (matches.isEmpty) {
    return 'No transactions matched merchant=${merchantQ ?? "(any)"}'
        '${amount == null ? '' : ' amount=\$${amount.toStringAsFixed(2)}'}';
  }

  // Human-readable form (no amount sign for display, just magnitude).
  final lines = matches.map((t) {
    final date = '${t.occurredAt.year.toString().padLeft(4, '0')}-'
        '${t.occurredAt.month.toString().padLeft(2, '0')}-'
        '${t.occurredAt.day.toString().padLeft(2, '0')}';
    final signed = t.amount < 0 ? '-\$' : '\$';
    return '#${t.id} · ${t.merchant} · $date · '
        '$signed${t.amount.abs().toStringAsFixed(2)}'
        '${t.ignored ? ' · ignored' : ''}';
  }).toList();

  final header = matches.length == 1
      ? '1 transaction found (use {"id": <number>} for update/delete):'
      : '${matches.length} transactions found (use {"id": <number>} '
          'for update/delete, or call find_transaction with more specific filters):';

  return '$header\n${lines.join('\n')}';
}

Future<String> _execCreateBudget(WidgetRef ref, Map<String, Object?> p) async {
  final name = ((p['name'] as String?) ?? '').trim();
  final amount = (p['amount'] as num?)?.toDouble();
  final periodStr = (p['period'] as String?) ?? 'monthly';
  if (name.isEmpty || amount == null || amount <= 0) {
    throw ArgumentError('Budget needs a name and positive amount');
  }
  final period = BudgetPeriod.values.firstWhere(
    (e) => e.name == periodStr,
    orElse: () => BudgetPeriod.monthly,
  );
  final now = DateTime.now();
  DateTime start;
  DateTime end;
  switch (period) {
    case BudgetPeriod.weekly:
      start = now.subtract(Duration(days: now.weekday - 1));
      start = DateTime(start.year, start.month, start.day);
      end = start.add(const Duration(days: 6));
    case BudgetPeriod.monthly:
      start = DateTime(now.year, now.month, 1);
      end = DateTime(now.year, now.month + 1, 1).subtract(
        const Duration(days: 1),
      );
    case BudgetPeriod.custom:
      final sStr = p['start_date'] as String?;
      final eStr = p['end_date'] as String?;
      if (sStr == null || eStr == null) {
        throw ArgumentError('Custom budget needs start_date and end_date');
      }
      start = DateTime.parse(sStr);
      end = DateTime.parse(eStr);
  }
  final repo = ref.read(budgetRepoProvider);
  final budgets = await repo.all();
  final active = budgets.isEmpty;
  // Capture the inserted id so follow-up edits/deletes can use
  // {"id": <number>} instead of brittle name-based lookups.
  final inserted = await repo.insert(
    Budget(
      id: null,
      name: name,
      amount: amount,
      period: period,
      startDate: start,
      endDate: end,
      alertEvery: false,
      alertThresholds: const [80, 100],
      active: active,
      createdAt: DateTime.now(),
    ),
  );
  ref.invalidate(budgetsProvider);
  ref.invalidate(activeBudgetProvider);
  final id = inserted?.id;
  final desc = 'Created budget${id == null ? '' : ' #$id'}: "$name" '
      'at \$${amount.toStringAsFixed(2)}/${period.name}'
      '${active ? ' (now active)' : ''}';
  recordAgentFact(ref, AgentFact(kind: 'budget_created', description: desc));
  return desc;
}

Future<String> _execCreateExpense(WidgetRef ref, Map<String, Object?> p) async {
  final amount = (p['amount'] as num?)?.toDouble();
  final merchant = ((p['merchant'] as String?) ?? '').trim();
  final reason = (p['reason'] as String?)?.trim();
  final kind = (p['kind'] as String?) ?? 'spend';
  if (amount == null || amount <= 0 || merchant.isEmpty) {
    throw ArgumentError('Expense needs a positive amount and merchant');
  }
  final occurredAt = _parseOccurredAt(p['occurred_at'] as String?) ?? DateTime.now();
  final signed = kind == 'refund' ? -amount : amount;
  final txn = Transaction(
    id: null,
    notificationKey: '',
    source: 'manual',
    amount: signed,
    merchant: merchant,
    reason: (reason == null || reason.isEmpty) ? null : reason,
    occurredAt: occurredAt,
  );
  final repo = ref.read(transactionRepoProvider);
  // Capture the inserted id so the model can refer to this exact row
  // in follow-ups ("delete that one"). Every transaction is uniquely
  // identified by its id from the moment it's created — that's the
  // standard for find/update/delete, not merchant strings.
  final inserted = await repo.insertManual(txn);
  ref.invalidate(transactionsProvider);
  final id = inserted.id;
  final desc = '${kind == 'refund' ? 'Refund' : 'Added'} expense'
      '${id == null ? '' : ' #$id'}: '
      '\$${amount.toStringAsFixed(2)} · $merchant';
  recordAgentFact(ref, AgentFact(kind: 'expense_created', description: desc));
  return desc;
}

/// Parses the optional `occurred_at` param for `create_expense`. Three
/// accepted shapes:
///   - YYYY-MM-DD            → that date with current local time-of-day
///   - ISO 8601, no `Z`      → datetime interpreted in local time
///   - ISO 8601 with `Z`     → UTC, converted to local time
/// Anything else returns null and the caller falls back to
/// `DateTime.now()` (the email-triggered default — receive time).
///
/// Why we don't try to parse natural language here: the LLM is
/// already capable of turning "yesterday at 3pm" into a well-formed
/// `2026-09-06T15:00:00` before it sends the verb, so the on-device
/// parser stays a thin ISO 8601 validator and never has to guess.
DateTime? _parseOccurredAt(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  final dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  if (dateOnly.hasMatch(s)) {
    // Date-only: take today's local clock so the user's "Sep 5" lands
    // at the same minute as the chat they're typing in. Users asking
    // for a specific date usually mean "on that day", not "midnight".
    try {
      final d = DateTime.parse(s);
      final now = DateTime.now();
      return DateTime(d.year, d.month, d.day, now.hour, now.minute, now.second);
    } catch (_) {
      return null;
    }
  }
  final parsed = DateTime.tryParse(s);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

Future<String> _execUpdateBudget(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(budgetRepoProvider);
  final budget = await _findBudget(ref, p);
  final updates = (p['updates'] as Map<String, Object?>?) ?? const {};
  if (updates.isEmpty) {
    throw ArgumentError('No fields to update');
  }

  Budget updated = budget;
  if (updates.containsKey('amount')) {
    final v = (updates['amount'] as num?)?.toDouble();
    if (v == null || v <= 0) {
      throw ArgumentError('Amount must be positive');
    }
    updated = updated.copyWith(amount: v);
  }
  if (updates.containsKey('name')) {
    final n = ((updates['name'] as String?) ?? '').trim();
    if (n.isEmpty) throw ArgumentError('Name cannot be empty');
    updated = updated.copyWith(name: n);
  }
  if (updates.containsKey('period')) {
    final periodStr = updates['period'] as String?;
    final period = BudgetPeriod.values.firstWhere(
      (e) => e.name == periodStr,
      orElse: () => BudgetPeriod.monthly,
    );
    updated = updated.copyWith(period: period);
  }
  if (updates.containsKey('alert_every')) {
    updated = updated.copyWith(
      alertEvery: updates['alert_every'] == true,
    );
  }
  if (updates.containsKey('alert_thresholds')) {
    final raw = (updates['alert_thresholds'] as List?) ?? const [];
    final ts = raw
        .map((e) => (e is num) ? e.toInt() : int.tryParse(e.toString()) ?? 0)
        .where((t) => t > 0 && t <= 200)
        .toSet()
        .toList(growable: false)
      ..sort();
    if (ts.isEmpty) {
      throw ArgumentError('At least one threshold required');
    }
    updated = updated.copyWith(alertThresholds: ts);
  }
  if (updates.containsKey('active') && updates['active'] == true) {
    await repo.activate(updated);
    ref.invalidate(activeBudgetProvider);
  }

  await repo.update(updated);
  ref.invalidate(budgetsProvider);
  final changes = updates.keys.where((k) => k != 'active').toList();
  final desc = 'Updated budget #${updated.id ?? '?'} "${updated.name}"'
      '${changes.isEmpty ? '' : ' (changed: ${changes.join(", ")})'}';
  recordAgentFact(ref, AgentFact(kind: 'budget_updated', description: desc));
  return desc;
}

Future<String> _execDeleteBudget(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(budgetRepoProvider);
  final budget = await _findBudget(ref, p);
  if (budget.id == null) {
    throw ArgumentError('Budget has no id');
  }
  final id = budget.id;
  final name = budget.name;
  await repo.delete(budget.id!);
  ref.invalidate(budgetsProvider);
  ref.invalidate(activeBudgetProvider);
  final desc = 'Deleted budget #$id "$name"';
  recordAgentFact(ref, AgentFact(kind: 'budget_deleted', description: desc));
  return desc;
}

Future<String> _execDeleteExpense(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(transactionRepoProvider);

  // Bulk delete (match == "all"): only allowed when the user explicitly
  // asks for every match. Anchored on merchant so a stray bulk request
  // with no merchant doesn't drop the entire table. Bulk still works by
  // merchant+amount because the user intent is bulk + scoped.
  final matchObj = p['match'] as Map<String, Object?>?;
  final isBulk = matchObj?['match'] == 'all' || p['match'] == 'all';
  if (isBulk) {
    final merchant = ((matchObj?['merchant'] as String?) ??
            (p['merchant'] as String?) ??
            '')
        .trim();
    if (merchant.isEmpty) {
      throw ArgumentError('Need a merchant to bulk-delete');
    }
    final amount = (matchObj?['amount'] as num?)?.toDouble() ??
        (p['amount'] as num?)?.toDouble();
    final all = await repo.recent(limit: 5000);
    final matches = all
        .where((t) =>
            t.merchant.toLowerCase() == merchant.toLowerCase())
        .where((t) => amount == null || (t.amount - amount).abs() < 0.01)
        .toList();
    if (matches.isEmpty) {
      throw ArgumentError('No matching expense found at $merchant');
    }
    for (final t in matches) {
      if (t.id != null) await repo.deleteById(t.id!);
    }
    ref.invalidate(transactionsProvider);
    ref.invalidate(activeBudgetProvider);
    final desc = 'Bulk-deleted ${matches.length} expense(s) at $merchant';
    recordAgentFact(ref, AgentFact(
      kind: 'transactions_bulk_deleted',
      description: desc,
    ));
    return desc;
  }

  // Single delete: REQUIRE an id. Every transaction has an id from the
  // moment it's created — that's how find/update/delete work, and
  // accepting merchant-only here was the source of every "unable to
  // find transaction <X>" error: case differences, smart quotes, OCR
  // noise, and merchant name collisions all silently broke lookups.
  //
  // If the user describes a transaction by name, the workflow is:
  //   1. Call find_transaction with the description
  //   2. Pass the returned id to delete_transaction
  // The LLM is told this in the system prompt.
  final idNum = (matchObj?['id'] as num?)?.toInt() ?? (p['id'] as num?)?.toInt();
  if (idNum == null) {
    throw ArgumentError(
      'delete_transaction needs an id, not a merchant. '
      'Call find_transaction first to resolve the description to an id, '
      'then pass {"id": <number>}.',
    );
  }
  final all = await repo.recent(limit: 5000);
  final target = all.where((t) => t.id == idNum).toList();
  if (target.isEmpty) {
    throw ArgumentError(
      'No transaction with id $idNum (already deleted, or local data out of sync)',
    );
  }
  await repo.deleteById(idNum);
  ref.invalidate(transactionsProvider);
  ref.invalidate(activeBudgetProvider);
  final t = target.first;
  final desc = 'Deleted transaction #$idNum: ${t.merchant} '
      '(\$${t.amount.toStringAsFixed(2)})';
  recordAgentFact(ref, AgentFact(kind: 'transaction_deleted', description: desc));
  return desc;
}

Future<String> _execSetActiveBudget(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(budgetRepoProvider);
  final budget = await _findBudget(ref, p);
  if (budget.active) return '"${budget.name}" is already active';
  await repo.activate(budget);
  ref.invalidate(budgetsProvider);
  ref.invalidate(activeBudgetProvider);
  final desc = 'Switched active budget to #${budget.id ?? '?'} '
      '"${budget.name}"';
  recordAgentFact(ref, AgentFact(kind: 'active_budget_switched', description: desc));
  return desc;
}

Future<String> _execUpdateTransaction(WidgetRef ref, Map<String, Object?> p) async {
  final updates = (p['updates'] as Map<String, Object?>?) ?? const {};
  if (updates.isEmpty) throw ArgumentError('No fields to update');

  final repo = ref.read(transactionRepoProvider);
  final target = await _findTransaction(ref, p);

  Transaction next = target;
  if (updates.containsKey('merchant')) {
    final m = ((updates['merchant'] as String?) ?? '').trim();
    if (m.isEmpty) throw ArgumentError('Merchant cannot be empty');
    next = next.copyWith(merchant: m);
  }
  if (updates.containsKey('amount')) {
    final v = (updates['amount'] as num?)?.toDouble();
    if (v == null || v == 0) throw ArgumentError('Amount must be non-zero');
    // Preserve the original sign: refunds stay negative, spends stay positive.
    next = next.copyWith(
      amount: next.amount < 0 ? -v.abs() : v.abs(),
    );
  }
  if (updates.containsKey('reason')) {
    final r = updates['reason'] as String?;
    next = next.copyWith(reason: (r == null || r.isEmpty) ? null : r);
  }
  if (updates.containsKey('occurred_at')) {
    // Same parse rules as create_expense — ISO 8601 only, empty /
    // null / unparseable falls back to DateTime.now() so the agent
    // can re-time an expense to "just now" by sending an empty
    // string (mirrors the UI's "Reset to now" button).
    final raw = updates['occurred_at'] as String?;
    final parsed = _parseOccurredAt(raw) ?? DateTime.now();
    next = next.copyWith(occurredAt: parsed);
  }

  await repo.update(next);
  ref.invalidate(transactionsProvider);
  ref.invalidate(activeBudgetProvider);
  final changes = updates.keys.toList();
  final desc = 'Updated transaction #${next.id}: "${next.merchant}" '
      '(\$${next.amount.toStringAsFixed(2)})'
      '${changes.isEmpty ? '' : ' (changed: ${changes.join(", ")})'}';
  recordAgentFact(ref, AgentFact(kind: 'transaction_updated', description: desc));
  return desc;
}

Future<String> _execSetIgnored(WidgetRef ref, Map<String, Object?> p) async {
  final ignored = p['ignored'] == true;
  final repo = ref.read(transactionRepoProvider);
  final target = await _findTransaction(ref, p);
  final id = target.id;
  if (id == null) {
    throw ArgumentError('Transaction has no id');
  }
  await repo.setIgnored(id, ignored);
  ref.invalidate(transactionsProvider);
  ref.invalidate(activeBudgetProvider);
  final desc = ignored
      ? 'Ignoring #$id ${target.merchant} '
          '(${target.amount.toStringAsFixed(2)}) from spending'
      : 'Including #$id ${target.merchant} back in spending';
  recordAgentFact(ref, AgentFact(kind: 'transaction_ignored', description: desc));
  return desc;
}

Future<String> _execClearAiLog(WidgetRef ref, Map<String, Object?> p) async {
  await AiLogStore.clear();
  ref.invalidate(aiLogProvider);
  return 'Cleared the activity log';
}

Future<String> _execExportCsv(WidgetRef ref, Map<String, Object?> p) async {
  final kind = (p['kind'] as String?) ?? 'transactions';
  final fromStr = p['from'] as String?;
  final toStr = p['to'] as String?;
  final from = fromStr != null ? DateTime.parse(fromStr) : null;
  final to = toStr != null
      ? DateTime.parse(toStr).add(const Duration(days: 1))
      : null;

  String body;
  String filename;
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').substring(0, 16);
  if (kind == 'budgets') {
    final repo = ref.read(budgetRepoProvider);
    final budgets = await repo.all();
    body = CsvExporter.budgets(budgets);
    filename = 'pocket-budgets-$stamp.csv';
  } else {
    final repo = ref.read(transactionRepoProvider);
    final txns = (from != null && to != null)
        ? await repo.inRange(from, to)
        : await repo.recent(limit: 5000);
    body = CsvExporter.transactions(txns);
    filename = 'pocket-transactions-$stamp.csv';
  }
  await ShareFile.shareCsv(filename: filename, csvBody: body);
  return 'Exported $kind CSV';
}

Future<String> _execUpdateAiConfig(WidgetRef ref, Map<String, Object?> p) async {
  final store = await ref.read(aiKeyStoreProvider.future);
  final cfg = await store.read();

  CloudProvider provider = cfg.provider;
  if (p.containsKey('provider')) {
    final name = p['provider'] as String?;
    provider = CloudProvider.values.firstWhere(
      (e) => e.name == name,
      orElse: () => cfg.provider,
    );
    await store.writeProvider(provider);
  }

  if (p.containsKey('model')) {
    final m = (p['model'] as String?)?.trim() ?? '';
    await store.writeModel(m.isEmpty ? provider.defaultModel : m);
  } else if (p.containsKey('provider')) {
    // Switching provider without specifying a model → reset to default.
    await store.writeModel(provider.defaultModel);
  }

  if (p['clear_base_url'] == true) {
    await store.writeBaseUrl(null);
  } else if (p.containsKey('base_url')) {
    final url = (p['base_url'] as String?)?.trim() ?? '';
    await store.writeBaseUrl(url.isEmpty ? null : url);
  }

  ref.invalidate(aiConfigProvider);
  ref.invalidate(cloudParserProvider);
  return 'Updated AI config to ${provider.name}'
      '${p.containsKey('model') ? ' / ${p['model']}' : ''}';
}

Future<String> _execAddFilterRule(WidgetRef ref, Map<String, Object?> p) async {
  final ruleRaw = p['rule'] as Map<String, Object?>?;
  if (ruleRaw == null) throw ArgumentError('Missing "rule" param');
  final newRule = _parseRule(ruleRaw);
  if (newRule.isEmpty) {
    throw ArgumentError('Rule needs at least one of sender/subject/body');
  }

  final controller = ref.read(gmailFilterRulesProvider.notifier);
  var current = ref.read(gmailFilterRulesProvider);
  if (p.containsKey('enabled')) {
    current = current.copyWith(enabled: p['enabled'] == true);
  }
  if (p['logic'] is String) {
    current = current.copyWith(
      logic: Logic.values.firstWhere(
        (l) => l.name == p['logic'],
        orElse: () => current.logic,
      ),
    );
  }
  final next = current.copyWith(rules: [...current.rules, newRule]);
  await controller.update(next);
  await ref.read(ruleSyncServiceProvider).saveNow(next);
  final desc = 'Added filter rule (now ${next.rules.length} total): '
      '${newRule.sender?.value ?? newRule.subject?.value ?? newRule.body?.value ?? "(empty)"}';
  recordAgentFact(ref, AgentFact(kind: 'filter_rule_added', description: desc));
  return desc;
}

Future<String> _execUpdateFilterRule(WidgetRef ref, Map<String, Object?> p) async {
  final idx = (p['index'] as num?)?.toInt();
  if (idx == null) throw ArgumentError('Need an index to identify the rule');
  final updates = (p['updates'] as Map<String, Object?>?) ?? const {};
  if (updates.isEmpty) throw ArgumentError('No fields to update');

  final controller = ref.read(gmailFilterRulesProvider.notifier);
  final current = ref.read(gmailFilterRulesProvider);
  if (idx < 0 || idx >= current.rules.length) {
    throw ArgumentError('Rule index $idx out of range');
  }
  var rule = current.rules[idx];
  if (updates.containsKey('sender')) {
    rule = rule.copyWith(
      sender: _parseRuleField(updates['sender']),
      clearSender: updates['clear_sender'] == true,
    );
  }
  if (updates.containsKey('subject')) {
    rule = rule.copyWith(
      subject: _parseRuleField(updates['subject']),
      clearSubject: updates['clear_subject'] == true,
    );
  }
  if (updates.containsKey('body')) {
    rule = rule.copyWith(
      body: _parseRuleField(updates['body']),
      clearBody: updates['clear_body'] == true,
    );
  }
  final next = current.copyWith(
    rules: [...current.rules]..[idx] = rule,
  );
  await controller.update(next);
  await ref.read(ruleSyncServiceProvider).saveNow(next);
  final desc = 'Updated filter rule #$idx';
  recordAgentFact(ref, AgentFact(kind: 'filter_rule_updated', description: desc));
  return desc;
}

Future<String> _execDeleteFilterRule(WidgetRef ref, Map<String, Object?> p) async {
  final controller = ref.read(gmailFilterRulesProvider.notifier);
  final current = ref.read(gmailFilterRulesProvider);
  if (current.rules.isEmpty) throw ArgumentError('No filter rules to delete');

  final idxStr = p['index'];
  int? idx;
  if (idxStr is num) {
    idx = idxStr.toInt();
  } else if (idxStr is String) {
    idx = int.tryParse(idxStr);
  }
  if (idx != null) {
    if (idx < 0 || idx >= current.rules.length) {
      throw ArgumentError('Rule index $idx out of range');
    }
    final next = current.copyWith(rules: [...current.rules]..removeAt(idx));
    await controller.update(next);
    await ref.read(ruleSyncServiceProvider).saveNow(next);
    final desc = 'Deleted filter rule #$idx';
    recordAgentFact(ref, AgentFact(kind: 'filter_rule_deleted', description: desc));
    return desc;
  }
  final m = p['match'] as Map<String, Object?>?;
  if (m == null) {
    throw ArgumentError('Need either "index" or "match" to delete a rule');
  }
  final findIdx = current.rules.indexWhere((r) {
    if (m['sender'] is String) {
      if (r.sender == null || r.sender!.value != m['sender']) return false;
    }
    if (m['subject'] is String) {
      if (r.subject == null || r.subject!.value != m['subject']) return false;
    }
    if (m['body'] is String) {
      if (r.body == null || r.body!.value != m['body']) return false;
    }
    return true;
  });
  if (findIdx < 0) {
    throw ArgumentError('No rule matches the given sender/subject/body');
  }
  final next = current.copyWith(rules: [...current.rules]..removeAt(findIdx));
  await controller.update(next);
  await ref.read(ruleSyncServiceProvider).saveNow(next);
  final desc = 'Deleted filter rule #$findIdx';
  recordAgentFact(ref, AgentFact(kind: 'filter_rule_deleted', description: desc));
  return desc;
}

Future<String> _execSetFilterMode(WidgetRef ref, Map<String, Object?> p) async {
  final controller = ref.read(gmailFilterRulesProvider.notifier);
  var current = ref.read(gmailFilterRulesProvider);
  if (p.containsKey('enabled')) {
    current = current.copyWith(enabled: p['enabled'] == true);
  }
  if (p['logic'] is String) {
    current = current.copyWith(
      logic: Logic.values.firstWhere(
        (l) => l.name == p['logic'],
        orElse: () => current.logic,
      ),
    );
  }
  await controller.update(current);
  await ref.read(ruleSyncServiceProvider).saveNow(current);
  return 'Filter mode: '
      '${current.enabled ? 'on' : 'off'}, logic=${current.logic.name}';
}

Future<String> _execSyncGmailNow(WidgetRef ref, Map<String, Object?> p) async {
  final sync = ref.read(gmailSyncProvider);
  final n = await sync.fetchNew();
  ref.invalidate(transactionsProvider);
  ref.invalidate(activeBudgetProvider);
  final desc = 'Synced Gmail: $n new transaction${n == 1 ? '' : 's'}';
  recordAgentFact(ref, AgentFact(kind: 'gmail_synced', description: desc));
  return desc;
}

Future<String> _execDisconnectGmail(WidgetRef ref, Map<String, Object?> p) async {
  final gmail = ref.read(gmailAuthProvider);
  await gmail.signOut();
  ref.invalidate(gmailConnectedProvider);
  return 'Disconnected Gmail';
}

Future<String> _execBulkDeleteTransactions(WidgetRef ref, Map<String, Object?> p) async {
  final repo = ref.read(transactionRepoProvider);
  final all = await repo.recent(limit: 5000);

  final source = (p['source'] as String?)?.toLowerCase();
  final merchantContains =
      (p['merchant_contains'] as String?)?.toLowerCase();
  final before = (p['before'] as String?) != null
      ? DateTime.parse(p['before'] as String)
          .add(const Duration(days: 1))
      : null;
  final after = (p['after'] as String?) != null
      ? DateTime.parse(p['after'] as String)
      : null;
  final minAmount = (p['min_amount'] as num?)?.toDouble();
  final maxAmount = (p['max_amount'] as num?)?.toDouble();
  final includeIgnored = p['include_ignored'] == true;

  final matches = all.where((t) {
    if (!includeIgnored && t.ignored) return false;
    if (source != null && t.source.toLowerCase() != source) return false;
    if (merchantContains != null &&
        !t.merchant.toLowerCase().contains(merchantContains)) {
      return false;
    }
    if (before != null && !t.occurredAt.isBefore(before)) return false;
    if (after != null && !t.occurredAt.isAfter(after)) return false;
    final absAmt = t.amount.abs();
    if (minAmount != null && absAmt < minAmount) return false;
    if (maxAmount != null && absAmt > maxAmount) return false;
    return true;
  }).toList();

  if (matches.isEmpty) return 'No transactions matched those filters';

  for (final t in matches) {
    if (t.id != null) await repo.deleteById(t.id!);
  }
  ref.invalidate(transactionsProvider);
  ref.invalidate(activeBudgetProvider);
  return 'Deleted ${matches.length} transaction${matches.length == 1 ? '' : 's'}';
}

Future<String> _execDeleteActivityLogEntry(WidgetRef ref, Map<String, Object?> p) async {
  final id = (p['id'] as num?)?.toInt();
  if (id == null) {
    throw ArgumentError('Need an id to delete a log entry');
  }
  final n = await AiLogStore.deleteById(id);
  ref.invalidate(aiLogProvider);
  return n == 0
      ? 'No log entry with id $id (already deleted?)'
      : 'Deleted log entry #$id';
}

Future<String> _execManageAiApiKey(
  WidgetRef ref,
  BuildContext context,
  Map<String, Object?> p,
) async {
  if (!context.mounted) return 'AI key screen closed';
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => const AiModelScreen()),
  );
  // Invalidate so the model sees fresh has_api_key on the next turn.
  ref.invalidate(aiConfigProvider);
  return 'Opened AI model settings';
}

Future<String> _execReplaceFilterRules(WidgetRef ref, Map<String, Object?> p) async {
  final raw = (p['rules'] as List?) ?? const [];
  if (raw.isEmpty) {
    throw ArgumentError('Need at least one rule in "rules"');
  }
  final newRules = raw
      .whereType<Map<String, Object?>>()
      .map(_parseRule)
      .where((r) => !r.isEmpty)
      .toList(growable: false);
  if (newRules.isEmpty) {
    throw ArgumentError('No usable rules in the supplied list');
  }
  final controller = ref.read(gmailFilterRulesProvider.notifier);
  final current = ref.read(gmailFilterRulesProvider);
  final next = current.copyWith(rules: newRules);
  await controller.update(next);
  await ref.read(ruleSyncServiceProvider).saveNow(next);
  final desc = 'Replaced filter rules (now ${next.rules.length} total)';
  recordAgentFact(ref, AgentFact(kind: 'filter_rules_replaced', description: desc));
  return desc;
}

Future<String> _execSignInGmail(WidgetRef ref, Map<String, Object?> p) async {
  final email = await ref.read(gmailAuthProvider).signIn();
  // Mirror the UI sign-in flow: restore the cloud snapshot so the
  // device matches the user's authoritative state. Swallow the
  // "no backup yet" result — first-time sign-ins don't have one.
  final result = await autoRestoreAfterSignIn(ref);
  ref.invalidate(gmailConnectedProvider);
  if (email == null) return 'Sign-in cancelled';
  if (result.success) {
    return 'Signed in as $email · restored ${result.transactions} '
        'transactions, ${result.budgets} budgets';
  }
  return 'Signed in as $email';
}

Future<String> _execResetGmailSignin(WidgetRef ref, Map<String, Object?> p) async {
  await ref.read(gmailAuthProvider).wipeAndReset();
  ref.invalidate(gmailConnectedProvider);
  return 'Reset Google sign-in — try again';
}

/// Triggers the Android 13+ POST_NOTIFICATIONS prompt. Safe to call
/// repeatedly; the OS short-circuits if the user has already
/// granted/denied.
Future<String> _execRequestNotificationPermission(
  WidgetRef ref,
  Map<String, Object?> p,
) async {
  final svc = ref.read(notificationServiceProvider);
  await svc.requestPermission();
  final granted = await svc.areNotificationsEnabled();
  return granted
      ? 'Notifications enabled — you\'ll get budget alerts'
      : 'Notifications denied — adjust in system Settings to receive alerts';
}

/// Mutates the user's [BackupPreferences] — auto-backup master switch,
/// daily time (hour:minute in device-local), frequency, and the four
/// per-event notification toggles. Only fields present in [p] are
/// applied; everything else is preserved. Mirrors the per-field setters
/// in [BackupPreferencesController] so the Settings screen's UI updates
/// the moment the action confirms.
///
/// Flushes via [BackupPreferencesController.save] once at the end —
/// one Firestore PATCH + one Cloud Scheduler POST for the whole agent
/// command, regardless of how many sub-fields it touched. The
/// controller handles the "did anything change?" check so the
/// "unchanged" path still maps to a single no-op round-trip-pair.
Future<String> _execUpdateBackupPreferences(
  WidgetRef ref,
  Map<String, Object?> p,
) async {
  final ctrl = ref.read(backupPreferencesProvider.notifier);
  final changes = <String>[];

  if (p.containsKey('enabled')) {
    final v = p['enabled'];
    if (v is! bool) {
      throw ArgumentError('enabled must be a bool, got ${v.runtimeType}');
    }
    ctrl.setEnabled(v);
    changes.add('auto-backup ${v ? 'on' : 'off'}');
  }

  if (p.containsKey('hour') || p.containsKey('minute')) {
    final current = ref.read(backupPreferencesProvider);
    final h = (p['hour'] as int?) ?? current.hour;
    final m = (p['minute'] as int?) ?? current.minute;
    if (h < 0 || h > 23 || m < 0 || m > 59) {
      throw ArgumentError('hour must be 0..23, minute 0..59 (got $h:$m)');
    }
    ctrl.setTime(h, m);
    changes.add('time set to $h:${m.toString().padLeft(2, '0')}');
  }

  if (p.containsKey('frequency')) {
    final name = p['frequency'] as String?;
    final freq = BackupFrequency.values.firstWhere(
      (f) => f.name == name,
      orElse: () => throw ArgumentError(
          'frequency must be daily|weekly|monthly (got $name)'),
    );
    ctrl.setFrequency(freq);
    changes.add('frequency → ${freq.label}');
  }

  void setNotify(String key, void Function(bool) setter) {
    if (!p.containsKey(key)) return;
    final v = p[key];
    if (v is! bool) {
      throw ArgumentError('$key must be a bool, got ${v.runtimeType}');
    }
    setter(v);
    changes.add('${_friendlyNotifyName(key)} ${v ? 'on' : 'off'}');
  }

  setNotify('notify_on_backup_complete', ctrl.setNotifyOnBackupComplete);
  setNotify('notify_on_backup_failed', ctrl.setNotifyOnBackupFailed);
  setNotify('notify_on_restore_complete', ctrl.setNotifyOnRestoreComplete);

  if (changes.isEmpty) {
    return 'Backup settings unchanged';
  }

  // Single round-trip-pair covers everything: the Firestore PATCH
  // writes every staged `backupPrefs` field; the scheduler POST
  // creates / updates / deletes `pocket-backup-{sub}` based on the
  // current `state.enabled`. `save()` returns success without doing
  // anything when `_dirty` is false, so a no-op edit session still
  // costs zero network calls.
  final result = await ctrl.save();
  if (!result.success) {
    changes.add('cloud save failed (${result.reason})');
  }
  return 'Backup settings: ${changes.join(', ')}';
}

/// On-demand "back up now" — same wire call as the manual button on
/// Settings → Backup. Mirrors the settings-screen behavior end-to-end:
/// the in-app notification fires on success/failure exactly the same
/// way (gated on `notify_on_backup_complete` / `notify_on_backup_failed`)
/// so the user gets the same banner whether they tap the button or ask
/// the agent. The card text just summarizes the row counts.
Future<String> _execBackupNow(WidgetRef ref) async {
  final svc = ref.read(backupServiceProvider);
  final prefs = ref.read(backupPreferencesProvider);
  final result = await svc.upload();
  if (!result.success) {
    if (prefs.notifyOnBackupFailed) {
      // Fire-and-forget: notification failure shouldn't bubble into the
      // chat as an exception — match the settings path which calls
      // notifyFailure after the upload attempt.
      unawaited(svc.notifyFailure(result.reason ?? 'Unknown error'));
    }
    throw StateError('Backup failed: ${result.reason ?? "unknown error"}');
  }
  final ts = result.uploadedAt != null
      ? TimeFormat.dateTime(result.uploadedAt!)
      : 'just now';
  // Bust the cached snapshot so a follow-up "what's in my backup"
  // question reads fresh state.
  ref.invalidate(backupPreferencesProvider);
  if (prefs.notifyOnBackupComplete) {
    unawaited(
      svc.notifySuccess(
        transactions: result.transactions,
        budgets: result.budgets,
      ),
    );
  }
  return 'Backed up ${result.transactions} transactions and '
      '${result.budgets} budgets at $ts';
}

/// On-demand "restore now" — wipes the local SQLite and replaces it
/// with the rows from `backups/{sub}`. Marked DESTRUCTIVE in the
/// system prompt and added to `_kDestructiveVerbs` so the user gets a
/// type-to-confirm modal before anything runs. Fires the same in-app
/// notification banner the settings-screen path fires, gated on
/// `notify_on_restore_complete`.
Future<String> _execRestoreNow(WidgetRef ref) async {
  final svc = ref.read(backupServiceProvider);
  final prefs = ref.read(backupPreferencesProvider);
  final result = await svc.restore();
  if (!result.success) {
    throw StateError('Restore failed: ${result.reason ?? "unknown error"}');
  }
  // Refresh every provider that depends on transactions/budgets so
  // the dashboard reflects the restored rows immediately.
  ref.invalidate(transactionsProvider);
  ref.invalidate(budgetsProvider);
  ref.invalidate(activeBudgetProvider);
  ref.invalidate(backupPreferencesProvider);
  final ts = result.uploadedAt != null
      ? TimeFormat.dateTime(result.uploadedAt!)
      : 'unknown time';
  if (prefs.notifyOnRestoreComplete) {
    unawaited(
      svc.notifyRestoreComplete(
        transactions: result.transactions,
        budgets: result.budgets,
      ),
    );
  }
  return 'Restored ${result.transactions} transactions and '
      '${result.budgets} budgets (backup from $ts)';
}

String _friendlyNotifyName(String key) => switch (key) {
      'notify_on_backup_complete' => 'backup-complete notif',
      'notify_on_backup_failed' => 'backup-failed notif',
      'notify_on_restore_complete' => 'restore-complete notif',
      _ => key,
    };

/// Renders an [AgentActionPlan] (a chain of dependent mutations) as a
/// single confirm card. The user sees all steps up front with one
/// Confirm button; on confirm we run them sequentially and update each
/// step's row to ✓ / ✗ as we go. The plan stops on the first error —
/// remaining steps stay in the pending state so the user can see how
/// far the chain got.
///
/// Destructive steps in the plan get a single combined type-confirm
/// modal at the top (lists every destructive step) instead of one modal
/// per step — keeps the user flow to two confirmations total even on
/// plans with several destructive verbs.
class _PlanWidget extends ConsumerStatefulWidget {
  const _PlanWidget({
    required this.plan,
    required this.index,
    required this.status,
  });

  final AgentActionPlan plan;
  final int index;
  final AgentActionStatus? status;

  @override
  ConsumerState<_PlanWidget> createState() => _PlanWidgetState();
}

class _PlanWidgetState extends ConsumerState<_PlanWidget> {
  bool _busy = false;
  int? _runningStep;
  final List<String?> _results = [];
  final List<Object?> _errors = [];

  @override
  void initState() {
    super.initState();
    _results.addAll(List<String?>.filled(widget.plan.steps.length, null));
    _errors.addAll(List<Object?>.filled(widget.plan.steps.length, null));
  }

  IconData _iconFor(String name) => switch (name) {
    'create_budget' || 'update_budget' || 'set_active_budget' =>
      Icons.savings_rounded,
    'delete_budget' => Icons.delete_outline_rounded,
    'create_expense' || 'update_transaction' => Icons.receipt_long_rounded,
    'delete_expense' || 'delete_transaction' => Icons.delete_outline_rounded,
    'bulk_delete_transactions' => Icons.delete_sweep_rounded,
    'set_ignored' => Icons.visibility_off_rounded,
    'clear_ai_log' || 'delete_activity_log_entry' =>
      Icons.delete_sweep_rounded,
    'export_csv' => Icons.ios_share_rounded,
    'update_ai_config' => Icons.auto_awesome_rounded,
    'manage_ai_api_key' => Icons.key_rounded,
    'add_filter_rule' ||
    'update_filter_rule' ||
    'delete_filter_rule' ||
    'set_filter_mode' ||
    'replace_filter_rules' => Icons.rule_rounded,
    'sync_gmail_now' => Icons.sync_rounded,
    'disconnect_gmail' => Icons.logout_rounded,
    'sign_in_gmail' => Icons.login_rounded,
    'reset_gmail_signin' => Icons.restart_alt_rounded,
    'request_notification_permission' => Icons.notifications_active_rounded,
    'update_backup_preferences' => Icons.cloud_sync_rounded,
    'backup_now' => Icons.cloud_upload_rounded,
    'restore_now' => Icons.cloud_download_rounded,
    _ => Icons.auto_awesome_rounded,
  };

  String _fallback(String name) => switch (name) {
    'create_budget' => 'Create a new budget',
    'update_budget' => 'Update a budget',
    'delete_budget' => 'Delete a budget',
    'set_active_budget' => 'Switch active budget',
    'create_expense' => 'Add an expense',
    'update_transaction' => 'Update a transaction',
    'delete_expense' => 'Delete an expense',
    'delete_transaction' => 'Delete a transaction',
    'bulk_delete_transactions' => 'Bulk-delete transactions',
    'set_ignored' => 'Ignore from spending',
    'clear_ai_log' => 'Clear the activity log',
    'delete_activity_log_entry' => 'Delete an activity log entry',
    'export_csv' => 'Export a CSV',
    'update_ai_config' => 'Update AI settings',
    'manage_ai_api_key' => 'Open AI model settings',
    'add_filter_rule' => 'Add a Gmail filter rule',
    'update_filter_rule' => 'Update a Gmail filter rule',
    'delete_filter_rule' => 'Delete a Gmail filter rule',
    'set_filter_mode' => 'Update Gmail filter mode',
    'replace_filter_rules' => 'Replace all Gmail filter rules',
    'sync_gmail_now' => 'Sync Gmail now',
    'disconnect_gmail' => 'Disconnect Gmail',
    'sign_in_gmail' => 'Sign in with Google',
    'reset_gmail_signin' => 'Reset Google sign-in',
    'request_notification_permission' => 'Enable notifications',
    'update_backup_preferences' => 'Update backup settings',
    'backup_now' => 'Back up now',
    'restore_now' => 'Restore from cloud',
    _ => 'Run action',
  };

  Future<void> _confirm() async {
    // Single combined type-confirm for every destructive step in the
    // plan. The user already approved the plan by tapping Confirm; the
    // second modal just adds the "type to confirm" gate that destructive
    // verbs require (matching the single-action card's behavior).
    final destructive = [
      for (final s in widget.plan.steps)
        if (_isDestructive(s.name)) s,
    ];
    if (destructive.isNotEmpty) {
      final ok = await _showPlanDestructiveConfirm(
        context: context,
        steps: destructive,
        fallback: (s) => _fallback(s.name),
      );
      if (ok != true) return;
      if (!mounted) return;
    }

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final notifier = ref.read(agentConversationProvider.notifier);

    var failed = 0;
    for (var i = 0; i < widget.plan.steps.length; i++) {
      if (!mounted) return;
      setState(() => _runningStep = i);
      notifier.setPlanStepStatus(widget.index, i, AgentActionStatus.pending);
      try {
        final result =
            await executeAgentAction(ref, context, widget.plan.steps[i]);
        _results[i] = result;
        notifier.setPlanStepStatus(
          widget.index,
          i,
          AgentActionStatus.confirmed,
        );
      } catch (e) {
        _errors[i] = e;
        failed++;
        notifier.setPlanStepStatus(
          widget.index,
          i,
          AgentActionStatus.cancelled,
        );
        if (mounted) {
          messenger.showSnackBar(SnackBar(
            content: Text('Step ${i + 1} failed: $e'),
          ));
        }
        break;
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      _runningStep = null;
    });

    if (failed == 0) {
      messenger.showSnackBar(SnackBar(
        content: Text(
          'Plan complete · ${widget.plan.steps.length} '
          'step${widget.plan.steps.length == 1 ? '' : 's'}',
        ),
      ));
    } else {
      // Mark the plan as confirmed too so the conversation history
      // collapses to a compact card on the next rebuild.
      ref
          .read(agentConversationProvider.notifier)
          .setActionStatus(widget.index, AgentActionStatus.confirmed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final steps = widget.plan.steps;
    final status = widget.status;
    final body = widget.plan.body.trim();
    final allDone = _results.every((r) => r != null);

    if (status == AgentActionStatus.confirmed || allDone) {
      return _CompactCard(
        accent: AppColors.success,
        icon: Icons.checklist_rounded,
        text: 'Done · ${steps.length} step${steps.length == 1 ? '' : 's'}',
        subtle: status == null && !allDone,
      );
    }
    if (status == AgentActionStatus.cancelled) {
      return _CompactCard(
        accent: scheme.outline,
        icon: Icons.close_rounded,
        text: 'Plan cancelled',
        subtle: true,
        strikethrough: true,
      );
    }

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.checklist_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  'Plan · ${steps.length} step${steps.length == 1 ? '' : 's'}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                InkWell(
                  onTap: () => ref
                      .read(agentConversationProvider.notifier)
                      .setActionStatus(
                        widget.index,
                        AgentActionStatus.cancelled,
                      ),
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              MarkdownText(
                body,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            for (var i = 0; i < steps.length; i++) ...[
              _PlanStepRow(
                index: i,
                spec: steps[i],
                icon: _iconFor(steps[i].name),
                fallback: _fallback(steps[i].name),
                result: _results[i],
                error: _errors[i],
                running: _busy && _runningStep == i,
                pending: _busy && _runningStep != null && _runningStep! > i,
              ),
              if (i < steps.length - 1) const SizedBox(height: AppSpacing.xs),
            ],
            const SizedBox(height: AppSpacing.sm),
            Align(
              alignment: Alignment.centerRight,
              child: _PillButton(
                label: 'Run plan',
                busy: _busy,
                onPressed: _confirm,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row inside [_PlanWidget]'s plan list. Shows a numbered bullet,
/// the action icon + fallback description, and a status icon on the
/// right that flips pending → spinner → check / cross as the step
/// progresses through the runner.
class _PlanStepRow extends StatelessWidget {
  const _PlanStepRow({
    required this.index,
    required this.spec,
    required this.icon,
    required this.fallback,
    required this.result,
    required this.error,
    required this.running,
    required this.pending,
  });

  final int index;
  final AgentActionSpec spec;
  final IconData icon;
  final String fallback;
  final String? result;
  final Object? error;
  final bool running;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDone = result != null;
    final isError = error != null;
    final statusIcon = isError
        ? Icons.close_rounded
        : isDone
            ? Icons.check_rounded
            : running
                ? Icons.more_horiz_rounded
                : pending
                    ? Icons.circle_outlined
                    : Icons.circle_outlined;
    final statusColor = isError
        ? AppColors.danger
        : isDone
            ? AppColors.success
            : running
                ? scheme.primary
                : scheme.outline;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            '${index + 1}.',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2, right: 6),
          child: Icon(icon, size: 14, color: scheme.primary),
        ),
        Expanded(
          child: Text(
            isError
                ? '$fallback — failed'
                : isDone
                    ? (result ?? fallback)
                    : fallback,
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.35,
              color: isError
                  ? AppColors.danger
                  : isDone
                      ? scheme.onSurface
                      : scheme.onSurface,
              decoration: isError ? TextDecoration.lineThrough : null,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        SizedBox(
          width: 18,
          height: 18,
          child: running
              ? const Padding(
                  padding: EdgeInsets.all(2),
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(statusIcon, size: 16, color: statusColor),
        ),
      ],
    );
  }
}

/// Combined type-confirm modal for destructive steps in a plan. Lists
/// each destructive action so the user can verify what they're about to
/// run; they type the destructive token (e.g. "delete") once and the
/// whole plan proceeds. Falls back to a single-line description if
/// every destructive step has the same token.
Future<bool?> _showPlanDestructiveConfirm({
  required BuildContext context,
  required List<AgentActionSpec> steps,
  required String Function(AgentActionSpec) fallback,
}) {
  final theme = Theme.of(context);
  // All destructive steps share a token prefix (delete_* → "delete"),
  // so prompt for that one. Mixed-token plans (delete + disconnect)
  // ask for the most common token and explain.
  final tokens = steps.map((s) => _destructiveTokenFor(s.name)).toSet();
  final expected = tokens.length == 1
      ? tokens.first
      : steps.any((s) => s.name.startsWith('delete_'))
          ? 'delete'
          : 'confirm';
  final controller = TextEditingController();

  return showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final typed = controller.text;
          final canProceed = typed == expected;
          return AlertDialog(
            icon: Icon(
              Icons.warning_amber_rounded,
              color: AppColors.danger,
              size: 32,
            ),
            title: const Text('Are you sure?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This plan includes destructive steps:',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final s in steps)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '  • ${fallback(s)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  "This can't be undone. Type $expected below to confirm.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Type to confirm',
                    isDense: true,
                  ),
                  onChanged: (_) => setLocal(() {}),
                  onSubmitted: (v) {
                    if (v == expected) Navigator.of(ctx).pop(true);
                  },
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.danger,
                ),
                onPressed: canProceed
                    ? () => Navigator.of(ctx).pop(true)
                    : null,
                child: const Text('Run plan'),
              ),
            ],
          );
        },
      );
    },
  );
}

