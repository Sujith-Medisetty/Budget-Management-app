import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../data/services/gmail_filter_rules.dart';
import '../../providers/providers.dart';

/// User-editable Gmail filter rules. By default every Gmail message is
/// processed; turning the master switch on lets the user limit which
/// messages become transactions. Each rule has optional sender /
/// subject / body fields, each independently toggleable between
/// "contains" (substring, case-insensitive) and "regex".
///
/// Across multiple rules the user picks [Logic.or] (any match → process)
/// or [Logic.and] (every rule must match). Within a single rule the
/// fields are implicit AND.
///
/// Saving: changes auto-persist to local SharedPreferences on every
/// keystroke (no data loss if the app dies mid-edit). The Save button
/// in the AppBar pushes the current set to the server with immediate
/// feedback — a snackbar + inline status row. There is no background
/// sync on every keystroke: intermediate (half-typed or partially
/// deleted) states are NOT pushed to the server because the server's
/// diff-then-apply semantics treat each POST as the user's final
/// intent, and intermediate syncs produced spurious deletes/recreates
/// that left the server with fewer filters than the phone showed.
class EmailFiltersScreen extends ConsumerStatefulWidget {
  const EmailFiltersScreen({super.key});

  @override
  ConsumerState<EmailFiltersScreen> createState() => _EmailFiltersScreenState();
}

