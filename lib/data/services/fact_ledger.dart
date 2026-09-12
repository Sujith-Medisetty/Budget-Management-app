/// Structured fact ledger for the agent. Holds the small set of concrete
/// facts the agent has established or mutated during the current chat:
/// transaction ids created, budgets made/edited/deleted, user preferences
/// captured, etc.
///
/// Unlike the conversation summary (which is prose and degrades with
/// recompression), facts are stored as structured records and rendered
/// verbatim into the system prompt on every turn. The model can rely on
/// them as authoritative — they survive summarization, they never get
/// truncated to a paragraph, and they never get lost in summarizer cache
/// eviction.
///
/// Lives for the lifetime of the AgentService. Chat clears wipe it via
/// [AgentService.clearMemory].
class FactLedger {
  final List<AgentFact> _facts = [];

  /// Bounded ring buffer. Oldest fact drops off the front when we exceed
  /// this — the summary is responsible for compressing anything older
  /// than the window.
  static const int _maxFacts = 50;

  /// Number of recent facts rendered into the system prompt. Bounded
  /// so the facts block stays a few hundred chars even in a long chat.
  static const int _renderedFacts = 12;

  void add(AgentFact fact) {
    _facts.add(fact);
    if (_facts.length > _maxFacts) {
      _facts.removeRange(0, _facts.length - _maxFacts);
    }
  }

  void clear() => _facts.clear();

  /// Most-recent first. Empty string when there's nothing to say — caller
  /// can drop the section entirely instead of including an empty header.
  String renderBlock() {
    if (_facts.isEmpty) return '';
    final tail = _facts.length > _renderedFacts
        ? _facts.sublist(_facts.length - _renderedFacts)
        : _facts;
    final lines = tail.map((f) => '- ${f.description}').join('\n');
    return lines;
  }

  int get length => _facts.length;
}

/// One established fact the agent can rely on. [description] is the
/// human-readable form that goes into the system prompt; [data] is the
/// structured form for callers that want to query (kept here for future
/// use — current callers only need [description]).
class AgentFact {
  AgentFact({
    required this.kind,
    required this.description,
    this.data = const {},
  });

  /// Stable kind tag: 'expense_created', 'budget_created',
  /// 'budget_updated', 'budget_deleted', 'transaction_updated',
  /// 'transaction_deleted', 'transactions_bulk_deleted',
  /// 'filter_rule_added', etc. Lets future tooling filter without
  /// parsing prose.
  final String kind;

  /// One-line, concrete, names ids/amounts/merchants. Model can quote
  /// this verbatim. Examples:
  ///   "Created expense #42: \$5.00 at Amazon"
  ///   "Created budget #3: \"Food\" at \$200/month (now active)"
  ///   "Deleted transaction #88 (\$12 Amazon)"
  final String description;

  /// Structured payload for programmatic use. Optional — most callers
  /// only need the description.
  final Map<String, Object?> data;
}
