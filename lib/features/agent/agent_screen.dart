import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../core/theme/app_theme.dart';
import '../../core/widgets/theme_toggle_button.dart';
import '../../data/models/agent_message.dart';
import '../../data/models/agent_response.dart';
import '../../providers/agent_providers.dart';
import '../settings/ai_model_screen.dart';
import 'agent_widgets.dart';

/// Conversational agent over the user's Pocket data. Shows a chat list
/// (user right, assistant left) with an input bar at the bottom. The
/// conversation is held in [agentConversationProvider] with
/// `keepAlive: true` so it survives tab switches — but not app
/// restarts. When the user has no API key configured the screen shows
/// a "Configure AI" empty state instead of an input.
class AgentScreen extends ConsumerStatefulWidget {
  const AgentScreen({super.key});

  @override
  ConsumerState<AgentScreen> createState() => _AgentScreenState();
}

class _AgentScreenState extends ConsumerState<AgentScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // Scroll to the latest message after first paint. `ref.listen` only
    // fires on changes — it doesn't fire on the initial value, so without
    // this the user lands on the screen with the chat scrolled to the
    // top, hiding the most recent reply.
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Public entry point so example tiles can fire the same path as the
  /// send button (validate, append user + placeholder, hit the agent).
  void sendText(String text) {
    _send(text);
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _busy) return;
    final notifier = ref.read(agentConversationProvider.notifier);
    final service = await ref.read(agentServiceProvider.future);

    // Pass the *previous* conversation as history so the agent has
    // full context (last few turns). The user msg we're about to send
    // is passed separately as the current message.
    final history = ref.read(agentConversationProvider);

    notifier.add(AgentMessage.user(trimmed));
    notifier.add(
      const AgentMessage(
        role: AgentMessageRole.assistant,
        response: AgentAnswer(body: '...'),
      ),
    );
    _controller.clear();
    setState(() => _busy = true);

    try {
      final response = await service.send(trimmed, history: history);
      notifier.updateLast(AgentMessage.assistant(response));
    } catch (e) {
      notifier.updateLast(AgentMessage.error("Couldn't reach the AI: $e"));
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(agentConversationProvider);
    final serviceAsync = ref.watch(agentServiceProvider);

    // Whenever messages change, scroll to bottom.
    ref.listen(agentConversationProvider, (_, _) => _scrollToEnd());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent'),
        actions: [
          if (messages.isNotEmpty)
            IconButton(
              tooltip: 'Clear conversation',
              icon: const Icon(Icons.delete_sweep_rounded),
              onPressed: () =>
                  ref.read(agentConversationProvider.notifier).clear(),
            ),
          const ThemeToggleButton(),
        ],
      ),
      body: SafeArea(
        top: false,
        // Agent lives inside MainShell's Stack, which renders the
        // floating pill nav at the bottom. Lift the body just enough
        // so the input bar clears the pill with a tight, modern gap.
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 76),
          child: serviceAsync.when(
          loading: () =>
              const Center(child: CircularProgressIndicator()),
          error: (e, _) => _NoKeyEmptyState(error: e),
          data: (_) => Column(
            children: [
              Expanded(
                child: messages.isEmpty
                    ? const _IdleEmptyState()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          AppSpacing.md,
                          0,
                          AppSpacing.sm,
                        ),
                        itemCount: messages.length + 1,
                        itemBuilder: (_, i) {
                          if (i == messages.length) {
                            return const SizedBox(height: AppSpacing.xl);
                          }
                          return _MessageBubble(
                            message: messages[i],
                            index: i,
                          );
                        },
                      ),
              ),
              _SuggestionStrip(hasText: _controller.text.trim().isNotEmpty),
              _InputBarSlot(),
            ],
          ),
        ),
      ),
    ),
    );
  }
}

