import 'ai_config.dart';

/// Static catalog of widely-available models per provider. Used to
/// power the searchable model picker in AI settings. Update this when
/// new flagship / mini / flash variants ship. The user can always type
/// a custom model name even if it's not in the catalog.
class ModelInfo {
  const ModelInfo({required this.id, required this.label, this.note});
  final String id;
  final String label;
  final String? note;
}

const modelCatalog = <CloudProvider, List<ModelInfo>>{
  CloudProvider.openai: [
    ModelInfo(
      id: 'gpt-4o-mini',
      label: 'GPT-4o mini',
      note: 'Cheap, fast, great default for short tasks',
    ),
    ModelInfo(id: 'gpt-4o', label: 'GPT-4o', note: 'Flagship multimodal'),
    ModelInfo(
      id: 'gpt-4-turbo',
      label: 'GPT-4 Turbo',
      note: 'Older flagship, still strong',
    ),
    ModelInfo(id: 'gpt-4', label: 'GPT-4', note: 'Classic'),
    ModelInfo(
      id: 'gpt-3.5-turbo',
      label: 'GPT-3.5 Turbo',
      note: 'Budget option',
    ),
    ModelInfo(id: 'o1', label: 'o1', note: 'Reasoning model, slow + pricey'),
    ModelInfo(
      id: 'o1-mini',
      label: 'o1-mini',
      note: 'Reasoning, lighter',
    ),
    ModelInfo(
      id: 'o3-mini',
      label: 'o3-mini',
      note: 'Latest reasoning-mini',
    ),
    ModelInfo(id: 'o4-mini', label: 'o4-mini', note: 'Newer reasoning-mini'),
    ModelInfo(id: 'gpt-5', label: 'GPT-5', note: 'Next-gen flagship'),
    ModelInfo(id: 'gpt-5-mini', label: 'GPT-5 mini'),
    ModelInfo(id: 'gpt-5-nano', label: 'GPT-5 nano', note: 'Cheapest GPT-5'),
  ],
  CloudProvider.anthropic: [
    ModelInfo(
      id: 'claude-3-5-haiku-latest',
      label: 'Claude 3.5 Haiku',
      note: 'Fast, cheap — great default',
    ),
    ModelInfo(
      id: 'claude-3-5-sonnet-latest',
      label: 'Claude 3.5 Sonnet',
      note: 'Balanced quality/speed',
    ),
    ModelInfo(
      id: 'claude-3-opus-latest',
      label: 'Claude 3 Opus',
      note: 'Highest quality, slow',
    ),
    ModelInfo(id: 'claude-3-sonnet-20240229', label: 'Claude 3 Sonnet'),
    ModelInfo(id: 'claude-3-haiku-20240307', label: 'Claude 3 Haiku'),
    ModelInfo(id: 'claude-3-opus-20240229', label: 'Claude 3 Opus (pinned)'),
    ModelInfo(
      id: 'claude-sonnet-4-5',
      label: 'Claude Sonnet 4.5',
      note: 'Latest Sonnet',
    ),
    ModelInfo(id: 'claude-haiku-4-5', label: 'Claude Haiku 4.5'),
    ModelInfo(id: 'claude-opus-4-1', label: 'Claude Opus 4.1'),
  ],
  CloudProvider.google: [
    ModelInfo(
      id: 'gemini-1.5-flash-latest',
      label: 'Gemini 1.5 Flash',
      note: 'Fast, very cheap',
    ),
    ModelInfo(
      id: 'gemini-1.5-flash-8b-latest',
      label: 'Gemini 1.5 Flash-8B',
      note: 'Cheapest Gemini',
    ),
    ModelInfo(
      id: 'gemini-1.5-pro-latest',
      label: 'Gemini 1.5 Pro',
      note: 'Stronger reasoning',
    ),
    ModelInfo(
      id: 'gemini-2.0-flash-exp',
      label: 'Gemini 2.0 Flash (exp)',
      note: 'Experimental, fast',
    ),
    ModelInfo(
      id: 'gemini-2.0-flash-lite',
      label: 'Gemini 2.0 Flash Lite',
    ),
    ModelInfo(id: 'gemini-2.5-flash', label: 'Gemini 2.5 Flash'),
    ModelInfo(id: 'gemini-2.5-pro', label: 'Gemini 2.5 Pro'),
    ModelInfo(id: 'gemini-2.5-flash-lite', label: 'Gemini 2.5 Flash Lite'),
  ],
  CloudProvider.minimax: [
    ModelInfo(
      id: 'MiniMax-M3',
      label: 'MiniMax M3',
      note: 'Latest general model',
    ),
    ModelInfo(
      id: 'MiniMax-M2.7-highspeed',
      label: 'MiniMax M2.7 Highspeed',
      note: 'Faster variant',
    ),
    ModelInfo(id: 'MiniMax-M2.7', label: 'MiniMax M2.7'),
    ModelInfo(
      id: 'MiniMax-M2.5-highspeed',
      label: 'MiniMax M2.5 Highspeed',
      note: 'Default — fast + cheap',
    ),
    ModelInfo(
      id: 'MiniMax-M2.1-highspeed',
      label: 'MiniMax M2.1 Highspeed',
      note: 'Cheaper highspeed variant',
    ),
    ModelInfo(id: 'MiniMax-H3', label: 'MiniMax H3', note: 'Newer tier'),
    ModelInfo(
      id: 'MiniMax-M2',
      label: 'MiniMax M2',
      note: 'Previous generation',
    ),
  ],
};

List<ModelInfo> modelsFor(CloudProvider p) {
  if (p == CloudProvider.custom) return const [];
  return modelCatalog[p] ?? const [];
}