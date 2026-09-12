import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format/ai_text.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/loading_button.dart';
import '../../core/widgets/pocket_snackbar.dart';
import '../../data/models/ai_config.dart';
import '../../data/models/model_catalog.dart';
import '../../data/models/parsed_transaction.dart';
import '../../data/models/raw_notification.dart';
import '../../data/services/cloud_ai_parser.dart';
import '../../providers/providers.dart';
import 'model_picker_sheet.dart';

/// Functional AI model picker. Three sections:
///   1. Provider picker (OpenAI / Anthropic / Google AI Studio, or any
///      OpenAI-compatible host via the "Custom" row)
///   2. Model + (for custom) base URL + API key entry
///   3. Help link for getting an API key
///
/// All edits write through [AiKeyStore]. "Test connection" sends a
/// single minimal notification through the cloud parser and reports
/// success/failure so the user can verify their key before saving.
///
/// Pocket parses strictly through the cloud AI — there is no fallback.
/// Without a key, notifications come in but never become transactions.
class AiModelScreen extends ConsumerStatefulWidget {
  const AiModelScreen({super.key});

  @override
  ConsumerState<AiModelScreen> createState() => _AiModelScreenState();
}

class _AiModelScreenState extends ConsumerState<AiModelScreen> {
  late CloudProvider _provider;
  late TextEditingController _model;
  late TextEditingController _baseUrl;
  late TextEditingController _key;
  bool _obscureKey = true;
  bool _saving = false;
  _TestState _test = const _TestIdle();

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(aiConfigProvider).valueOrNull;
    _provider = cfg?.provider ?? CloudProvider.openai;
    _model = TextEditingController(
      text: (cfg?.model.isNotEmpty ?? false) ? cfg!.model : _provider.defaultModel,
    );
    _baseUrl = TextEditingController(text: cfg?.baseUrl ?? '');
    _key = TextEditingController();
  }

  @override
  void dispose() {
    _model.dispose();
    _baseUrl.dispose();
    _key.dispose();
    super.dispose();
  }

  bool get _isCustom => _provider == CloudProvider.custom;

  Future<void> _onProviderChanged(CloudProvider p) async {
    setState(() {
      _provider = p;
      // Reset model name to the new provider's default; the user can
      // always edit it again. Skip for custom since we don't know the
      // user's model yet — leave whatever they typed.
      if (p != CloudProvider.custom) _model.text = p.defaultModel;
    });
    final store = await ref.read(aiKeyStoreProvider.future);
    await store.writeProvider(p);
    if (p != CloudProvider.custom) {
      await store.writeModel(p.defaultModel);
    }
    if (!mounted) return;
    ref.invalidate(aiConfigProvider);
  }

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final store = await ref.read(aiKeyStoreProvider.future);
      await store.writeProvider(_provider);
      await store.writeModel(_model.text.trim());
      await store.writeBaseUrl(_isCustom ? _baseUrl.text.trim() : null);
      await store.writeKey(_provider, _key.text.trim());
      if (!mounted) return;
      ref.invalidate(aiConfigProvider);
      showPocketSnackBar(context, 'Saved');
      // Pop on success so the user lands back on Settings immediately.
      // Writes are local + synchronous (SharedPreferences), so the
      // snackbar plus pop is the success signal — no failure path
      // to worry about here.
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    try {
      await _runTest().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _test = const _TestFailed(
            'Test hung for 15 s — aborted. '
            'Tap Test again to retry.',
          ));
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _test = _TestFailed('Test failed: $e'));
      return;
    }
  }

  Future<void> _runTest() async {
    if (_isCustom && _baseUrl.text.trim().isEmpty) {
      setState(() => _test = const _TestFailed(
            'Enter a base URL first — e.g. https://api.deepseek.com/v1',
          ));
      return;
    }
    final store = await ref.read(aiKeyStoreProvider.future);
    final apiKey = _key.text.trim().isNotEmpty
        ? _key.text.trim()
        : (await store.readKey(_provider)) ?? '';
    if (apiKey.isEmpty) {
      setState(() => _test = const _TestFailed('No API key yet — paste one above.'));
      return;
    }
    setState(() => _test = const _TestRunning());
    final ai = CloudAiParser(
      config: AiConfig(
        provider: _provider,
        model: _model.text.trim().isEmpty
            ? _provider.defaultModel
            : _model.text.trim(),
        hasKey: true,
        baseUrl: _isCustom ? _baseUrl.text.trim() : null,
      ),
      apiKey: apiKey,
    );
    final probe = RawNotification(
      notificationKey: 'test-${DateTime.now().millisecondsSinceEpoch}',
      packageName: 'com.paypal.android.p2pmobile',
      title: 'You sent \$1.00 USD to Test Merchant.',
      text: 'You sent \$1.00 USD to Test Merchant.',
      postedAt: DateTime.now(),
    );
    final stopwatch = Stopwatch()..start();
    final ({ParsedTransaction? parsed, String? rawBody}) result;
    try {
      result = await ai
          .parseWithRaw(probe)
          .timeout(const Duration(seconds: 12));
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _test = const _TestFailed(
            'Timed out after 12 s. Check the model name, base URL, '
            'or your network.',
          ));
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _test = _TestFailed('Request failed: $e'));
      return;
    }
    stopwatch.stop();
    if (!mounted) return;
    if (result.parsed != null) {
      setState(() => _test = _TestSuccess(
            '${result.parsed!.amount.toStringAsFixed(2)} '
            '${result.parsed!.source} · '
            '${stopwatch.elapsedMilliseconds} ms',
          ));
      return;
    }
    final raw = result.rawBody;
    if (raw == null || raw.isEmpty) {
      setState(() => _test = const _TestFailed(
            'Reachable, but the response body was empty.',
          ));
      return;
    }
    final preview = raw.length > 220 ? '${raw.substring(0, 220)}…' : raw;
    setState(() => _test = _TestFailed(
      'Reachable, but no usable JSON.\nModel said:\n$preview',
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI model'),
        actions: [
          LoadingButton.text(
            label: 'Save',
            busyLabel: 'Saving…',
            busy: _saving,
            onPressed: _saveAll,
          ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.md,
          AppSpacing.pagePadding,
          AppSpacing.floatingBarContentPadding,
        ),
        children: [
          _SectionLabel('Provider'),
          const SizedBox(height: AppSpacing.sm),
          RepaintBoundary(
            child: _ProviderPicker(
              value: _provider,
              onChanged: _onProviderChanged,
            ),
          ),
          const SizedBox(height: AppSpacing.sectionGap),
          _SectionLabel('Model'),
          const SizedBox(height: AppSpacing.sm),
          RepaintBoundary(
            child: _isCustom
                ? TextField(
                    controller: _model,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Model name',
                      hintText:
                          'e.g. deepseek-chat, mixtral-8x7b, llama-3.1-70b',
                    ),
                  )
                : _ModelPickerRow(
                    provider: _provider,
                    current: _model.text,
                    onPick: (v) => setState(() {
                      _model.text = v;
                      _model.selection =
                          TextSelection.collapsed(offset: v.length);
                    }),
                  ),
          ),
          if (_isCustom) ...[
            const SizedBox(height: AppSpacing.lg),
            _SectionLabel('Base URL'),
            const SizedBox(height: AppSpacing.sm),
            RepaintBoundary(
              child: TextField(
                controller: _baseUrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'https://…/v1',
                  hintText: 'e.g. https://api.deepseek.com/v1',
                  helperText: 'We append /chat/completions to this.',
                ),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _SectionLabel('API key'),
          const SizedBox(height: AppSpacing.sm),
          RepaintBoundary(
            child: TextField(
              controller: _key,
              obscureText: _obscureKey,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'\s')),
              ],
              decoration: InputDecoration(
                labelText: 'Paste your key',
                hintText: 'Stored on-device, never sent to us',
                suffixIcon: IconButton(
                  icon: Icon(_obscureKey
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () =>
                      setState(() => _obscureKey = !_obscureKey),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _test is _TestRunning ? null : _testConnection,
                  icon: const Icon(Icons.wifi_tethering_rounded, size: 18),
                  label: Text(
                    _test is _TestRunning
                        ? 'Testing…'
                        : 'Test connection',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _TestStatusTile(state: _test),
          const SizedBox(height: AppSpacing.lg),
          _HelpLink(provider: _provider),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.sm),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
      ),
    );
  }
}

class _ProviderPicker extends StatelessWidget {
  const _ProviderPicker({required this.value, required this.onChanged});
  final CloudProvider value;
  final ValueChanged<CloudProvider> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final p in CloudProvider.values) ...[
          _ProviderTile(
            provider: p,
            selected: p == value,
            onTap: () => onChanged(p),
          ),
          if (p != CloudProvider.values.last) const SizedBox(height: AppSpacing.sm),
        ],
      ],
    );
  }
}

