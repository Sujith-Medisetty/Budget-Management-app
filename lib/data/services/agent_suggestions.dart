import 'dart:convert';

import '../models/agent_message.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import '../util/strip_think_blocks.dart';
import 'cloud_ai_parser.dart';

/// Heuristic, no-LLM suggestions for the Agent's input strip. Cheap,
/// deterministic, runs on every conversation change. We bias toward
/// prompts the user is most likely to actually want next given their
/// conversation + recent data.
class AgentSuggestions {
  AgentSuggestions({
    required this._txns,
    required this._budgets,
  });

  final TransactionRepository _txns;
  final BudgetRepository _budgets;

  static const _starter = <String>[
    'How much did I spend this month?',
    'Show weekly chart',
    'Top merchants',
    'Create a weekly budget',
    'Set a daily limit',
  ];

  /// Up to 5 suggestions. Reads recent transactions + active budget to
  /// make them feel relevant; falls back to starters if there's no
  /// signal to bias on.
  Future<List<String>> suggest({DateTime? now}) async {
    final ts = now ?? DateTime.now();
    final suggestions = <String>[];

    final activeBudget = await _budgets.firstActive();
    final monthStart = DateTime(ts.year, ts.month, 1);
    final monthEnd = DateTime(ts.year, ts.month + 1, 1)
        .subtract(const Duration(milliseconds: 1));
    final monthTxns = await _txns.inRange(monthStart, monthEnd);
    final txCount = monthTxns.length;

    // 1) Active budget: suggest how much is left, or update it.
    if (activeBudget != null) {
      suggestions.add(
        'How much is left in ${activeBudget.name}?',
      );
    }

    // 2) Top merchant this month — useful when there is one.
    final byMerchant = <String, double>{};
    for (final t in monthTxns) {
      if (t.amount <= 0) continue;
      byMerchant[t.merchant] = (byMerchant[t.merchant] ?? 0) + t.amount;
    }
    if (byMerchant.isNotEmpty) {
      final topEntry = byMerchant.entries.reduce(
        (a, b) => a.value >= b.value ? a : b,
      );
      suggestions.add('How much on ${topEntry.key}?');
    }

    // 3) Comparison against last month if there's last-month data.
    final lastMonthStart = DateTime(ts.year, ts.month - 1, 1);
    final lastMonthEnd = DateTime(ts.year, ts.month, 1)
        .subtract(const Duration(milliseconds: 1));
    final lastMonthSpend = await _txns.spentBetween(
      lastMonthStart,
      lastMonthEnd,
    );
    if (lastMonthSpend > 0 && txCount > 0) {
      suggestions.add('Compare to last month');
    }

    // 4) Time-of-day nudges.
    if (ts.weekday == DateTime.monday && txCount > 0) {
      suggestions.add('Wrap up last week');
    } else if (ts.day >= 25 && txCount > 0) {
      suggestions.add('Month-end summary');
    }

    // 5) Always offer a chart prompt — universally useful.
    suggestions.add('Show weekly chart');

    // De-dupe while keeping order, cap at 5.
    final seen = <String>{};
    final out = <String>[];
    for (final s in suggestions) {
      if (seen.add(s.toLowerCase())) out.add(s);
      if (out.length >= 5) break;
    }

    // Fall back to starters if heuristics produced nothing useful
    // (e.g. brand-new user with zero transactions).
    if (out.isEmpty) return List.of(_starter);
    return out;
  }

  /// Starter prompts used when the conversation is empty. Distinct
  /// from heuristic suggestions because new users benefit from examples
  /// rather than personalized nudges.
  List<String> starter() => List.of(_starter);

  /// Ask the configured LLM for 3-4 short follow-up prompts based on
  /// the recent conversation. Costs one cheap completion; returns an
  /// empty list on failure so callers can fall back to [suggest].
  ///
  /// The model is told to mimic the user's tone and bias toward prompts
  /// that would actually advance the conversation (e.g. drill into a
  /// merchant that was just surfaced, mutate something the agent
  /// described, or compare against a different period).
  static const _followupsSystemPrompt = '''
You suggest the next prompts a user is most likely to want inside a personal-finance chat called Pocket Agent.

Given the conversation so far, return strictly this JSON:
{"suggestions": ["prompt", "prompt", "prompt"]}

Rules:
- 3 to 4 prompts.
- ≤7 words each. Natural language, lowercase except proper nouns.
- Bias toward variety: one drill-in (deeper into something the assistant just mentioned), one action (create/update/delete), one comparative or summary.
- Reference the user's data when relevant (merchant, budget name, period). Use the same numbers/amounts the assistant used.
- No quotes inside prompts. No preamble. JSON only.
- No reasoning, no thinking, no commentary, no markdown fences — just the JSON object.
''';

  Future<List<String>> llmFollowups({
    required CloudAiParser parser,
    required List<AgentMessage> conversation,
  }) async {
    // Feed the model a compact transcript of the last 15 turns so it
    // can anchor follow-ups to what was just discussed. We don't ship
    // the full conversation — that bloats tokens and the early turns
    // are usually stale by the time the user is reading suggestions.
    final tail = conversation.length > 15
        ? conversation.sublist(conversation.length - 15)
        : conversation;
    final transcript = tail.map((m) {
      final role = switch (m.role) {
        AgentMessageRole.user => 'user',
        AgentMessageRole.assistant => 'assistant',
        AgentMessageRole.error => 'system',
      };
      final body = m.response?.text ?? m.text ?? '';
      final compact = body.trim().replaceAll(RegExp(r'\s+'), ' ');
      return '$role: ${compact.length > 240 ? '${compact.substring(0, 240)}…' : compact}';
    }).join('\n');

    final raw = await parser.chatCompletion(
      systemPrompt: _followupsSystemPrompt,
      userPrompt: transcript,
      temperature: 0.6,
    );
    if (raw == null || raw.isEmpty) return const [];

    final cleaned = stripThinkBlocks(raw)
        .replaceAll(RegExp(r'```(?:json)?\s*|```', caseSensitive: false), '')
        .trim();
    Map<String, Object?>? json;
    try {
      json = jsonDecode(cleaned) as Map<String, Object?>;
    } catch (_) {
      final start = cleaned.indexOf('{');
      final end = cleaned.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          json = jsonDecode(cleaned.substring(start, end + 1))
              as Map<String, Object?>;
        } catch (_) {}
      }
    }
    if (json == null) return const [];

    final raw2 = json['suggestions'];
    if (raw2 is! List) return const [];
    final out = <String>[];
    final seen = <String>{};
    for (final item in raw2) {
      if (item is! String) continue;
      final s = item.trim();
      if (s.isEmpty) continue;
      if (seen.add(s.toLowerCase())) out.add(s);
      if (out.length >= 5) break;
    }
    return out;
  }
}
