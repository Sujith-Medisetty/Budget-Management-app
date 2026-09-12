import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/models/agent_message.dart';
import '../data/models/agent_response.dart';
import '../data/services/agent_data.dart';
import '../data/services/agent_service.dart';
import '../data/services/agent_suggestions.dart';
import '../data/services/cloud_ai_parser.dart';
import '../data/services/gmail_filter_rules.dart';
import 'backup_provider.dart';
import 'providers.dart';

/// The data helpers the agent service uses to build snapshots. Cheap
/// to construct — holds references to every repository / service the
/// agent has read access to (transactions, budgets, AI log, AI config,
/// filter rules, Gmail auth + sync).
///
/// Async deps ([sharedPrefsProvider], [aiKeyStoreProvider]) are awaited
/// inside the cloud-parser FutureProvider, which the agent service
/// depends on, so by the time this Provider runs all three should be
/// settled. If they're not, the provider throws — the UI catches that
/// via AgentMissingKeyException and renders the configure-AI state.
final agentDataProvider = Provider<AgentData>((ref) {
  final prefs = ref.watch(sharedPrefsProvider).valueOrNull;
  final store = ref.watch(aiKeyStoreProvider).valueOrNull;
  if (prefs == null || store == null) {
    throw const AgentMissingKeyException();
  }
  const secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final filterStore = FilterRuleStore(ref.watch(accountsRepoProvider));
  // Best-effort warm-up so the first synchronous filterStore.read()
  // returns the real rules instead of defaults. The agent's
  // _readRules() cache makes this the only network hit; subsequent
  // reads hit the in-memory cache.
  Future.microtask(filterStore.loadFromDisk);
  return AgentData(
    txns: ref.watch(transactionRepoProvider),
    budgets: ref.watch(budgetRepoProvider),
    prefs: prefs,
    aiKeyStore: store,
    secure: secure,
    gmailAuth: ref.watch(gmailAuthProvider),
    gmailSync: ref.watch(gmailSyncProvider),
    filterStore: filterStore,
    // `ref.read` (not watch) so a midnight auto-backup time change
    // doesn't rebuild the whole agent provider — the next snapshot
    // call simply re-reads.
    readBackupPrefs: () => ref.read(backupPreferencesProvider),
  );
});


/// Suggestion generator for the Agent input strip. Returns:
///  - starters when the conversation is empty,
///  - data-driven heuristics while the user is typing or the assistant
///    is in flight (no real assistant response yet),
///  - LLM-generated prompts once at least one assistant response has
///    fully landed. The LLM result is cached on the assistant
///    response's signature so we don't refire every keystroke.
///
/// Falls back to heuristics if the LLM call fails (no key, transport
/// error, malformed JSON).
final agentSuggestionsProvider =
    AsyncNotifierProvider<AgentSuggestionsNotifier, List<String>>(
  AgentSuggestionsNotifier.new,
);

class AgentSuggestionsNotifier extends AsyncNotifier<List<String>> {
  // Signature of the conversation snapshot we last fetched suggestions
  // for. While the conversation changes around this same signature
  // (typing, scroll rebuilds, id churn) we return the cached value
  // rather than burning another completion.
  String? _lastSig;

  @override
  Future<List<String>> build() async {
    // Only rebuild when the *meaningful* conversation state changes —
    // see [_signature]. Watching the full list would refire on every
    // id churn (every append mints a new microsecond id).
    final sig = ref.watch(
      agentConversationProvider.select(_signature),
    );
    final convo = ref.read(agentConversationProvider);

    // Cached for this signature? Just hand back the previous value.
    if (sig == _lastSig && state.hasValue) return state.value!;
    _lastSig = sig;

    final sugg = AgentSuggestions(
      txns: ref.read(transactionRepoProvider),
      budgets: ref.read(budgetRepoProvider),
    );

    if (convo.isEmpty) return sugg.starter();

    // No completed assistant response yet — agent is mid-flight or the
    // user just sent something. Stay on cheap heuristics.
    final hasCompletedAssistant = convo.any((m) =>
        m.role == AgentMessageRole.assistant && _isRealResponse(m.response));
    if (!hasCompletedAssistant) {
      return sugg.suggest();
    }

    // Try LLM follow-ups. Fall back to heuristics if anything goes
    // wrong (no key, transport error, malformed JSON, empty result).
    try {
      final parser = await ref.read(cloudParserProvider.future);
      final llm =
          await sugg.llmFollowups(parser: parser, conversation: convo);
      if (llm.isNotEmpty) return llm;
    } catch (_) {
      // Fall through.
    }
    return sugg.suggest();
  }

