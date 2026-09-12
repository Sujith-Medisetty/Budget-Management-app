import '../models/agent_message.dart';
import '../util/strip_think_blocks.dart';
import 'cloud_ai_parser.dart';

/// Rolling summary of an Agent conversation. Once the conversation
/// crosses [_summaryThreshold] turns, the older portion (everything
/// except the last [_keepLastN] turns) gets summarized and the summary
/// is updated incrementally as new turns age out of the window. The
/// summarizer holds its cache for the lifetime of the AgentService,
/// so subsequent calls only burn an LLM completion when a brand-new
/// turn actually moves into the "older" bucket — not on every send.
class ConversationSummarizer {
  ConversationSummarizer({required this._parser});

  final CloudAiParser _parser;

  // -1 means we have no summary yet. [0..olderEnd) is what's covered.
  int _summarizedUpTo = -1;
  String _cacheKey = '';
  String _cacheSummary = '';
  // First-message id of the conversation we've been summarizing. When
  // this changes we know the user cleared and started over — the
  // previous summary is for a different conversation entirely and we
  // must rebuild from zero.
  String? _firstMessageId;

  /// Cross this many turns and we start summarizing. Below it the
  /// caller sends the verbatim transcript (the existing
  /// last-N-transcript path).
  static const int _summaryThreshold = 15;

  /// Update the rolling summary to cover [conversation] except the
  /// last [keepLastN] turns. Returns the summary, or null when there's
  /// nothing older to summarize.
  ///
  /// Cache invariant is broken (and a new LLM call fires) only when:
  ///   - a brand-new turn has just aged out of the last-[keepLastN]
  ///     window, or
  ///   - content within the already-summarized range changed (e.g. an
  ///     assistant response was rewritten), or
  ///   - the conversation itself was cleared and a new one started.
  /// Same input twice in a row → no LLM call.
  Future<String?> ensureSummary({
    required List<AgentMessage> conversation,
    int keepLastN = 5,
  }) async {
    if (conversation.length <= _summaryThreshold) return null;
    final olderEnd = conversation.length - keepLastN;
    if (olderEnd <= 0) return null;

    // Detect "different conversation" via the leading message's id.
    // Without this guard, a clear-then-restart at a similar length
    // would mistakenly try to extend the previous conversation's
    // summary with turns that have nothing to do with it.
    final firstId = conversation.first.id;
    if (firstId != _firstMessageId) {
      _summarizedUpTo = -1;
      _cacheSummary = '';
      _cacheKey = '';
      _firstMessageId = firstId;
    }

    final newKey = _computeKey(conversation, olderEnd);
    if (newKey == _cacheKey && _cacheSummary.isNotEmpty) {
      return _cacheSummary;
    }

    // Pick the strategy: initial / shrunk → summarize the whole
    // older range from scratch. Grow → extend the existing summary
    // with just the newly-aged-out turns. Mutation within the
    // already-summarized range (content signature differs but range
    // unchanged) → also summarize from scratch.
    final isShrink = olderEnd <= _summarizedUpTo;
    final isMutation = !isShrink && olderEnd == _summarizedUpTo;
    if (_summarizedUpTo < 0 || isShrink || isMutation) {
      _cacheSummary = await _callSummary(
        _format(conversation, 0, olderEnd),
        previousSummary: null,
      );
    } else {
      // Grow: only summarize the new turns, hand the previous summary
      // along so the model extends it instead of rewriting from zero.
      _cacheSummary = await _callSummary(
        _format(conversation, _summarizedUpTo, olderEnd),
        previousSummary: _cacheSummary,
      );
    }

    _summarizedUpTo = olderEnd;
    _cacheKey = newKey;
    return _cacheSummary.isEmpty ? null : _cacheSummary;
  }

  /// Drop the cached summary. Call when the conversation is cleared.
  void reset() {
    _summarizedUpTo = -1;
    _cacheKey = '';
    _cacheSummary = '';
    _firstMessageId = null;
  }

