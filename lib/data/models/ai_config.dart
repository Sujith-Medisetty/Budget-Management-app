/// Which cloud AI provider the user has picked. Determines the request
/// shape, auth header, and model defaults. [CloudProvider.custom] uses
/// the OpenAI chat-completions format against a user-supplied base URL,
/// so it covers any OpenAI-compatible host (DeepSeek, Groq, Mistral,
/// Together, OpenRouter, Perplexity, Fireworks, xAI, …).
enum CloudProvider { openai, anthropic, google, minimax, custom }

extension CloudProviderX on CloudProvider {
  String get label => switch (this) {
    CloudProvider.openai => 'OpenAI',
    CloudProvider.anthropic => 'Anthropic',
    CloudProvider.google => 'Google AI Studio',
    CloudProvider.minimax => 'MiniMax',
    CloudProvider.custom => 'Custom (OpenAI-compatible)',
  };

  String get defaultModel => switch (this) {
    CloudProvider.openai => 'gpt-4o-mini',
    CloudProvider.anthropic => 'claude-3-5-haiku-latest',
    CloudProvider.google => 'gemini-1.5-flash-latest',
    CloudProvider.minimax => 'MiniMax-M2.5-highspeed',
    CloudProvider.custom => '',
  };

  String get helpUrl => switch (this) {
    CloudProvider.openai => 'https://platform.openai.com/api-keys',
    CloudProvider.anthropic => 'https://console.anthropic.com/settings/keys',
    CloudProvider.google => 'https://aistudio.google.com/apikey',
    CloudProvider.minimax => 'https://platform.minimax.io/user-center/basic-information/interface-key',
    CloudProvider.custom => 'https://platform.openai.com/docs/api-reference/chat',
  };

  /// Where to fetch models from, if any. Null for the four presets
  /// (their catalogs are hand-curated) and for custom (no catalog).
  String? get modelsListUrl => null;
}

/// Persisted non-secret config for cloud AI. API key is stored
/// separately via [AiKeyStore] so it never touches plaintext prefs.
class AiConfig {
  const AiConfig({
    required this.provider,
    required this.model,
    required this.hasKey,
    this.baseUrl,
  });

  final CloudProvider provider;
  final String model;
  final bool hasKey;

  /// Used only when [provider] is [CloudProvider.custom]. The full
  /// URL is built as `{baseUrl}/chat/completions` with `/v1` left to
  /// the user to include if their provider needs it.
  final String? baseUrl;

  AiConfig copyWith({
    CloudProvider? provider,
    String? model,
    bool? hasKey,
    String? baseUrl,
  }) {
    return AiConfig(
      provider: provider ?? this.provider,
      model: model ?? this.model,
      hasKey: hasKey ?? this.hasKey,
      baseUrl: baseUrl ?? this.baseUrl,
    );
  }
}