  bool _isRealResponse(AgentResponse? r) {
    if (r == null) return false;
    // The screen adds a placeholder assistant message with body '...'
    // while a request is in flight. Treat that as not-yet-real so we
    // don't fire follow-up prompts before the assistant has actually
    // replied.
    if (r.text == '...') return false;
    return true;
  }

  /// Stable signature for [agentConversationProvider.select]. Three
  /// buckets: EMPTY (starters), PENDING (data-driven heuristics), and
  /// DONE:{text} (cache by last assistant response text — id changes
  /// would invalidate the cache even when content is identical).
  String _signature(List<AgentMessage> convo) {
    if (convo.isEmpty) return 'EMPTY';
    final lastReal = convo.lastWhere(
      (m) => m.role == AgentMessageRole.assistant && _isRealResponse(m.response),
      orElse: () => const AgentMessage(role: AgentMessageRole.user, text: ''),
    );
    if (lastReal.role != AgentMessageRole.assistant) return 'PENDING';
    return 'DONE:${lastReal.response?.text ?? lastReal.text ?? ''}';
  }
}

/// The configured cloud parser. Throws if the AI key store isn't ready
/// or if no key is set — the Agent screen catches this to render the
/// "Configure AI" empty state.
final cloudParserProvider = FutureProvider<CloudAiParser>((ref) async {
  final config = await ref.watch(aiConfigProvider.future);
  if (!config.hasKey) {
    throw const AgentMissingKeyException();
  }
  final store = await ref.watch(aiKeyStoreProvider.future);
  final key = await store.readKey(config.provider);
  if (key == null || key.isEmpty) {
    throw const AgentMissingKeyException();
  }
  return CloudAiParser(config: config, apiKey: key);
});

final agentServiceProvider = FutureProvider<AgentService>((ref) async {
  final parser = await ref.watch(cloudParserProvider.future);
  return AgentService(parser: parser, data: ref.watch(agentDataProvider));
});

/// The conversation. Kept alive across tab switches (keepAlive: true)
/// so the chat doesn't reset every time the user opens Agent. NOT
/// persisted across app restarts in v1.
final agentConversationProvider =
    NotifierProvider<AgentConversation, List<AgentMessage>>(
      AgentConversation.new,
    );

class AgentConversation extends Notifier<List<AgentMessage>> {
  @override
  List<AgentMessage> build() {
    ref.keepAlive();
    return const [];
  }

  void add(AgentMessage m) {
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    state = [...state, m.withId(id)];
  }

  /// Replace the *last* assistant message with the given one. Used to
  /// stream a single response bubble while a request is in flight (we
  /// don't actually stream yet, but the API supports it).
  void updateLast(AgentMessage m) {
    if (state.isEmpty) return;
    final updated = [...state];
    updated[updated.length - 1] = m;
    state = updated;
  }

  /// Mark the action in [index] as confirmed or cancelled.
  void setActionStatus(int index, AgentActionStatus status) {
    if (index < 0 || index >= state.length) return;
    final updated = [...state];
    updated[index] = updated[index].copyWith(actionConfirmed: status);
    state = updated;
  }

  /// Updates one step of an `action_plan` card. Used while the runner
  /// is mid-flight so the per-step row can flip pending → confirmed in
  /// real time. Mints the per-step list (filled with `pending`) on the
  /// first call so callers don't need to know the step count up front.
  void setPlanStepStatus(int index, int stepIndex, AgentActionStatus status) {
    if (index < 0 || index >= state.length) return;
    final updated = [...state];
    updated[index] = _withStep(updated[index], stepIndex, status);
    state = updated;
  }

  AgentMessage _withStep(
    AgentMessage m,
    int stepIndex,
    AgentActionStatus status,
  ) {
    final plan = m.response;
    if (plan is! AgentActionPlan) return m;
    final length = plan.steps.length;
    final existing = m.planStepStatuses;
    final base = existing != null && existing.length == length
        ? List<AgentActionStatus>.from(existing)
        : List<AgentActionStatus>.filled(length, AgentActionStatus.pending);
    if (stepIndex < 0 || stepIndex >= length) return m;
    base[stepIndex] = status;
    final allDone = base.every((s) => s == AgentActionStatus.confirmed);
    return m.copyWith(
      planStepStatuses: base,
      actionConfirmed: allDone ? AgentActionStatus.confirmed : m.actionConfirmed,
    );
  }

  void clear() {
    state = const [];
  }
}

class AgentMissingKeyException implements Exception {
  const AgentMissingKeyException();
  @override
  String toString() => 'No AI key configured';
}
