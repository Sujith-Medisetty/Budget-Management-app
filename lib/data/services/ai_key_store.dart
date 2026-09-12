import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_config.dart';

/// Owns persistence for AI config. Two halves:
///   - non-secret (provider, model, baseUrl) in SharedPreferences
///   - API key in flutter_secure_storage, keyed by provider so users can
///     rotate or stash more than one at a time.
class AiKeyStore {
  AiKeyStore(this._secure, this._prefs);

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final FlutterSecureStorage _secure;
  final SharedPreferences _prefs;

  static const _kProvider = 'ai_provider';
  static const _kModel = 'ai_model';
  static const _kBaseUrl = 'ai_base_url';
  // Legacy key from the pre-AI-only build. Older installs may still
  // have a stored parser-mode value here — read() ignores it and
  // clearAll() scrubs it so the prefs file eventually sheds the cruft.
  static const _kLegacyParserMode = 'ai_parser_mode';

  static Future<AiKeyStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return AiKeyStore(_secureStorage, prefs);
  }

  static String _keyFor(CloudProvider p) => 'ai_key_${p.name}';

  Future<AiConfig> read() async {
    final providerName = _prefs.getString(_kProvider);
    final provider = CloudProvider.values.firstWhere(
      (p) => p.name == providerName,
      orElse: () => CloudProvider.openai,
    );
    final model = _prefs.getString(_kModel) ?? provider.defaultModel;
    final baseUrl = _prefs.getString(_kBaseUrl);
    final key = await _secure.read(key: _keyFor(provider));
    return AiConfig(
      provider: provider,
      model: model,
      hasKey: key != null && key.isNotEmpty,
      baseUrl: (baseUrl != null && baseUrl.isNotEmpty) ? baseUrl : null,
    );
  }

  Future<void> writeProvider(CloudProvider p) async {
    await _prefs.setString(_kProvider, p.name);
    // Reset model to the provider default if the current one was empty.
    if (_prefs.getString(_kModel) == null ||
        _prefs.getString(_kModel)!.isEmpty) {
      await _prefs.setString(_kModel, p.defaultModel);
    }
  }

  Future<void> writeModel(String model) async {
    await _prefs.setString(_kModel, model);
  }

  Future<void> writeBaseUrl(String? url) async {
    if (url == null || url.trim().isEmpty) {
      await _prefs.remove(_kBaseUrl);
    } else {
      await _prefs.setString(_kBaseUrl, url.trim());
    }
  }

  Future<void> writeKey(CloudProvider p, String key) async {
    if (key.isEmpty) {
      await _secure.delete(key: _keyFor(p));
    } else {
      await _secure.write(key: _keyFor(p), value: key);
    }
  }

  Future<String?> readKey(CloudProvider p) async =>
      _secure.read(key: _keyFor(p));

  Future<void> clearAll() async {
    await _prefs.remove(_kProvider);
    await _prefs.remove(_kModel);
    await _prefs.remove(_kLegacyParserMode);
    for (final p in CloudProvider.values) {
      await _secure.delete(key: _keyFor(p));
    }
  }
}