class _ProviderTile extends StatelessWidget {
  const _ProviderTile({
    required this.provider,
    required this.selected,
    required this.onTap,
  });
  final CloudProvider provider;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: selected
                      ? theme.colorScheme.primary.withValues(alpha: 0.16)
                      : theme.colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _iconFor(provider),
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      provider.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      provider == CloudProvider.custom
                          ? 'Bring your own OpenAI-compatible host'
                          : provider.defaultModel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              else
                Icon(
                  Icons.radio_button_unchecked_rounded,
                  color: theme.colorScheme.outline,
                  size: 22,
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(CloudProvider p) => switch (p) {
    CloudProvider.openai => Icons.auto_awesome_rounded,
    CloudProvider.anthropic => Icons.bolt_rounded,
    CloudProvider.google => Icons.diamond_rounded,
    CloudProvider.minimax => Icons.flash_on_rounded,
    CloudProvider.custom => Icons.public_rounded,
  };
}

class _HelpLink extends StatelessWidget {
  const _HelpLink({required this.provider});
  final CloudProvider provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Get a key at ${provider.helpUrl}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

class _ModelPickerRow extends StatelessWidget {
  const _ModelPickerRow({
    required this.provider,
    required this.current,
    required this.onPick,
  });

  final CloudProvider provider;
  final String current;
  final ValueChanged<String> onPick;

