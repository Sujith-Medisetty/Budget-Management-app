import 'dart:convert';

import '../util/strip_think_blocks.dart';

/// The five shapes the agent can return. All are decoded from a single
/// JSON blob the LLM emits; the `kind` field chooses which one we got.
/// The model is asked (via system prompt) to return exactly one of these
/// — anything unparseable falls back to [AgentAnswer] with whatever
/// text we managed to extract.
sealed class AgentResponse {
  const AgentResponse();

  /// What to show as the assistant's text in the chat bubble.
  String get text;

  factory AgentResponse.fromJson(Map<String, Object?> json) {
    final kind = json['kind'] as String?;
    switch (kind) {
      case 'chart':
        return AgentChart.fromJson(json);
      case 'table':
        return AgentTable.fromJson(json);
      case 'action':
        return AgentAction.fromJson(json);
      case 'action_plan':
        return AgentActionPlan.fromJson(json);
      case 'clarify':
        return AgentClarify.fromJson(json);
      case 'answer':
      default:
        return AgentAnswer.fromJson(json);
    }
  }

  /// Best-effort: take raw LLM output, peel fences / reasoning tags,
  /// return a response object or null if nothing usable came back.
  static AgentResponse? tryParse(String raw) {
    // Strip reasoning blocks (<think>, <thinking>, <reason>, etc.,
    // closed or unclosed). Some models emit reasoning alongside the
    // structured payload and we only want the payload.
    var trimmed = stripThinkBlocks(raw);
    if (trimmed.isEmpty) trimmed = raw.trim();
    Map<String, Object?>? json;
    try {
      json = jsonDecode(trimmed) as Map<String, Object?>;
    } catch (_) {
      final fence = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
      final m = fence.firstMatch(trimmed);
      if (m != null) {
        try {
          json = jsonDecode(m.group(1)!) as Map<String, Object?>;
        } catch (_) {}
      }
    }
    if (json == null) {
      final start = trimmed.indexOf('{');
      final end = trimmed.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          json = jsonDecode(trimmed.substring(start, end + 1))
              as Map<String, Object?>;
        } catch (_) {}
      }
    }
    if (json == null) return null;
    return AgentResponse.fromJson(json);
  }
}

/// Plain text answer. The fallback shape — anything we can't classify
/// becomes one of these.
class AgentAnswer extends AgentResponse {
  const AgentAnswer({required this.body});
  final String body;

  @override
  String get text => body;

  factory AgentAnswer.fromJson(Map<String, Object?> json) {
    return AgentAnswer(
      body: (json['text'] as String?)?.trim().isNotEmpty == true
          ? json['text'] as String
          : 'I don’t have a clear answer for that.',
    );
  }
}

/// The model wants to show a chart. Buckets are pre-computed client-side;
/// the model only picks the chart kind + text.
class AgentChart extends AgentResponse {
  const AgentChart({
    required this.body,
    required this.chartKind,
    required this.buckets,
  });
  final String body;
  final AgentChartKind chartKind;
  final List<AgentBucket> buckets;

  @override
  String get text => body;

  factory AgentChart.fromJson(Map<String, Object?> json) {
    final raw = (json['buckets'] as List?) ?? const [];
    final buckets = raw
        .whereType<Map<String, Object?>>()
        .map(AgentBucket.fromJson)
        .where((b) => b.value.isFinite)
        .toList(growable: false);
    final kindStr = (json['chart_kind'] as String?) ?? 'bar';
    return AgentChart(
      body: (json['text'] as String?) ?? '',
      chartKind: AgentChartKind.values.firstWhere(
        (k) => k.name == kindStr,
        orElse: () => AgentChartKind.bar,
      ),
      buckets: buckets,
    );
  }
}

enum AgentChartKind { bar, line, pie }

class AgentBucket {
  const AgentBucket({required this.label, required this.value});
  final String label;
  final double value;

  factory AgentBucket.fromJson(Map<String, Object?> json) {
    final v = json['value'];
    double parsed;
    if (v is num) {
      parsed = v.toDouble();
    } else if (v is String) {
      parsed = double.tryParse(v) ?? 0;
    } else {
      parsed = 0;
    }
    return AgentBucket(label: (json['label'] as String?) ?? '', value: parsed);
  }
}

/// Tabular answer. Same rule: rows are pre-computed, model picks cols.
class AgentTable extends AgentResponse {
  const AgentTable({
    required this.body,
    required this.columns,
    required this.rows,
  });
  final String body;
  final List<String> columns;
  final List<List<String>> rows;

  @override
  String get text => body;

  factory AgentTable.fromJson(Map<String, Object?> json) {
    final cols = ((json['columns'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(growable: false);
    final rawRows = ((json['rows'] as List?) ?? const [])
        .whereType<List>()
        .map((r) => r.map((e) => e?.toString() ?? '').toList(growable: false))
        .toList(growable: false);
    return AgentTable(body: (json['text'] as String?) ?? '', columns: cols, rows: rawRows);
  }
}

/// The model wants the user to confirm a mutation. The card shows the
/// params in plain language; the user taps Confirm to execute locally.
class AgentAction extends AgentResponse {
  const AgentAction({required this.body, required this.action});
  final String body;
  final AgentActionSpec action;

  @override
  String get text => body;

  factory AgentAction.fromJson(Map<String, Object?> json) {
    final spec = json['action'];
    final params = (json['params'] as Map<String, Object?>?) ?? const {};
    return AgentAction(
      body: (json['text'] as String?) ?? '',
      action: AgentActionSpec(name: (spec as String?) ?? 'unknown', params: params),
    );
  }
}

/// The model wants the user to confirm a CHAIN of mutations that
/// depend on each other ("create a budget then add 3 expenses to it").
/// The card shows all steps in a numbered list with one Confirm button;
/// on confirm we run the steps in order, surfacing per-step status
/// (pending / running / done / failed) so the user can see exactly how
/// far the chain got. Each step uses the same verbs and param shapes
/// as a single [AgentAction] — the model just bundles several together
/// when the user clearly asked for more than one thing.
///
/// Use this for plans (N>1 steps). For a single mutation, still return
/// `kind: "action"`. Steps must each be self-contained — we don't
/// thread outputs of one step into params of the next automatically.
class AgentActionPlan extends AgentResponse {
  const AgentActionPlan({required this.body, required this.steps});
  final String body;
  final List<AgentActionSpec> steps;

  @override
  String get text => body;

  factory AgentActionPlan.fromJson(Map<String, Object?> json) {
    final body = (json['text'] as String?) ?? '';
    final raw = (json['steps'] as List?) ?? const [];
    final steps = raw
        .whereType<Map<String, Object?>>()
        .map(AgentActionSpec.fromJson)
        .toList(growable: false);
    return AgentActionPlan(body: body, steps: steps);
  }
}

class AgentActionSpec {
  const AgentActionSpec({required this.name, required this.params});
  final String name;
  final Map<String, Object?> params;

  factory AgentActionSpec.fromJson(Map<String, Object?> json) {
    final name = (json['action'] as String?) ?? 'unknown';
    final params = (json['params'] as Map<String, Object?>?) ?? const {};
    return AgentActionSpec(name: name, params: params);
  }
}

/// The model needs more info from the user before it can answer.
class AgentClarify extends AgentResponse {
  const AgentClarify({required this.question});
  final String question;

  @override
  String get text => question;

  factory AgentClarify.fromJson(Map<String, Object?> json) {
    return AgentClarify(
      question: (json['question'] as String?)?.trim().isNotEmpty == true
          ? json['question'] as String
          : 'Could you give me a bit more detail?',
    );
  }
}