/// Indirection so [_AgentScreenState] can pass the controller / callbacks
/// into [_InputBar] without leaking its own state into the wrapper tree.
class _InputBarSlot extends StatelessWidget {
  const _InputBarSlot();
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_AgentScreenState>();
    assert(state != null, 'Input bar must be inside an AgentScreen');
    return _InputBar(
      controller: state!._controller,
      busy: state._busy,
      onSend: state._send,
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.index});
  final AgentMessage message;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (message.role) {
      case AgentMessageRole.user:
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.pagePadding,
            vertical: AppSpacing.xs,
          ),
          child: Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78,
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(AppRadius.lg),
                    topRight: const Radius.circular(AppRadius.lg),
                    bottomLeft: const Radius.circular(AppRadius.lg),
                    bottomRight: const Radius.circular(4),
                  ),
                ),
                child: Text(
                  message.text ?? '',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ),
        );
      case AgentMessageRole.error:
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.pagePadding,
            vertical: AppSpacing.xs,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(
                  color: AppColors.danger.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 16,
                    color: AppColors.danger,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Flexible(
                    child: Text(
                      message.text ?? '',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case AgentMessageRole.assistant:
        final response = message.response;
        if (response == null) return const SizedBox.shrink();
        if (response is AgentAnswer && response.body == '...') {
          return const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: AppSpacing.pagePadding,
              vertical: AppSpacing.md,
            ),
            child: _TypingDots(),
          );
        }
        return AgentResponseBubble(
          response: response,
          index: index,
          actionConfirmed: message.actionConfirmed,
        );
    }
  }
}

class _TypingDots extends StatefulWidget {
  const _TypingDots();
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final phase = (_c.value + i / 3) % 1.0;
            final scale = 0.7 + 0.3 * (1 - (phase - 0.5).abs() * 2).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Transform.scale(
                scale: scale,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _InputBar extends ConsumerStatefulWidget {
  const _InputBar({
    required this.controller,
    required this.busy,
    required this.onSend,
  });
  final TextEditingController controller;
  final bool busy;
  final ValueChanged<String> onSend;

  @override
  ConsumerState<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends ConsumerState<_InputBar> {
  static const _maxHeight = 140.0;

  // Drives the multi-line TextField's internal scroll. We jump to
  // maxScrollExtent on every controller change so the most recently
  // dictated text stays visible (Flutter's auto-scroll-to-cursor
  // doesn't kick in reliably for programmatic edits).
  final _textScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the controller changes — covers both user
    // typing (which also fires onChanged, but this is the canonical
    // signal) AND programmatic writes from the mic so the Send
    // button's enabled state stays in sync.
    widget.controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _textScrollController.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    // Defer until after this frame so the TextField has rebuilt at
    // its new height before we measure scroll extents.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_textScrollController.hasClients) return;
      _textScrollController.jumpTo(
        _textScrollController.position.maxScrollExtent,
      );
    });
  }

  void _sendCurrent() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    widget.controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = widget.controller.text.trim().isNotEmpty;
    final canSend = hasText && !widget.busy;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.sm,
          AppSpacing.pagePadding,
          AppSpacing.md,
        ),
        child: Container(
          constraints: const BoxConstraints(maxHeight: _maxHeight),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: theme.colorScheme.outlineVariant,
              width: 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.xs,
                    AppSpacing.md,
                  ),
                  child: TextField(
                    controller: widget.controller,
                    scrollController: _textScrollController,
                    enabled: !widget.busy,
                    minLines: 1,
                    maxLines: null,
                    textInputAction: TextInputAction.send,
                    onSubmitted: widget.busy ? null : (_) => _sendCurrent(),
                    onChanged: (_) => setState(() {}),
                    textAlignVertical: TextAlignVertical.center,
                    decoration: const InputDecoration(
                      hintText: 'Ask about your spending…',
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.35,
                    ),
                  ),
                ),
              ),
              _MicButton(
                controller: widget.controller,
                busy: widget.busy,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(2, 6, 6, 6),
                child: _SendButton(
                  enabled: canSend,
                  busy: widget.busy,
                  onTap: _sendCurrent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final bg = enabled ? primary : primary.withValues(alpha: 0.18);
    final fg = enabled ? Colors.white : primary.withValues(alpha: 0.55);
    return SizedBox(
      width: 36,
      height: 36,
      child: Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(
                    Icons.arrow_upward_rounded,
                    size: 18,
                    color: fg,
                  ),
          ),
        ),
      ),
    );
  }
}

