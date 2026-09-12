import '../database/database_helper.dart';
import '../models/ai_log_entry.dart';

/// Persists the rolling AI activity log (capped at [maxRows] = 50).
/// Every parse attempt (kept or dropped) gets one row, and on each
/// insert the table is trimmed back down to the most recent entries
/// so the store never grows unbounded.
///
/// Static API because the parser, pipeline, FCM bridge, and Gmail
/// sync all want to log and none of them want a Riverpod dependency
/// pulled into their call chain.
class AiLogStore {
  AiLogStore._();

  static const int maxRows = 50;

  static Future<void> record({
    required String package,
    required String sourceText,
    String? aiResponse,
    required String decision,
    String? reason,
    double? parsedAmount,
    String? parsedMerchant,
    String? parsedSource,
  }) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert('ai_log', {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'package': package,
      'source_text': sourceText,
      'ai_response': aiResponse,
      'decision': decision,
      'reason': reason,
      'parsed_amount': parsedAmount,
      'parsed_merchant': parsedMerchant,
      'parsed_source': parsedSource,
    });
    await _prune(db);
  }

  static Future<List<AiLogEntry>> list() async {
    final db = await DatabaseHelper.instance.database;
    final rows = await db.query(
      'ai_log',
      orderBy: 'ts DESC',
      limit: maxRows,
    );
    return rows.map(AiLogEntry.fromMap).toList();
  }

  static Future<void> clear() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('ai_log');
  }

  /// Deletes one row by id. No-op if the id doesn't exist. Used by
  /// the agent verb `delete_activity_log_entry` and by the activity
  /// log screen's per-row delete.
  static Future<int> deleteById(int id) async {
    final db = await DatabaseHelper.instance.database;
    return db.delete('ai_log', where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> _prune(dynamic db) async {
    // Keeps the newest `maxRows` rows. Subquery returns the threshold
    // id, then we delete everything else. Cheaper than re-counting on
    // every read.
    await db.execute('''
      DELETE FROM ai_log WHERE id NOT IN (
        SELECT id FROM ai_log ORDER BY ts DESC LIMIT ?
      )
    ''', [maxRows]);
  }
}