  ModelInfo? _matchCatalog() {
    for (final m in modelsFor(provider)) {
      if (m.id == current) return m;
    }
    return null;
  }

  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: false,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => ModelPickerSheet(provider: provider, current: current),
    );
    if (picked != null) onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final match = _matchCatalog();
    final isCustom = match == null;
    final displayLabel = match?.label ?? current;
    final subLabel = isCustom ? 'Custom model id' : current;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.bolt_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            displayLabel.isEmpty ? 'Pick a model' : displayLabel,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isCustom && current.isNotEmpty) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'CUSTOM',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.4,
                                fontSize: 9,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Icon(
                Icons.chevron_right_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

sealed class _TestState {
  const _TestState();
}

class _TestIdle extends _TestState {
  const _TestIdle();
}

class _TestRunning extends _TestState {
  const _TestRunning();
}

class _TestSuccess extends _TestState {
  const _TestSuccess(this.summary);
  final String summary;
}

class _TestFailed extends _TestState {
  const _TestFailed(this.message);
  final String message;
}

class _TestStatusTile extends StatelessWidget {
  const _TestStatusTile({required this.state});
  final _TestState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Color bg;
    Color fg;
    IconData icon;
    String text;
    switch (state) {
      case _TestIdle():
        bg = theme.colorScheme.surfaceContainerHigh;
        fg = theme.colorScheme.onSurfaceVariant;
        icon = Icons.help_outline_rounded;
        text = 'Tap "Test connection" to verify the key.';
      case _TestRunning():
        bg = theme.colorScheme.primary.withValues(alpha: 0.10);
        fg = theme.colorScheme.primary;
        icon = Icons.sync_rounded;
        text = 'Sending test prompt…';
      case _TestSuccess(:final summary):
        bg = AppColors.success.withValues(alpha: 0.14);
        fg = AppColors.success;
        icon = Icons.check_circle_rounded;
        text = 'OK · $summary';
      case _TestFailed(:final message):
        bg = AppColors.danger.withValues(alpha: 0.12);
        fg = AppColors.danger;
        icon = Icons.error_outline_rounded;
        text = message;
    }
    final isMultiline = state is _TestFailed;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: isMultiline
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        text.split('\n').first,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: fg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (text.contains('\n')) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    // Render as markdown so any structure the model
                    // emitted (lists, bold, code) is readable rather
                    // than a wall of monospace text. The body is
                    // already stripped of think-tag blocks upstream.
                    child: MarkdownText(
                      text.split('\n').skip(1).join('\n').trim(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: fg,
                        height: 1.35,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ],
            )
          : Row(
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    text,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