/// Voice capture for the agent input. Tapping the mic starts a STT
/// session (Android's on-device SpeechRecognizer or iOS SFSpeech — no
/// audio leaves the device). The session ends naturally when the
/// engine finalizes — we don't restart or fight the library. Partial
/// transcripts stream into the field; tap the mic again to stop.
/// Hides itself if the device has no recognizer.
class _MicButton extends StatefulWidget {
  const _MicButton({required this.controller, required this.busy});
  final TextEditingController controller;
  final bool busy;

  @override
  State<_MicButton> createState() => _MicButtonState();
}

class _MicButtonState extends State<_MicButton>
    with SingleTickerProviderStateMixin {
  late final SpeechToText _stt = SpeechToText();
  late final AnimationController _pulse;
  bool _initialized = false;
  bool _listening = false;
  // Hide the button if the device has no recognizer at all. Probed
  // on the first tap and never re-shown.
  bool _supported = true;

  /// Whatever the user had typed when the mic was tapped. We treat
  /// it as immutable and concatenate partial transcripts on top of
  /// it, so dictated text layers on instead of clobbering in-progress
  /// typing. Set once at session start.
  String _baseline = '';

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    if (_listening) {
      _stt.stop();
    }
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (widget.busy) return;
    if (_listening) {
      // User taps mic while a session is active — explicit stop.
      await _stt.stop();
      // _handleStatus will pick up the done event and flip UI back.
      return;
    }
    // First-ever tap: lazy-init. Returns false if there's no
    // recognizer engine installed.
    if (!_initialized) {
      final ok = await _stt.initialize(
        onError: _handleError,
        onStatus: _handleStatus,
      );
      if (!mounted) return;
      if (!ok) {
        setState(() => _supported = false);
        _showError('Voice input is unavailable on this device.');
        return;
      }
      _initialized = true;
    }
    final granted = await _stt.hasPermission;
    if (!mounted) return;
    if (!granted) {
      _showError(
        'Microphone permission denied. Enable it in Settings → Apps → Pocket → Permissions.',
      );
      return;
    }
    _baseline = widget.controller.text;
    setState(() => _listening = true);
    _pulse.repeat(reverse: true);
    await _stt.listen(
      onResult: _onResult,
      listenOptions: SpeechListenOptions(
        localeId: 'en_US',
        partialResults: true,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  void _onResult(SpeechRecognitionResult r) {
    final transcript = r.recognizedWords.trim();
    if (transcript.isEmpty) return;
    final prefix = _baseline.trim();
    final spacer = prefix.isEmpty || prefix.endsWith(' ') ? '' : ' ';
    final composed = '$prefix$spacer$transcript';
    widget.controller.value = TextEditingValue(
      text: composed,
      selection: TextSelection.collapsed(offset: composed.length),
    );
  }

  void _handleStatus(String status) {
    if (!mounted) return;
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      setState(() => _listening = false);
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  void _handleError(SpeechRecognitionError e) {
    if (!mounted) return;
    setState(() => _listening = false);
    _pulse.stop();
    _pulse.value = 0;
    // "error_no_match" fires when the engine didn't pick up speech
    // before its internal timeout — natural end of session, not
    // worth pestering the user with a snackbar.
    if (e.errorMsg == 'error_no_match') return;
    _showError('Voice input error: ${e.errorMsg}');
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_supported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 4, 6),
      child: Semantics(
        label: 'Voice input',
        button: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                AnimatedBuilder(
                  animation: _pulse,
                  builder: (_, _) {
                    if (!_listening) return const SizedBox.shrink();
                    final t = _pulse.value;
                    return Container(
                      width: 28 + 8 * t,
                      height: 28 + 8 * t,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: primary.withValues(alpha: 0.20 + 0.18 * t),
                      ),
                    );
                  },
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: primary.withValues(
                      alpha: _listening ? 0.20 : 0.10,
                    ),
                  ),
                  child: Icon(
                    Icons.mic_rounded,
                    size: 18,
                    color: primary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IdleEmptyState extends StatelessWidget {
  const _IdleEmptyState();

  static const _examples = <String>[
    'How much did I spend this month?',
    'Show me a chart of weekly spending',
    'Create a \$200 weekly food budget',
    'Top 5 merchants this month',
    'Add a \$12 refund from Amazon',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.pagePadding,
          AppSpacing.xl,
          AppSpacing.pagePadding,
          AppSpacing.xl,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 36,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Center(
                child: Text(
                  'Ask Pocket anything',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Center(
                child: Text(
                  'Charts, breakdowns, budgets, and edits — all from a single prompt.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Try one of these',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final e in _examples) ...[
                _ExampleTile(text: e),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ExampleTile extends ConsumerWidget {
  const _ExampleTile({required this.text});
  final String text;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () {
          // Find the enclosing AgentScreen state and reuse its _send
          // so the request actually fires (and the typing dots render
          // until the response comes back).
          final state = context.findAncestorStateOfType<_AgentScreenState>();
          if (state != null) {
            state.sendText(text);
          } else {
            // Fallback if the ancestor can't be found (shouldn't happen
            // in practice) — at least seed the conversation.
            ref
                .read(agentConversationProvider.notifier)
                .add(AgentMessage.user(text));
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Icon(
                Icons.arrow_outward_rounded,
                size: 16,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  text,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoKeyEmptyState extends StatelessWidget {
  const _NoKeyEmptyState({required this.error});
  final Object error;

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
                color: theme.colorScheme.secondary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Icon(
                Icons.key_off_rounded,
                size: 40,
                color: theme.colorScheme.secondary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              'AI not configured',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Add an API key in Settings to start a conversation with Pocket Agent.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AiModelScreen()),
                );
              },
              icon: const Icon(Icons.settings_rounded, size: 18),
              label: const Text('Configure AI'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Horizontally scrollable row of context-aware suggestion chips. Sits
/// between the chat list and the input bar. Hidden when the user has
/// typed text (so they don't compete) and during in-flight requests.
class _SuggestionStrip extends ConsumerWidget {
  const _SuggestionStrip({required this.hasText});
  final bool hasText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final suggestionsAsync = ref.watch(agentSuggestionsProvider);
    if (hasText) return const SizedBox.shrink();

    // `valueOrNull` returns the previous chip list while a new
    // signature (EMPTY→PENDING→DONE) is being fetched, so the chips
    // don't blink to empty between turns. On the very first load
    // it's null → empty list → strip stays empty until the first
    // batch resolves.
    final suggestions = suggestionsAsync.valueOrNull ?? const <String>[];
    if (suggestions.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.pagePadding,
          vertical: AppSpacing.xs,
        ),
        itemCount: suggestions.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (_, i) => _SuggestionChip(
          text: suggestions[i],
          onTap: () => _apply(context, suggestions[i]),
        ),
      ),
    );
  }

  void _apply(BuildContext context, String text) {
    final state = context.findAncestorStateOfType<_AgentScreenState>();
    if (state == null) return;
    state.sendText(text);
  }
}

class _SuggestionChip extends StatelessWidget {
  const _SuggestionChip({required this.text, required this.onTap});
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: theme.colorScheme.primary.withValues(alpha: 0.25),
              width: 0.8,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 13,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 6),
              Text(
                text,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
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
