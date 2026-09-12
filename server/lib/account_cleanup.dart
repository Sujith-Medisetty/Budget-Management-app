import 'backup_scheduler.dart';
import 'backup_snapshot.dart';
import 'config.dart';
import 'crypto.dart';
import 'dart:async';
import 'filters_sync.dart';
import 'gmail_filter_rules.dart';
import 'gmail_filter_sync.dart';
import 'package:logging/logging.dart';
import 'token_store.dart';

/// Why a single helper exists: every code path that ends a user's
/// relationship with Pocket — explicit sign-out, devices/signout
/// when the last FCM token is gone, and the FCM UNREGISTERED signal
/// (the server's only reactive hook for app uninstall) — must leave
/// the same trail of deletions behind. Anything the helper misses
/// (typically the Gmail-side filter, which is the most-skipped step)
/// leaks forever in the user's actual Gmail account, where the user
/// can see it but we can't reach it via a TTL.
///
/// Failure mode is best-effort with structured logging at every step.
/// Worst case: Firestore records gone but one Gmail filter stays
/// around — the user can still remove it manually from Gmail
/// Settings → Filters. The reverse (Gmail filter gone but Firestore
/// records present) is much worse, because we'd silently lose the
/// rule mapping with no user-visible signal.
Future<void> deleteAccountCompletely({
  required ServerConfig config,
  required TokenStore tokens,
  required TokenCipher cipher,
  required FilterRuleStore rules,
  required String sub,
  required String reason,
  // Test-injection hooks — production wiring passes nothing and
  // gets the real GmailFilterSync + OAuth exchange. Mirrors the
  // pattern in `filtersSyncHandler`.
  GmailFilterSync Function(String accessToken, {String? pocketLabelId})?
      gmailFactory,
  Future<String> Function(String refreshToken)? exchangeRefresh,
  // Optional backup store — when provided, the backup doc is wiped
  // alongside filter_rules so the user's snapshots don't outlive the
  // account. Skipped silently when null (test path).
  BackupStore? backups,
  // Optional backup scheduler — when provided, the per-user
  // `pocket-backup-{sub}.{service,timer}` systemd units are torn
  // down so the trigger doesn't keep firing into the void for an
  // account that's been wiped. Skipped silently when null (test path).
  BackupScheduler? backupScheduler,
}) async {
  final log = Logger('account-cleanup');
  log.info('deleting account $sub (reason=$reason)');

  final record = await tokens.get(sub);
  final exchange = exchangeRefresh ?? (r) => exchangeRefreshToken(r, config);
  final factory = gmailFactory ??
      ((t, {String? pocketLabelId}) =>
          GmailFilterSync(
            accessToken: t,
            config: config,
            pocketLabelId: pocketLabelId,
          ));

  // 1. Delete every Gmail-side filter this user has. The 1:1 mapping
  // between Pocket rules and Gmail filters means we can iterate the
  // server-side FilterRuleSet, pull the Gmail `id` off each rule,
  // and call DELETE /filters/{id}. Idempotent (GmailFilterSync
  // treats 404 as success). Requires a fresh access token from the
  // stored refresh token — if the user revoked Gmail scopes, this
  // step fails and we proceed with Firestore deletes anyway.
  if (record != null) {
    try {
      final refreshPlain = await cipher.open(record.refreshToken);
      final accessToken = await exchange(refreshPlain);
      final existing = await rules.get(sub);
      if (existing != null) {
        final gmail = factory(accessToken,
            pocketLabelId: record.pocketLabelId);
        for (final r in existing.rules) {
          if (r.id == null) continue;
          try {
            await gmail.deleteFilter(r.id!);
          } catch (e) {
            log.warning('gmail filter delete(${r.id}) failed for $sub '
                '(continuing): $e');
          }
        }
      }
    } catch (e) {
      log.warning('gmail filter cleanup failed for $sub (continuing): $e');
    }
  }

  // 2. Delete the account record. tokens.remove() swallows 404 so
  // it's safe to call after the user has already signed out via
  // /oauth/signout (which only deletes accounts/{sub} + filter_rules).
  try {
    await tokens.remove(sub);
  } catch (e) {
    log.warning('tokens.remove($sub) failed: $e');
  }

  // 3. Delete the filter_rules doc. Same idempotent-404 semantics.
  try {
    await rules.remove(sub);
  } catch (e) {
    log.warning('rules.remove($sub) failed: $e');
  }

  // 4. Delete the backup snapshot if a store was wired in. Skipped
  //    when null (test wiring). Same idempotent-404 semantics.
  if (backups != null) {
    try {
      await backups.remove(sub);
    } catch (e) {
      log.warning('backups.remove($sub) failed: $e');
    }
  }

  // 5. Tear down the per-user systemd timer + service units. The
  //    pocket_schedules row drops via FK CASCADE in step 2. Best-
  //    effort: if no units exist (user never enabled backup) the
  //    disable is a no-op; if systemctl fails we log and continue so
  //    the row-level delete still wins.
  if (backupScheduler != null) {
    try {
      await backupScheduler.disableForDeletedSub(sub);
    } catch (e) {
      log.warning('backupScheduler.disableForDeletedSub($sub) failed: $e');
    }
  }

  // 6. Envelopes are NOT eagerly swept — the 24h Firestore TTL
  // handles cleanup for unread envelopes. The user's install path
  // will fetch /sync?since=<last-sync> on first launch and only see
  // their own envelopes, so a brief window of orphaned envelopes is
  // invisible to the next user.

  log.info('account $sub fully deleted (reason=$reason)');
}

