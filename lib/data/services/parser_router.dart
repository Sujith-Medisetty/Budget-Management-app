import 'package:flutter/foundation.dart';

import '../models/parsed_transaction.dart';
import '../models/raw_notification.dart';
import 'ai_key_store.dart';
import 'cloud_ai_parser.dart';

/// Single entry point for parsing a [RawNotification] into a
/// [ParsedTransaction]. Always routes through the user's cloud AI
/// model — no regex fallback, no offline short-circuit. If no API key
/// is configured, [parse] returns null and the notification is dropped
/// (the user can still log expenses manually).
///
/// One [ParserRouter] per app instance — the constructor reads
/// [AiKeyStore] on every [parse] call so key / model / provider
/// changes take effect immediately without rebuilding providers.
class ParserRouter {
  ParserRouter({required this._store});

  final AiKeyStore _store;

  Future<ParsedTransaction?> parse(RawNotification n) async {
    final config = await _store.read();
    if (!config.hasKey) {
      if (kDebugMode) {
        debugPrint('[ai] no API key configured — dropping ${n.notificationKey}');
      }
      return null;
    }
    final key = await _store.readKey(config.provider);
    if (key == null || key.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          '[ai] key missing for ${config.provider.name} — dropping '
          '${n.notificationKey}',
        );
      }
      return null;
    }
    return CloudAiParser(config: config, apiKey: key).parse(n);
  }
}