  /// Stable content signature for messages [0..end). Used as the cache
  /// key — when this changes, something in the older portion is new
  /// or different, so the cached summary is stale.
  String _computeKey(List<AgentMessage> convo, int end) {
    final buf = StringBuffer();
    for (var i = 0; i < end; i++) {
      final m = convo[i];
      buf
        ..write(m.role.name)
        ..write(':')
        ..write(m.response?.text ?? m.text ?? '')
        ..write('|');
    }
    return buf.toString();
  }

  String _format(List<AgentMessage> convo, int from, int to) {
    final out = StringBuffer();
    for (var i = from; i < to; i++) {
      final m = convo[i];
      final body = m.response?.text ?? m.text ?? '';
      if (body.trim().isEmpty) continue;
      final compact = body.trim().replaceAll(RegExp(r'\s+'), ' ');
      final truncated =
          compact.length > 240 ? '${compact.substring(0, 240)}…' : compact;
      out
        ..write(_roleLabel(m.role))
        ..write(': ')
        ..writeln(truncated);
    }
    return out.toString().trim();
  }

  String _roleLabel(AgentMessageRole r) => switch (r) {
        AgentMessageRole.user => 'user',
        AgentMessageRole.assistant => 'assistant',
        AgentMessageRole.error => 'system',
      };

  Future<String> _callSummary(
    String content, {
    String? previousSummary,
  }) async {
    final isUpdate = previousSummary != null;
    final sys = isUpdate ? _summaryUpdateSystemPrompt : _summarySystemPrompt;
    final prompt = isUpdate
        ? 'Current summary of earlier conversation:\n'
            '"""$previousSummary"""\n\n'
            'New turns to fold in:\n'
            '"""$content"""\n\n'
            'Produce an updated summary covering ALL turns. Preserve every '
            'concrete data point — ids, amounts, merchant names, budget '
            'names, periods, dates. Stay under 250 words. Output only the '
            'updated summary.'
        : 'Earlier conversation turns to compress:\n'
            '"""$content"""\n\n'
            'Produce a summary the assistant can rely on to answer '
            'follow-ups accurately. Use this exact section layout:\n\n'
            'FACTS ESTABLISHED\n'
            '- Concrete data points the user mentioned or you computed '
            '(ids, amounts, merchants, dates, ranges). PRESERVE THESE '
            'VERBATIM — they are ground truth for follow-ups.\n\n'
            'ACTIONS TAKEN\n'
            '- Mutations you proposed (created budget #N "Foo" \$X/mo, '
            'deleted expense #M, etc.). Each as one bullet.\n\n'
            'OPEN THREADS\n'
            '- Questions the user asked that you haven\'t resolved, '
            'or follow-ups they hinted at.\n\n'
            'TONE / PREFERENCES\n'
            '- Anything the user told you about how they want answers '
            '(currency, time zone, period preference, etc.).\n\n'
            'Keep the total under 220 words. Concrete data first, '
            'narrative last. Output only the summary.';

    final raw = await _parser.chatCompletion(
      systemPrompt: sys,
      userPrompt: prompt,
      temperature: 0.1,
    );
    if (raw == null) return '';
    return stripThinkBlocks(raw);
  }

  static const _summarySystemPrompt = '''
You are a conversation memory compressor for a personal-finance chat assistant inside the Pocket app.

Your job: turn a sequence of conversation turns into a structured summary that another assistant turn can rely on to answer follow-ups. Preserve every concrete data point (ids, amounts, merchant names, dates) verbatim. Drop pleasantries and meta-conversation. Output only the summary, using the section layout the caller specified.
''';

  static const _summaryUpdateSystemPrompt = '''
You are a conversation memory compressor for a personal-finance chat assistant inside the Pocket app.

You will receive the existing summary of earlier turns plus new turns to fold in. Produce an updated summary that covers ALL turns. Preserve every concrete data point (ids, amounts, merchants, dates) verbatim — never let them get paraphrased away. Compress narrative detail aggressively, but never truncate an action or a fact. Output only the updated summary.
''';
}