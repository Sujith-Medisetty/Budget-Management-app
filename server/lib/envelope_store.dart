import 'accounts_repo.dart';
import 'package:logging/logging.dart';
import 'package:postgres/postgres.dart';

/// Postgres-backed envelope store. Stores Gmail messages too large to
/// fit in a 4 KB FCM payload. The Pub/Sub handler writes one row per
/// oversized message and publishes a minimal
/// `{messageId, truncated: true}` marker to FCM; the mobile client
/// then GETs `/sync?messageId=<id>` and reads the envelope from here.
///
/// Writes are idempotent on `message_id` (re-deliveries from Pub/Sub
/// overwrite the same row) — keeps the row count flat and the read
/// side simple. Owner column [sub] makes DELETE /envelope safe to
/// verify against a leaked apiToken: only the recipient may drop it.
///
/// Rows are auto-expired by the [ttl] column. Until we wire pg_cron,
/// `tool/sweep_envelopes.dart` (or any external cron) should DELETE
/// expired rows every few hours. Replaying a delete that already
/// succeeded is harmless.
abstract class EnvelopeStore {
  Future<void> init();
  Future<void> put(
    String messageId,
    Map<String, String> envelope, {
    required String sub,
    required DateTime date,
    Duration ttl,
  });
  Future<void> delete(String messageId);
  Future<Map<String, dynamic>?> get(String messageId);
  Future<List<Map<String, dynamic>>> listSince(DateTime since);
}

class PostgresEnvelopeStore implements EnvelopeStore {
  PostgresEnvelopeStore({required this.repo});
  final AccountsRepo repo;
  final _log = Logger('envelopes');

  @override
  Future<void> init() => repo.init();

  @override
  Future<void> put(
    String messageId,
    Map<String, String> envelope, {
    required String sub,
    required DateTime date,
    Duration ttl = const Duration(hours: 24),
  }) async {
    final conn = await repo.ready();
    final expiresAt = DateTime.now().toUtc().add(ttl);
    await conn.execute(
      Sql.named('''
      INSERT INTO envelopes (message_id, sub, from_addr, subject, body, received_at, ttl)
      VALUES (@mid, @sub, @from, @subject, @body, @date, @ttl)
      ON CONFLICT (message_id) DO UPDATE SET
        sub = EXCLUDED.sub,
        from_addr = EXCLUDED.from_addr,
        subject = EXCLUDED.subject,
        body = EXCLUDED.body,
        received_at = EXCLUDED.received_at,
        ttl = EXCLUDED.ttl
      '''),
      parameters: {
        'mid': messageId,
        'sub': sub,
        'from': envelope['from'] ?? '',
        'subject': envelope['subject'] ?? '',
        'body': envelope['text'] ?? '',
        'date': date.toUtc(),
        'ttl': expiresAt,
      },
    );
    _log.info('envelope $messageId stored (sub=$sub, ttl=$expiresAt)');
  }

  @override
  Future<void> delete(String messageId) async {
    final conn = await repo.ready();
    final res = await conn.execute(
      Sql.named('DELETE FROM envelopes WHERE message_id=@mid'),
      parameters: {'mid': messageId},
    );
    if (res.affectedRows == 0) {
      _log.info('envelope $messageId already gone (or TTL\'d out)');
      return;
    }
    _log.info('envelope $messageId deleted');
  }

  @override
  Future<Map<String, dynamic>?> get(String messageId) async {
    final conn = await repo.ready();
    final res = await conn.execute(
      Sql.named('SELECT message_id, sub, from_addr, subject, body, received_at '
          'FROM envelopes WHERE message_id=@mid'),
      parameters: {'mid': messageId},
    );
    if (res.isEmpty) return null;
    final row = res.first;
    return {
      'messageId': row[0]! as String,
      'sub': row[1]! as String,
      'from': row[2]! as String,
      'subject': row[3]! as String,
      'date': (row[5]! as DateTime).toUtc().toIso8601String(),
      'text': row[4]! as String,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> listSince(DateTime since) async {
    final conn = await repo.ready();
    final res = await conn.execute(
      Sql.named('SELECT message_id, sub, from_addr, subject, body, received_at '
          'FROM envelopes WHERE received_at > @since '
          'ORDER BY received_at ASC LIMIT 100'),
      parameters: {'since': since.toUtc()},
    );
    return res.map((row) => {
          'messageId': row[0]! as String,
          'sub': row[1]! as String,
          'from': row[2]! as String,
          'subject': row[3]! as String,
          'date': (row[5]! as DateTime).toUtc().toIso8601String(),
          'text': row[4]! as String,
        }).toList(growable: false);
  }
}

