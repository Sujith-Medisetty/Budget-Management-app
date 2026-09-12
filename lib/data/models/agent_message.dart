import 'agent_response.dart';

enum AgentMessageRole { user, assistant, error }

/// One entry in the agent conversation. User messages just carry text.
/// Assistant messages carry a parsed [AgentResponse] (the renderer picks
/// which widget to use based on the runtime type). Errors carry text +
/// a flag so we can show a retry affordance.
class AgentMessage {
  const AgentMessage({
    required this.role,
    this.text,
    this.response,
    this.id,
    this.actionConfirmed,
    this.planStepStatuses,
  });

  /// Stable id for the list. Null until we mint one when appending.
  final String? id;
  final AgentMessageRole role;

  /// Used for user messages and the plain-text fallback when the
  /// assistant returns prose without a structured response.
  final String? text;

  /// Used for assistant turns. Null if the response was unparseable
  /// and we fell back to a plain error bubble.
  final AgentResponse? response;

  /// For single-action cards: did the user tap Confirm / Cancel?
  final AgentActionStatus? actionConfirmed;

  /// For action_plan cards: per-step status list. Length matches
  /// `response.steps.length` when populated. The widget falls back to
  /// a derived view (all pending / all done) when this is null.
  final List<AgentActionStatus>? planStepStatuses;

  AgentMessage copyWith({
    AgentMessageRole? role,
    String? text,
    AgentResponse? response,
    AgentActionStatus? actionConfirmed,
    List<AgentActionStatus>? planStepStatuses,
    String? id,
  }) {
    return AgentMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      text: text ?? this.text,
      response: response ?? this.response,
      actionConfirmed: actionConfirmed ?? this.actionConfirmed,
      planStepStatuses: planStepStatuses ?? this.planStepStatuses,
    );
  }

  /// Replace the id; used when first appending (id is null until then).
  AgentMessage withId(String newId) => copyWith(id: newId);

  factory AgentMessage.user(String text) =>
      AgentMessage(role: AgentMessageRole.user, text: text);
  factory AgentMessage.assistant(AgentResponse r) =>
      AgentMessage(role: AgentMessageRole.assistant, response: r);
  factory AgentMessage.error(String text) =>
      AgentMessage(role: AgentMessageRole.error, text: text);
}

enum AgentActionStatus { pending, confirmed, cancelled }
