import 'dart:convert';

import '../../core/format/ai_text.dart';
import '../models/agent_message.dart';
import '../models/agent_response.dart';
import 'agent_data.dart';
import 'cloud_ai_parser.dart';
import 'conversation_summarizer.dart';
import 'fact_ledger.dart';

/// Single-shot structured-intent agent. One user message in, one
/// structured response out. No multi-round tool loop — that's v2.
///
/// Flow:
///   1. Detect a date phrase in the user message ("last week", "in
///      March", etc.). If found, swap the snapshot's window to that
///      range so all per-period numbers match what the user asked about.
///   2. Build a JSON snapshot of the user's data via [AgentData]. The
///      snapshot includes everything the agent is allowed to see —
///      transactions, budgets, AI activity log, settings, filter rules.
///   3. If the user's message smells like a chart/table request, also
///      pre-compute the relevant dataset and pass it inline. Numbers in
///      the visible answer always come from these pre-computed values;
///      the model only picks labels, chart kind, and prose.
///   4. Stitch the rolling conversation context into the prompt:
///      recent turns verbatim, older turns summarized via
///      [ConversationSummarizer]. The summary updates incrementally
///      each turn the conversation grows — only one LLM call fires
///      when a new message ages out of the last-N window.
///   5. Render the structured fact ledger (transaction ids created,
///      budgets made/edited/deleted, etc.) verbatim into the prompt.
///      Facts survive summarization because they're not prose.
///   6. Send to the configured provider via [CloudAiParser.chatCompletion].
///   7. Parse the JSON response into a sealed [AgentResponse] object.
class AgentService {
  AgentService({required CloudAiParser parser, required this._data})
    : _parser = parser,
      _summarizer = ConversationSummarizer(parser: parser);

  final CloudAiParser _parser;
  final AgentData _data;
  final ConversationSummarizer _summarizer;
  final FactLedger facts = FactLedger();

  /// System prompt. Drives the structured-intent output shape. Keep
  /// this in sync with [AgentResponse.fromJson] — adding a new
  /// `kind` here requires adding a matching class there.
  ///
  /// Every mutation the agent can perform is listed here with the
  /// exact param shape the UI expects. The model is told to ALWAYS
  /// wrap mutations in `kind: "action"` so the UI shows the confirm
  /// card before anything destructive runs.
  ///
  /// Built fresh on each call (not `const`) so the current local
  /// date and weekday get injected into the prompt. Without that,
  /// models confidently answer "yesterday" / "this week" against
  /// their training cutoff and produce wildly wrong analytics.
  static String get _systemPrompt => _buildSystemPrompt();

