import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/ai_config.dart';
import '../../data/models/model_catalog.dart';

/// Searchable modal sheet for picking a model. Lists the catalog for
/// [provider], filtered live by [query]. The currently-selected id
/// (which may not be in the catalog) is shown first with a "Custom"
/// badge. Tapping any row returns its id; typing a free-form name and
/// tapping "Use "value"" returns the typed value.
class ModelPickerSheet extends StatefulWidget {
  const ModelPickerSheet({
    super.key,
    required this.provider,
    required this.current,
  });

  final CloudProvider provider;
  final String current;

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  final _query = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = modelsFor(widget.provider);
    final q = _q.toLowerCase();
    final filtered = q.isEmpty
        ? all
        : all
              .where(
                (m) =>
                    m.id.toLowerCase().contains(q) ||
                    m.label.toLowerCase().contains(q),
              )
              .toList(growable: false);

    final typed = _q.trim();
    final showCustomRow =
        typed.isNotEmpty &&
        !all.any((m) => m.id.toLowerCase() == typed.toLowerCase());

    final items = <_ListItem>[
      if (showCustomRow)
        _ListItem(
          id: typed,
          label: 'Use "$typed"',
          note: 'Custom model id',
          selected: widget.current == typed,
        ),
      ...filtered.map(
        (m) => _ListItem(
          id: m.id,
          label: m.label,
          note: m.note,
          selected: widget.current == m.id,
        ),
      ),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.md),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pagePadding,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Pick a model',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    widget.provider.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.pagePadding,
              ),
              child: TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search ${all.length} models…',
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () {
                            _query.clear();
                            setState(() => _q = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Flexible(
              child: items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Center(
                        child: Text(
                          'No models match.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.pagePadding,
                        vertical: AppSpacing.sm,
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, i) => _ModelRow(
                        key: ValueKey(items[i].id),
                        item: items[i],
                        onTap: () =>
                            Navigator.of(context).pop(items[i].id),
                      ),
                    ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _ListItem {
  const _ListItem({
    required this.id,
    required this.label,
    required this.note,
    required this.selected,
  });
  final String id;
  final String label;
  final String? note;
  final bool selected;
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({super.key, required this.item, required this.onTap});
  final _ListItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isSelected = item.selected;
    final bg = isSelected
        ? scheme.primary.withValues(alpha: 0.10)
        : scheme.surfaceContainerLow;
    final border = isSelected
        ? scheme.primary.withValues(alpha: 0.3)
        : scheme.outlineVariant;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: border,
                width: isSelected ? 1 : 0.8,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.id,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (item.note != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.note!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: isSelected ? scheme.primary : scheme.outline,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