class _EmailFiltersScreenState extends ConsumerState<EmailFiltersScreen> {
  bool _saving = false;
  DateTime? _lastSyncAt;
  String? _lastError;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    // Pull the canonical state from the server on every screen open
    // so a Gmail-side filter delete (Settings → Filters in Gmail UI)
    // is reflected here. Fire-and-forget: the in-memory controller
    // state updates via `onSynced` once the response lands.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _refresh();
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final ok = await ref.read(ruleSyncServiceProvider).refresh();
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      if (ok) {
        _lastError = null;
        _lastSyncAt = DateTime.now();
      } else if (!_saving) {
        // Don't overwrite a Save-time failure with a refresh-time one.
        _lastError = 'Refresh failed — tap retry';
      }
    });
  }

  Future<void> _onSave() async {
    if (_saving) return;
    final rules = ref.read(gmailFilterRulesProvider);
    setState(() => _saving = true);
    final ok = await ref.read(ruleSyncServiceProvider).saveNow(rules);
    if (!mounted) return;
    final svc = ref.read(ruleSyncServiceProvider);
    final unmirrored = svc.lastSyncUnmirroredCount;
    final errors = svc.lastSyncErrors;
    setState(() {
      _saving = false;
      if (!ok) {
        _lastError = 'Sync failed — tap to retry';
      } else if (errors != null && errors.isNotEmpty) {
        // The save returned 200 but some rules failed to mirror to
        // Gmail — keep the rule on screen but warn loudly. Without
        // this branch, the user sees "saved successfully" with no
        // clue why the filter isn't in Gmail.
        _lastError = 'Saved, but $unmirrored rule'
            '${unmirrored == 1 ? '' : 's'} '
            "didn't mirror to Gmail";
      } else {
        _lastError = null;
      }
      if (ok) _lastSyncAt = DateTime.now();
    });
    if (!ok) {
      showPocketSnackBar(context, 'Sync failed — check connection');
    } else if (errors != null && errors.isNotEmpty) {
      showPocketSnackBar(
        context,
        'Saved — but $unmirrored filter${unmirrored == 1 ? '' : 's'} '
        'rejected by Gmail',
      );
      // Partial success — the local state is saved, but Gmail-side
      // mirroring failed for at least one rule. Stay on screen so the
      // user can see the inline status row + retry; popping here
      // would hide the warning.
    } else {
      showPocketSnackBar(context, 'Filter rules saved');
      // Full success — pop so the user lands back on Settings.
      // Skipped on the partial-failure branch above (and the
      // outright-failure branch which doesn't reach here).
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop(true);
    }
  }

  /// Picks the right callback for the inline status row's Retry
  /// button. Each error message is set from exactly one place (refresh
  /// vs save), so dispatch on the prefix instead of tracking a flag.
  VoidCallback? _retryAction() {
    if (_saving) return null;
    if (_refreshing) return null;
    if (_lastError == null) return null;
    return _lastError!.startsWith('Refresh') ? _refresh : _onSave;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rules = ref.watch(gmailFilterRulesProvider);
    final controller = ref.read(gmailFilterRulesProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Email filters'),
        actions: [
          LoadingIconButton(
            tooltip: 'Refresh from Gmail',
            busy: _refreshing,
            onPressed: _refresh,
            icon: Icons.refresh_rounded,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: LoadingButton.text(
              label: 'Save',
              busyLabel: 'Saving…',
              busy: _saving,
              onPressed: _onSave,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.sm,
          AppSpacing.pagePadding,
          AppSpacing.lg,
        ),
        children: [
          _HeaderCard(
            enabled: rules.enabled,
            onToggle: (v) => controller.update(rules.copyWith(enabled: v)),
            logic: rules.logic,
            onLogicChanged: (l) =>
                controller.update(rules.copyWith(logic: l)),
            ruleCount: rules.rules.length,
          ),
          if (rules.enabled)
            ...rules.rules.asMap().entries.map((e) => Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: _RuleCard(
                    key: ValueKey('rule-${e.key}'),
                    index: e.key,
                    rule: e.value,
                    onChanged: (next) {
                      final list = [...rules.rules];
                      list[e.key] = next;
                      controller.update(rules.copyWith(rules: list));
                    },
                    onDelete: () {
                      final list = [...rules.rules]..removeAt(e.key);
                      controller.update(rules.copyWith(rules: list));
                    },
                  ),
                )),
          if (rules.enabled)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: _AddRuleButton(
                onPressed: () {
                  final list = [...rules.rules, const FilterRule()];
                  controller.update(rules.copyWith(rules: list));
                },
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          if (_lastSyncAt != null || _lastError != null)
            _SyncStatusRow(
              lastSyncAt: _lastSyncAt,
              error: _lastError,
              // Refresh-time failure → retry refresh; save-time
              // failure → retry save. Each does a different network
              // call, so the retry action has to match the failure
              // it came from.
              onRetry: _retryAction(),
            ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
            child: Text(
              'Matching emails are captured as transactions. Everything '
              'else is silently dropped — it never reaches the parser.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Inline status row shown after the first save attempt. Persists until
/// the next sync — gives the user something to look at beyond the
/// fleeting snackbar.
class _SyncStatusRow extends StatelessWidget {
  const _SyncStatusRow({
    required this.lastSyncAt,
    required this.error,
    required this.onRetry,
  });

  final DateTime? lastSyncAt;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isError = error != null;
    final color = isError ? scheme.error : scheme.primary;
    final icon = isError
        ? Icons.error_outline_rounded
        : Icons.check_circle_outline_rounded;
    final text = isError
        ? error!
        : 'Synced at ${_fmtTime(lastSyncAt!)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (isError && onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    final period = t.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m:$s $period';
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.enabled,
    required this.onToggle,
    required this.logic,
    required this.onLogicChanged,
    required this.ruleCount,
  });

  final bool enabled;
  final ValueChanged<bool> onToggle;
  final Logic logic;
  final ValueChanged<Logic> onLogicChanged;
  final int ruleCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.filter_alt_rounded,
                  color: scheme.primary,
                  size: 18,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Capture only matching emails',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        enabled
                            ? (ruleCount == 0
                                ? 'On — no rules, capturing everything'
                                : 'On — capture $ruleCount rule${ruleCount == 1 ? '' : 's'}')
                            : 'Off — capture every Gmail message',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(value: enabled, onChanged: onToggle),
              ],
            ),
            if (enabled) ...[
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Text(
                    'Capture',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SegmentedButton<Logic>(
                    style: ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    segments: [
                      ButtonSegment(
                        value: Logic.or,
                        label: Text(logic == Logic.or ? 'Any match' : 'any match'),
                      ),
                      ButtonSegment(
                        value: Logic.and,
                        label: Text(logic == Logic.and ? 'All match' : 'all match'),
                      ),
                    ],
                    selected: {logic},
                    onSelectionChanged: (s) => onLogicChanged(s.first),
                    showSelectedIcon: false,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RuleCard extends StatefulWidget {
  const _RuleCard({
    super.key,
    required this.index,
    required this.rule,
    required this.onChanged,
    required this.onDelete,
  });

  final int index;
  final FilterRule rule;
  final ValueChanged<FilterRule> onChanged;
  final VoidCallback onDelete;

  @override
  State<_RuleCard> createState() => _RuleCardState();
}

class _RuleCardState extends State<_RuleCard> {
  late final TextEditingController _sender;
  late final TextEditingController _subject;
  late final TextEditingController _body;
  String? _senderError;
  String? _subjectError;
  String? _bodyError;

  @override
  void initState() {
    super.initState();
    _sender = TextEditingController(text: widget.rule.sender?.value ?? '');
    _subject = TextEditingController(text: widget.rule.subject?.value ?? '');
    _body = TextEditingController(text: widget.rule.body?.value ?? '');
    _sender.addListener(_emit);
    _subject.addListener(_emit);
    _body.addListener(_emit);
  }

  @override
  void dispose() {
    _sender.dispose();
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  void _emit() {
    final next = widget.rule.copyWith(
      sender: _fieldFor(_sender, _senderError),
      subject: _fieldFor(_subject, _subjectError),
      body: _fieldFor(_body, _bodyError),
    );
    widget.onChanged(next);
  }

  RuleField? _fieldFor(TextEditingController c, String? error) {
    final v = c.text.trim();
    if (v.isEmpty) return null;
    if (error != null) return null;
    final matchType = _matchTypeFor(c);
    return RuleField(value: v, matchType: matchType);
  }

  MatchType _matchTypeFor(TextEditingController c) {
    if (c == _sender) {
      return widget.rule.sender?.matchType ?? MatchType.contains;
    }
    if (c == _subject) {
      return widget.rule.subject?.matchType ?? MatchType.contains;
    }
    return widget.rule.body?.matchType ?? MatchType.contains;
  }

  void _setMatchType(TextEditingController c, MatchType mt) {
    final v = c.text.trim();
    if (v.isEmpty) return;
    final next = RuleField(value: v, matchType: mt);
    widget.onChanged(widget.rule.copyWith(
      sender: c == _sender ? next : widget.rule.sender,
      subject: c == _subject ? next : widget.rule.subject,
      body: c == _body ? next : widget.rule.body,
    ));
  }

  void _validateRegex(TextEditingController c, ValueChanged<String?> onError) {
    if (c.text.trim().isEmpty) {
      onError(null);
      return;
    }
    final mt = _matchTypeFor(c);
    if (mt != MatchType.regex) {
      onError(null);
      return;
    }
    try {
      RegExp(c.text);
      onError(null);
    } catch (e) {
      onError('Invalid regex');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.xs,
          AppSpacing.xs,
          AppSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    'Rule ${widget.index + 1}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  tooltip: 'Delete rule',
                ),
              ],
            ),
            const SizedBox(height: 2),
            _RuleField(
              label: 'Sender',
              hint: 'paypal.com',
              controller: _sender,
              matchType: widget.rule.sender?.matchType ?? MatchType.contains,
              error: _senderError,
              onMatchTypeChanged: (mt) => _setMatchType(_sender, mt),
              onValidate: () => _validateRegex(_sender, (e) {
                if (mounted) setState(() => _senderError = e);
              }),
            ),
            const SizedBox(height: AppSpacing.xs),
            _RuleField(
              label: 'Subject',
              hint: 'payment',
              controller: _subject,
              matchType: widget.rule.subject?.matchType ?? MatchType.contains,
              error: _subjectError,
              onMatchTypeChanged: (mt) => _setMatchType(_subject, mt),
              onValidate: () => _validateRegex(_subject, (e) {
                if (mounted) setState(() => _subjectError = e);
              }),
            ),
            const SizedBox(height: AppSpacing.xs),
            _RuleField(
              label: 'Body',
              hint: 'you sent \$',
              controller: _body,
              matchType: widget.rule.body?.matchType ?? MatchType.contains,
              error: _bodyError,
              onMatchTypeChanged: (mt) => _setMatchType(_body, mt),
              onValidate: () => _validateRegex(_body, (e) {
                if (mounted) setState(() => _bodyError = e);
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleField extends StatelessWidget {
  const _RuleField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.matchType,
    required this.error,
    required this.onMatchTypeChanged,
    required this.onValidate,
  });

  final String label;
  final String hint;
  final TextEditingController controller;
  final MatchType matchType;
  final String? error;
  final ValueChanged<MatchType> onMatchTypeChanged;
  final VoidCallback onValidate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: (_) => onValidate(),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              errorText: error,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide(color: scheme.outlineVariant),
              ),
            ),
            style: theme.textTheme.bodyMedium,
            inputFormatters: matchType == MatchType.regex
                ? null
                : [LengthLimitingTextInputFormatter(120)],
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        _RegexChip(
          matchType: matchType,
          onChanged: onMatchTypeChanged,
        ),
      ],
    );
  }
}

class _RegexChip extends StatelessWidget {
  const _RegexChip({required this.matchType, required this.onChanged});
  final MatchType matchType;
  final ValueChanged<MatchType> onChanged;

  @override
  Widget build(BuildContext context) {
    final isRegex = matchType == MatchType.regex;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.sm),
      onTap: () => onChanged(isRegex ? MatchType.contains : MatchType.regex),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: isRegex
              ? scheme.primary.withValues(alpha: 0.12)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isRegex ? Icons.code_rounded : Icons.text_fields_rounded,
              size: 12,
              color: isRegex ? scheme.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 3),
            Text(
              isRegex ? 'regex' : 'contains',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isRegex ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AddRuleButton extends StatelessWidget {
  const _AddRuleButton({required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add_rounded, size: 16),
      label: const Text('Add rule'),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(38),
        padding: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