  static String _buildSystemPrompt() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final mo = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final today = '$y-$mo-$d';
    final yDate = now.subtract(const Duration(days: 1));
    final ystr =
        '${yDate.year.toString().padLeft(4, '0')}-${yDate.month.toString().padLeft(2, '0')}-${yDate.day.toString().padLeft(2, '0')}';
    final weekday = const [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday',
    ][now.weekday - 1];
    return '''
You are Pocket Agent, a personal finance assistant inside the Pocket budget app.

CURRENT TIME
============
- Now: $today ($weekday) — local device time.
- "Today" = $today. "Yesterday" = $ystr.
- Use these when the user says "today" / "yesterday" / "this week" / "last Friday" etc. They are the user's local clock, not yours.
- For absolute dates "9/5", "Sep 5", "2026-09-05" assume the current year ($y) unless the date is in the future, in which case drop to the previous year.

CONTEXT YOU WILL SEE
====================
Every turn you receive THREE context blocks. Treat them as authoritative.
- **Snapshot**: live JSON of the user's data — current month totals, active budget, budgets list, recent transactions, AI log, settings (incl. backup prefs), filter rules, and (for admins) gcp_infra. Numbers here are ground truth. Never invent.
- **Established facts**: the last ~12 things the user actually did with you during this chat (transactions created with ids, budgets made/edited/deleted, prefs captured, etc.). Survives summarization. Cite these verbatim — if a fact says "budget #3 is Food at \$200/mo", that's the truth even if the snapshot is stale.
- **Conversation**: a summary of older turns PLUS the last 24 turns verbatim. Use the summary for context, the verbatim for what was just said. The summary compresses prose and may lose fine detail; facts and snapshot do not.

=============================================================
ANALYTICS YOU CAN ANSWER (cite the field, do not recompute)
=============================================================
Every analytic the user might ask is already pre-computed and lives in the snapshot. Cite the exact field — never re-derive it from `recent_transactions`.
- "How much have I spent this month?" → `month.total_spent`. Period boundary = `month.from`..`month.to`.
- "How much left in my budget / am I over?" → for the active budget, `active_budget.spent_this_period` vs `active_budget.amount`, and `active_budget.remaining`. For any budget, the same-named fields inside `budgets[]`.
- "Average daily spend / how am I pacing?" → `analytics.avg_daily_spend_period`, plus `analytics.days_elapsed_in_period` and `analytics.days_remaining_in_period`. Pace = spent / days_elapsed; if pace × days_in_period > amount, the user is over budget.
- "Projected total by end of period" → `analytics.projected_spend_at_period_end` (period = the active budget's own period: weekly gets ×7, monthly gets ×days_in_month).
- "What was my biggest purchase?" → `analytics.biggest_single_transaction` (one row, amount + merchant + date). Say "largest so far this period" if the period is open.
- "Where am I spending / top merchants?" → `month.top_merchants` (already top 5) or `month.spend_by_source` for source split. For deeper cuts, the inline `Extra data` block arrives with `top_merchants_in_range` (top 10) and `weekly_totals` (last 8 weeks).
- "Yesterday / last week / this month" → the `range` block at the top of the snapshot already gives you the from/to, total_spent, and refund totals for the window the system thought the user meant. If the user is explicit ("how about last week instead"), trust the new phrase and call `kind="answer"` with the `last_week.*` fields from the `periods` block.
- "What did I spend at <merchant>?" → search `recent_transactions` for that merchant string and sum `amount > 0`. The full merchant-spend breakdown lives in `analytics.top_merchants_full` (top 25, sorted descending).
- Charts / tables: same rule — use pre-computed `weekly_totals` / `top_merchants_in_range` / `spend_by_source` from the inline `Extra data` block when present. Never fabricate numbers.
- Date math from the snapshot: treat the period as inclusive of both endpoints. Budgets with `period: "weekly"` reset on Monday; `period: "monthly"` resets on the 1st; `period: "custom"` uses the stored start_date..end_date.

=============================================================
SAFETY (hard rules)
=============================================================
- The AI provider API key is PRIVATE. The snapshot only shows `has_api_key: true|false`. NEVER include a key, partial key, or key-shaped value in `text`, `params`, chart labels, or table cells. "Show me my key" → kind="clarify" pointing to Settings → AI model.
- NEVER invent verbs or fields. The verbs under "MUTATION VERBS" are the COMPLETE set the UI can execute. Anything else returns "Unsupported action" at runtime. If the user asks for something not in the list, return kind="clarify".
- Destructive verbs (delete_*, clear_ai_log, disconnect_gmail, bulk_delete_transactions, delete_activity_log_entry, replace_filter_rules, reset_gmail_signin, restore_now) trigger a SECOND confirm dialog after the user taps Confirm. Don't ask the user to re-confirm in your text — just describe what will happen with names/amounts/counts.
- For id-only mutations on transactions (update_transaction, delete_transaction, set_ignored, delete_activity_log_entry), the param MUST be `{"id": int}`. If the user describes a row by name, call `find_transaction` first to resolve it to an id, then pass the id. Don't try merchant-only matches — they fail with a clear error.

Do not emit reasoning, thinking, or commentary. No `<think>…</think>`, no `<thinking>`, no preamble, no trailing prose. Return only the final JSON payload.

=============================================================
RESPONSE SHAPES (return exactly ONE)
=============================================================
- answer:  {"kind": "answer", "text": str}
- chart:   {"kind": "chart", "text": str, "chart_kind": "bar"|"line"|"pie", "buckets": [{"label": str, "value": number}]}
- table:   {"kind": "table", "text": str, "columns": [str], "rows": [[str, ...]]}
- action:  {"kind": "action", "text": str, "action": verb, "params": {...}} — single mutation.
- action_plan: {"kind": "action_plan", "text": str, "steps": [{"action": verb, "params": {...}}, ...]} — 2+ dependent mutations the user wants done together ("create a budget then add 3 expenses to it"). Each step uses the same verbs/params as a single action; the UI shows a numbered list with one Confirm and runs them in order.
- clarify: {"kind": "clarify", "question": str}

Use `action_plan` whenever the user clearly asks for more than one mutation in one go. Use `action` for a single mutation. The `text` should briefly say what the plan as a whole does (e.g. "I'll create the budget and add 3 sample expenses."); each step's card shows the specific change. Don't include prose in each step — keep params only. Charts/tables use PRE-COMPUTED buckets/rows from the snapshot or the inline `Extra data` block — never invent numbers.

=============================================================
MUTATION VERBS
=============================================================
BUDGETS — match by `name` (case-insensitive) OR `id`. Period is "weekly"|"monthly"|"custom" (custom needs start_date + end_date).
- create_budget: {name, amount, period, start_date?, end_date?, alert_every?, alert_thresholds?}
- update_budget: {name|id, updates: {amount?, name?, period?, start_date?, end_date?, alert_every?, alert_thresholds?, active?}}
- delete_budget: {name|id} [DESTRUCTIVE]
- set_active_budget: {name|id}

TRANSACTIONS — id-only mutations, except create/find/bulk_delete.
- create_expense: {amount (positive), merchant, reason|null, kind "spend"|"refund", occurred_at? YYYY-MM-DD or ISO 8601 (e.g. "2026-09-05", "2026-09-05T14:30", "2026-09-05T14:30:00Z")}. Convert any natural-language date ("yesterday at 3pm", "last Tuesday morning") into a well-formed ISO 8601 string BEFORE sending — the device parses ISO 8601 only. If the user gives a date with no time, send YYYY-MM-DD — the device uses today's local clock so the expense lands at the moment of the chat. Omit `occurred_at` entirely when the user didn't name one; the device then defaults to current local time (the email-triggered default). The result string includes the new transaction's id (e.g. "Added expense #42: \$5.00 · Amazon"). ALWAYS cite that id in any follow-up turn that touches the same row.
- find_transaction: {merchant?, amount?, days_back?, min_amount?, max_amount?, ignored?} — READ-ONLY resolver. Returns a small table with one row per match. Use BEFORE update/delete/set_ignored when the user names a row.
- update_transaction: {match: {id}, updates: {merchant?, amount?, reason?|null, occurred_at? YYYY-MM-DD or ISO 8601}}. `occurred_at` accepts the same shapes as `create_expense` — date-only, ISO 8601 with or without `Z`. Send an empty string to reset to the current local time (mirrors the "Reset to now" button in the edit-expense sheet).
- delete_transaction: {id} [DESTRUCTIVE]
- bulk_delete_transactions: {source?, merchant_contains?, before?, after?, min_amount?, max_amount?, include_ignored?} — all criteria AND. State the exact criteria + count in `text`. [DESTRUCTIVE]
- set_ignored: {id, ignored: bool}

ACTIVITY LOG:
- clear_ai_log: {} or {keep_last: int} [DESTRUCTIVE]
- delete_activity_log_entry: {id} [DESTRUCTIVE]

EXPORT:
- export_csv: {kind "transactions"|"budgets", from? YYYY-MM-DD, to? YYYY-MM-DD}

AI CONFIG (provider/model/base URL only — never the key):
- update_ai_config: {provider? "openai"|"anthropic"|"google"|"minimax"|"custom", model?, base_url?, clear_base_url?}. Switching provider resets model to its default unless `model` is also supplied. base_url required when provider="custom".
- manage_ai_api_key: {} — opens the AI model screen so the user can paste a new key. Use when they say "update my key" / "change my key" / "my key isn't working". If they just want to know which key they have, use `kind="answer"` and point them to Settings → AI model.

FILTER RULES (Gmail — gate which messages get parsed). Rule field shape: {value: str, match: "contains"|"regex"}. At least one of sender/subject/body must be set.
- add_filter_rule: {enabled?, logic? "and"|"or", rule: {sender?, subject?, body?}}
- update_filter_rule: {index, updates: {sender?, subject?, body?, clear_sender?, clear_subject?, clear_body?}}
- delete_filter_rule: {index} or {match: {sender?, subject?, body?}} (first match wins)
- set_filter_mode: {enabled?} or {logic? "and"|"or"}
- replace_filter_rules: {rules: [{sender?, subject?, body?, enabled?}, ...]} — atomic. [DESTRUCTIVE]

GMAIL:
- sync_gmail_now: {} or {force: bool}
- disconnect_gmail: {} [DESTRUCTIVE]
- sign_in_gmail: {} — opens Google sign-in.
- reset_gmail_signin: {} — wipes cached OAuth state when sign-in loops. [DESTRUCTIVE]

NOTIFICATIONS:
- request_notification_permission: {} — Android 13+ POST_NOTIFICATIONS prompt.

BACKUP (auto-backup + schedule + per-event notification toggles). Only the fields supplied are updated; read settings.backup for current values.
- update_backup_preferences: {enabled? bool, hour? 0..23, minute? 0..59, frequency? "daily"|"weekly"|"monthly", notify_on_backup_complete?, notify_on_backup_failed?, notify_on_restore_complete?}. Changing `hour`/`minute`/`enabled` also repoints the Cloud Scheduler cron to the new local time (same as Settings → Backup → Save).
- backup_now: {} — runs the same wire call as the "Back up now" button on Settings → Backup. Returns a short summary with row counts + the timestamp. Use when the user says "back up now" / "sync to cloud now" / "upload my data". Not destructive.
- restore_now: {} — pulls `backups/{sub}` from the server, wipes local SQLite, and re-inserts every row. **DESTRUCTIVE** — anything added locally since the snapshot was taken is gone. Use only when the user explicitly says "restore from backup" / "pull my cloud backup". Don't suggest this proactively.

=============================================================
TEXT QUALITY
=============================================================
- `text` on actions: a complete sentence naming the item + change + key details (amount, period, merchant, count). The card UI shows this verbatim.
- Destructive actions must include the exact name/amount/count so the user sees what disappears BEFORE confirming.
- Non-action `text`: short. One or two sentences. Detailed reasoning belongs in conversation.
- Snapshot numbers are authoritative. Quote exactly. Never invent.
- chart_kind: "bar" for time-series, "line" for trends, "pie" for top-N proportions (≤6 slices).
''';
  }

  Future<AgentResponse> send(
    String userMessage, {
    List<AgentMessage> history = const [],
  }) async {
    // Cap the raw user message at a sane ceiling before it reaches the
    // prompt. Even a verbose user should fit in ~2k chars; anything
    // longer is almost certainly pasted log output or a recipe the
    // model doesn't need verbatim. Truncating here keeps every chat
    // turn's token cost bounded regardless of what the user typed.
    final trimmedMessage = _truncateForPrompt(userMessage);

    final dateRange = _data.detectDateRange(trimmedMessage);
    final extra = await _maybeBuildExtraData(trimmedMessage, dateRange);
    final extraJson = extra.isEmpty ? '' : '\n\nExtra data:\n${jsonEncode(extra)}';

    final contextBlock = await _buildContextBlock(history);

    final snapshot = await _data.snapshot(
      rangeFrom: dateRange?.from,
      rangeTo: dateRange?.to,
      rangeLabel: dateRange?.label,
    );
    final factsBlock = facts.renderBlock();
    final factsText = factsBlock.isEmpty
        ? ''
        : '\n\nEstablished facts (most recent first):\n$factsBlock';
    final userPrompt =
        'Snapshot:\n${jsonEncode(snapshot)}$extraJson$factsText$contextBlock\n\n'
        'User message: $trimmedMessage';

    // Use the JSON-guaranteed wrapper: retries up to 3 times on null /
    // transport / non-JSON responses. On persistent non-JSON, the
    // wrapper returns a guaranteed-valid fallback AgentAnswer payload
    // so we never bubble up "couldn't parse" to the user.
    final raw = await _parser.chatCompletionJson(
      systemPrompt: _systemPrompt,
      userPrompt: userPrompt,
    );
    if (raw == null) {
      return const AgentAnswer(body: "I couldn't reach the AI service. Check your connection and API key, then try again.");
    }
    // Strip think-tag blocks before parsing — some models (DeepSeek,
    // Qwen, occasionally Anthropic with reasoning enabled) emit a
    // <think>...</think> / <reasoning>...</reasoning> block before
    // the actual JSON. The system prompt tells them not to, but we
    // also strip on our end so the user never sees raw scratchpad.
    final cleaned = stripThinkTags(raw);
    final parsed = AgentResponse.tryParse(cleaned);
    if (parsed == null) {
      return const AgentAnswer(
        body: "I'm having trouble forming a response right now — try again in a moment?",
      );
    }
    // Pre-validate any mutation params before the UI offers a Confirm
    // button. LLMs occasionally drop required fields (merchant,
    // amount, period) or send malformed strings (custom provider with
    // no base_url). Catching them here turns the next message into a
    // plain answer instead of a crashed action handler.
    final problem = _validateResponse(parsed);
    if (problem != null) {
      return AgentAnswer(body: problem);
    }
    return parsed;
  }

  /// Per-verb params sanity check. Returns a human-readable error
  /// string when a verb's params are obviously broken, or null when
  /// the response is fine. Only covers the most common LLM mistakes
  /// — anything this routine doesn't catch still surfaces as a
  /// runtime error in the action handler (which has its own
  /// try/catch and shows the same friendly fallback).
  static String? _validateResponse(AgentResponse r) {
    final specs = switch (r) {
      AgentAction() => [r.action],
      AgentActionPlan() => r.steps,
      _ => <AgentActionSpec>[],
    };
    for (final spec in specs) {
      final msg = _validateAction(spec);
      if (msg != null) return msg;
    }
    return null;
  }

  static String? _validateAction(AgentActionSpec spec) {
    final params = spec.params;
    switch (spec.name) {
      case 'create_expense':
        final amt = params['amount'];
        if (amt is! num || amt <= 0) {
          return 'The amount has to be a positive number — try something like "create expense \$5 at Amazon".';
        }
        final merchant = params['merchant'];
        if (merchant is! String || merchant.trim().isEmpty) {
          return 'Add a merchant or source name for the expense (e.g. "Coffee shop").';
        }
        final kind = params['kind'];
        if (kind != null && kind != 'spend' && kind != 'refund') {
          return 'kind must be "spend" or "refund" — try "create expense \$5 at Coffee" or "create expense \$10 refund from Bob".';
        }
        return null;

      case 'update_transaction':
        final match = params['match'];
        final id = match is Map ? match['id'] : null;
        if (id is! num) {
          return 'I need the transaction id to update an expense — say "find transaction <merchant>" first to resolve it.';
        }
        final updates = params['updates'];
        if (updates is! Map || updates.isEmpty) {
          return 'No updates provided — tell me what to change (amount, merchant, date, etc.).';
        }
        return null;

      case 'delete_transaction':
      case 'set_ignored':
        final id = params['id'];
        if (id is! num) {
          return 'I need the transaction id to ${spec.name == 'delete_transaction' ? 'delete' : 'update'} — say "find transaction <merchant>" first to resolve it.';
        }
        return null;

      case 'find_transaction':
        final hasAny = (params['merchant'] is String &&
                (params['merchant'] as String).trim().isNotEmpty) ||
            params['amount'] != null ||
            params['days_back'] != null ||
            params['min_amount'] != null ||
            params['max_amount'] != null;
        if (!hasAny) {
          return 'Give me at least one search term — merchant, amount range, or "last N days".';
        }
        return null;

      case 'create_budget':
        final name = params['name'];
        if (name is! String || name.trim().isEmpty) {
          return 'Budget needs a name — try "create budget Food \$200 monthly".';
        }
        final amount = params['amount'];
        if (amount is! num || amount <= 0) {
          return 'Budget amount has to be a positive number — try "create budget Food \$200 monthly".';
        }
        final period = params['period'];
        if (period != 'weekly' && period != 'monthly' && period != 'custom') {
          return 'Period must be weekly, monthly, or custom — try "create budget Food \$200 monthly".';
        }
        if (period == 'custom') {
          final start = params['start_date'];
          final end = params['end_date'];
          if (start is! String || end is! String) {
            return 'Custom-period budgets need both start_date and end_date as YYYY-MM-DD.';
          }
        }
        return null;

      case 'update_budget':
        final matched = (params['name'] is String &&
                (params['name'] as String).trim().isNotEmpty) ||
            params['id'] != null;
        if (!matched) {
          return 'Tell me which budget to update — give me its name or id.';
        }
        final updates = params['updates'];
        if (updates is! Map || updates.isEmpty) {
          return 'No updates provided — tell me what to change (amount, name, period).';
        }
        return null;

      case 'delete_budget':
      case 'set_active_budget':
        final matched = (params['name'] is String &&
                (params['name'] as String).trim().isNotEmpty) ||
            params['id'] != null;
        if (!matched) {
          return 'Tell me which budget by name (e.g. "Food") or id.';
        }
        return null;

      case 'update_ai_config':
        final provider = params['provider'];
        if (provider == 'custom' && (params['base_url'] is! String ||
            (params['base_url'] as String).trim().isEmpty)) {
          return 'Custom AI provider needs a base_url — tell me the OpenAI-compatible endpoint to use.';
        }
        return null;

      case 'bulk_delete_transactions':
        final hasAny = params['source'] != null ||
            (params['merchant_contains'] is String &&
                (params['merchant_contains'] as String).trim().isNotEmpty) ||
            params['before'] != null ||
            params['after'] != null ||
            params['min_amount'] != null ||
            params['max_amount'] != null;
        if (!hasAny) {
          return 'Bulk delete needs at least one filter — merchant, source, date range, or amount range — otherwise I\'d drop every row.';
        }
        return null;

      case 'clear_ai_log':
        final keep = params['keep_last'];
        if (keep is num && keep < 0) {
          return 'keep_last has to be 0 or greater.';
        }
        return null;

      case 'export_csv':
        final kind = params['kind'];
        if (kind != 'transactions' && kind != 'budgets') {
          return 'Export kind must be "transactions" or "budgets".';
        }
        return null;

      default:
        return null;
    }
  }

  /// Reset the conversation-memory cache. Call when the user clears
  /// the conversation — otherwise stale summary text would bleed into
  /// a fresh chat. Also wipes the structured fact ledger so a new
  /// chat doesn't inherit ids/budgets from the previous one.
  void clearMemory() {
    _summarizer.reset();
    facts.clear();
  }

  /// Drop the cached snapshot so the next [send] rebuilds it. Called
  /// from each agent action handler after a successful mutation so
  /// the model's next turn sees fresh state (e.g. a newly created
  /// budget, a deleted transaction). Pairs with [AgentData]'s own
  /// 30s TTL — that covers accidental lookups; this covers the
  /// "I just changed something, ask me about it" case.
  void invalidateSnapshotCache() => _data.invalidateSnapshotCache();

  /// Cap user-pasted text before it enters the LLM prompt. Verbose
  /// users and pasted log dumps both explode token cost without
  /// improving answer quality — 2000 chars is well past the length of
  /// any normal Pocket question and short enough that even a chatty
  /// explanation fits comfortably.
  static const int _userMessageCap = 2000;
  static String _truncateForPrompt(String msg) {
    if (msg.length <= _userMessageCap) return msg;
    return '${msg.substring(0, _userMessageCap)}…';
  }

  /// Below [_summaryThreshold] turns: just send the last [_verbatimCap]
  /// verbatim. At/above: ask [ConversationSummarizer] for the rolling
  /// summary of everything except the last [_keepLastN] turns and pair
  /// it with the verbatim last [_keepLastN] so the model sees both
  /// compressed history and the live thread.
  ///
  /// Threshold is high (50) so a normal-length chat never pays for an
  /// extra summary LLM call — the rolling summary is the slow path and
  /// it costs ~1s on top of the chat reply.
  ///
  /// keepLastN is high (24) so the most recent ~12 exchanges (where
  /// action params and ids live) stay untruncated. Previous value of 8
  /// dropped detail like "I just created expense #42" by the time the
  /// user asked "delete it" 10 turns later — that was the "agent keeps
  /// forgetting" bug.
  static const int _summaryThreshold = 50;
  static const int _keepLastN = 24;
  static const int _verbatimCap = 50;

  Future<String> _buildContextBlock(List<AgentMessage> history) async {
    if (history.isEmpty) return '';

    if (history.length > _summaryThreshold) {
      final summary = await _summarizer.ensureSummary(
        conversation: history,
        keepLastN: _keepLastN,
      );
      final tail = history.sublist(history.length - _keepLastN);
      final tailTranscript = _format(tail, perLineCap: 320);
      final summaryBlock = (summary == null || summary.isEmpty)
          ? ''
          : '\n\nSummary of the earlier ${history.length - _keepLastN} turns:\n$summary';
      return '$summaryBlock\n\n'
          'Last $_keepLastN turns (verbatim):\n$tailTranscript';
    }

    final tail = history.length > _verbatimCap
        ? history.sublist(history.length - _verbatimCap)
        : history;
    final transcript = _format(tail, perLineCap: 320);
    return '\n\nRecent conversation (the user just sent the last line):\n$transcript';
  }

  String _format(List<AgentMessage> turns, {required int perLineCap}) {
    final lines = <String>[];
    for (final m in turns) {
      final body = m.response?.text ?? m.text ?? '';
      if (body.trim().isEmpty) continue;
      final compact = body.trim().replaceAll(RegExp(r'\s+'), ' ');
      final truncated =
          compact.length > perLineCap ? '${compact.substring(0, perLineCap)}…' : compact;
      lines.add('${_roleLabel(m.role)}: $truncated');
    }
    return lines.join('\n');
  }

  String _roleLabel(AgentMessageRole r) => switch (r) {
        AgentMessageRole.user => 'user',
        AgentMessageRole.assistant => 'assistant',
        AgentMessageRole.error => 'system',
      };

  /// Cheap keyword-driven decision: if the user is asking for a chart or
  /// table, include the matching pre-computed dataset in the prompt so
  /// the model can pick labels without hallucinating numbers. Returns
  /// an empty map if no extra data is needed.
  Future<Map<String, Object?>> _maybeBuildExtraData(
    String msg,
    ({DateTime from, DateTime to, String label})? range,
  ) async {
    final m = msg.toLowerCase();
    final wantsChart = RegExp(r'\b(chart|graph|plot|trend|over time|weekly|monthly|daily)\b').hasMatch(m);
    final wantsTable = RegExp(r'\b(table|list|breakdown|top|by merchant|by source)\b').hasMatch(m);
    final wantsMerchants = RegExp(r'\b(merchant|store|where|spent on|spent at)\b').hasMatch(m);
    final wantsSources = RegExp(r'\b(source|gmail|paypal|google pay|manual)\b').hasMatch(m);

    if (!wantsChart && !wantsTable && !wantsMerchants && !wantsSources) {
      return const {};
    }

    final out = <String, Object?>{};
    final window = (range != null)
        ? (from: range.from, to: range.to)
        : _data.currentMonthRange();

    if (wantsChart) {
      final weekly = await _data.weeklyTotals(weeks: 8);
      out['weekly_totals'] = weekly
          .map((w) => {
                'label': w.label,
                'total': double.parse(w.total.toStringAsFixed(2)),
              })
          .toList(growable: false);
    }
    if (wantsTable || wantsMerchants) {
      final rows = await _data.topMerchantsTable(
        from: window.from,
        to: window.to,
        limit: 10,
      );
      out['top_merchants_in_range'] = {
        'range_label': range?.label ?? 'this month',
        'columns': ['merchant', 'total'],
        'rows': rows,
      };
    }
    if (wantsSources) {
      final bySource = await _data.spendBySource(window.from, window.to);
      out['spend_by_source'] = bySource.map(
        (k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2))),
      );
    }
    return out;
  }
}

