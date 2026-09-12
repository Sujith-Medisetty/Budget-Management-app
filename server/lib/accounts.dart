import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth.dart';
import 'backup_scheduler.dart';
import 'budget_rollover.dart';
import 'budgets_repo.dart';
import 'config.dart';
import 'token_store.dart';

/// `GET /accounts/{sub}` — return the full per-user account record
/// (auth tokens + per-user config: backup prefs, filter rules, last
/// sync/backup timestamps). The phone calls this on sign-in to
/// hydrate its local `accounts` SQLite table; the previous design
/// split this across multiple endpoints (`/filters/status`,
/// `/admin/backup-preference` round-trips, etc.) which cost extra
/// round trips and drift on partial failures.
///
/// Auth: Bearer apiToken. The path's `sub` must match the
/// authenticated user's `sub` (or the caller is the admin). The
/// sub-mismatch case returns 403, not 404 — leaking account
/// existence to a wrong-sub probe would help an attacker enumerate
/// active subs, even if they can't read the fields.
Future<Response> Function(Request) accountsGetHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth,
) {
  return (Request req) async {
    final sub = req.params['sub'];
    if (sub == null || sub.isEmpty) {
      return Response.badRequest(body: 'sub path param required');
    }
    final deny = await _authorizeSelfOrAdmin(
      config: config,
      tokens: tokens,
      auth: auth,
      req: req,
      targetSub: sub,
    );
    if (deny != null) return deny;

    final record = await tokens.get(sub);
    if (record == null) {
      return Response(404,
          body: jsonEncode({'error': 'no account for $sub'}),
          headers: {'content-type': 'application/json'});
    }
    return Response.ok(
      jsonEncode(_encodeAccountRecord(record)),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `PATCH /accounts/{sub}` — partial update of per-user config.
/// Body: any subset of:
///   `{ "backupPrefs": { enabled, hour, minute, frequency,
///      notifyComplete, notifyFailed, notifyRestoreComplete },
///      "budgetPrefs": { autoMonthlyBudget: bool },
///      "timezone": "America/Chicago",
///      `filterRules: &lt;json-string&gt;, lastSyncAt: &lt;ms&gt;`
///
/// Used by:
///   - the client on every Backup screen save (backupPrefs + timezone)
///   - the client on every Email filters save (filterRules)
///   - the client after every successful sync (lastSyncAt)
///
/// The full record is read, modified in memory, and written back —
/// the read-modify-write keeps the handler simple and side-effect-
/// free. After the put, if `backupPrefs` was in the body the
/// [BackupScheduler] is invoked so the per-user systemd timer and
/// the `pocket_schedules` row both reflect the new state in
/// lock-step with the `accounts.backup_prefs` column.
///
/// Auth: Bearer apiToken. Same self-or-admin gate as GET.
Future<Response> Function(Request) accountsPatchHandler(
  ServerConfig config,
  TokenStore tokens,
  TokenAuth auth,
  BackupScheduler scheduler,
  BudgetsRepo budgets,
) {
  final log = Logger('accounts-patch');

  return (Request req) async {
    final sub = req.params['sub'];
    if (sub == null || sub.isEmpty) {
      return Response.badRequest(body: 'sub path param required');
    }
    final deny = await _authorizeSelfOrAdmin(
      config: config,
      tokens: tokens,
      auth: auth,
      req: req,
      targetSub: sub,
    );
    if (deny != null) return deny;

    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }

    final record = await tokens.get(sub);
    if (record == null) {
      return Response(404,
          body: jsonEncode({'error': 'no account for $sub'}),
          headers: {'content-type': 'application/json'});
    }

    BackupPrefs? nextPrefs;
    if (body.containsKey('backupPrefs')) {
      final bp = body['backupPrefs'];
      if (bp is! Map) {
        return Response.badRequest(body: 'backupPrefs must be an object');
      }
      nextPrefs = BackupPrefs.fromJson(bp.cast<String, dynamic>());
    }

    // BudgetPrefs is intentionally best-effort — no scheduler /
    // timer to reconcile the way backupPrefs has its
    // pocket-schedules row + systemd unit. The 1st-of-month cron
    // reads `budget_prefs->>'autoMonthlyBudget'` directly on every
    // run, and the sign-in path's ensureCurrentMonthBudget helper
    // reads the same value. So flipping this toggle from the device
    // doesn't need any deferred work — the next read sees the new
    // value.
    //
    // The one side-effect worth doing synchronously here: when the
    // toggle flips OFF → ON, run `ensureCurrentMonthBudget` so the
    // user gets a current-month budget row the same instant they
    // enabled the feature, instead of waiting for the next sign-in.
    // The result is folded into the response under
    // `activatedBudget`, and the Settings screen on the phone calls
    // the matching `BudgetHydrator.ensureCurrentMonth()` to mirror
    // it into local SQLite. Flipping ON → OFF is intentionally a
    // no-op against the budgets table — toggling OFF does not
    // delete or modify any existing rows; it only stops the
    // auto-mint side-effect from running again next month.
    BudgetPrefs? nextBudgetPrefs;
    bool autoBudgetTransitionedOn = false;
    if (body.containsKey('budgetPrefs')) {
      final bp = body['budgetPrefs'];
      if (bp is! Map) {
        return Response.badRequest(body: 'budgetPrefs must be an object');
      }
      nextBudgetPrefs =
          BudgetPrefs.fromJson(bp.cast<String, dynamic>());
      autoBudgetTransitionedOn =
          nextBudgetPrefs.autoMonthlyBudget && !record.budgetPrefs.autoMonthlyBudget;
    }

    String? nextTimezone;
    if (body.containsKey('timezone')) {
      final tz = body['timezone'];
      if (tz is! String) {
        return Response.badRequest(body: 'timezone must be a string');
      }
      if (tz.isEmpty) {
        // Empty string = treat as "clear", fall through to UTC.
        nextTimezone = null;
      } else {
        nextTimezone = tz;
      }
    }

    String? nextFilterRules;
    var clearFilterRules = false;
    if (body.containsKey('filterRules')) {
      final fr = body['filterRules'];
      if (fr == null) {
        clearFilterRules = true;
      } else if (fr is String) {
        nextFilterRules = fr;
      } else {
        return Response.badRequest(
            body: 'filterRules must be a JSON string or null');
      }
    }

    int? nextLastSyncAt;
    if (body.containsKey('lastSyncAt')) {
      final v = body['lastSyncAt'];
      if (v is! int) {
        return Response.badRequest(body: 'lastSyncAt must be int (ms)');
      }
      nextLastSyncAt = v;
    }

    final now = DateTime.now().toUtc();
    final updated = record.copyWith(
      backupPrefs: nextPrefs ?? record.backupPrefs,
      budgetPrefs: nextBudgetPrefs ?? record.budgetPrefs,
      timezone: nextTimezone ?? record.timezone,
      lastSyncAt: nextLastSyncAt == null
          ? record.lastSyncAt
          : DateTime.fromMillisecondsSinceEpoch(nextLastSyncAt),
      createdAt: record.createdAt ?? now,
      updatedAt: now,
    ).copyWithFilterRules(
      filterRules: nextFilterRules,
      clear: clearFilterRules,
    );

    await tokens.put(sub, updated);
    log.info('patched account $sub '
        '(backupPrefs=${nextPrefs != null}, '
        'budgetPrefs=${nextBudgetPrefs != null}, '
        'timezone=${nextTimezone != null}, '
        'filterRules=${body.containsKey('filterRules')}, '
        'lastSyncAt=${nextLastSyncAt != null})');

    // Reconcile the per-user systemd timer + pocket_schedules row
    // whenever backupPrefs was part of the payload. We pass the
    // *just-persisted* record so the scheduler sees the same view
    // Postgres does, and so a timezone that's only present on the
    // incoming body (e.g. first save) is picked up. The scheduler
    // is best-effort — a PATCH must not fail because systemctl
    // couldn't write a unit; logs record the drift and the next
    // sync (next save) re-attempts.
    if (nextPrefs != null) {
      try {
        await scheduler.sync(
          sub: sub,
          prefs: updated.backupPrefs,
          timezone: updated.timezone,
        );
      } catch (e) {
        log.warning('scheduler.sync($sub) failed: $e — DB row is source of '
            'truth, unit will be reconciled on next save');
      }
    }

    // Auto-monthly-budget flip-side-effect. See the comment above
    // on `autoBudgetTransitionedOn` for why this fires exactly on
    // OFF → ON: it's the only transition that creates something the
    // user asked for. We use the helper directly (not the
    // `/budgets/ensure-current` HTTP round-trip) so the response
    // shape stays a single PATCH reply and there's no second
    // network hop. Best-effort — failure is logged but the PATCH
    // still returns 200 with the unchanged record, so the toggle
    // save still succeeds; the user can retry by toggling and
    // saving again.
    Budget? activatedBudget;
    if (autoBudgetTransitionedOn) {
      try {
        final outcome = await ensureCurrentMonthBudget(
          sub: sub,
          prefs: updated.budgetPrefs,
          budgets: budgets,
        );
        if (outcome.result == EnsureResult.createdNow) {
          activatedBudget = outcome.budget;
          log.info('auto-create on toggle flip: '
              'sub=$sub, ${activatedBudget?.name}, '
              'active=${activatedBudget?.active}');
        } else if (outcome.result == EnsureResult.alreadyExisted) {
          log.info('auto-create on toggle flip: '
              'sub=$sub already has a current-month budget — '
              'no mint');
        }
        // userOptedOut unreachable: autoBudgetTransitionedOn requires
        // prefs.autoMonthlyBudget=true, so ensureCurrentMonthBudget
        // can't return userOptedOut here.
      } catch (e, st) {
        log.warning('auto-create on toggle flip failed for '
            'sub=$sub: $e\n$st — toggle save is still committed; '
            'user can retry by saving again');
      }
    }

    return Response.ok(
      jsonEncode({
        ..._encodeAccountRecord(updated),
        // Mirrored budget (if any) — the mobile Settings screen
        // inserts it into local SQLite so the active budget
        // shows up on the dashboard immediately, without waiting
        // for the next sign-in. Null on every other path.
        if (activatedBudget != null) 'activatedBudget': activatedBudget.toJson(),
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// Shared sub-mismatch / admin gate. Returns null on success or
/// the appropriate 403/404 response. Same shape as the helper in
/// `admin_backup_schedule.dart` but kept here to avoid a circular
/// import — the two handlers don't share callers today.
Future<Response?> _authorizeSelfOrAdmin({
  required ServerConfig config,
  required TokenStore tokens,
  required TokenAuth auth,
  required Request req,
  required String targetSub,
}) async {
  final log = Logger('accounts-auth');
  final bearer = req.headers['authorization'];
  if (bearer == null || !bearer.startsWith('Bearer ')) {
    return Response.forbidden('missing bearer');
  }
  final token = bearer.substring(7);
  Map<String, dynamic> claims;
  try {
    if (auth.looksLikeOidc(token)) {
      // OIDC not expected to hit these endpoints. The mobile client
      // uses HS256 apiToken; Pub/Sub OIDC pushes /pubsub/push. If
      // some future Google-managed job ever needs to PATCH an
      // account, it should target the right sub via the audience
      // check + an explicit service-account allowlist. Until then:
      // 403.
      return Response.forbidden('oidc not allowed on /accounts');
    }
    claims = auth.verifyApiToken(token);
  } on FormatException catch (e) {
    log.warning('token verify failed: ${e.message}');
    return Response.forbidden('bad token');
  } catch (e) {
    log.warning('token verify failed: $e');
    return Response.forbidden('auth error');
  }
  final sub = claims['sub'] as String?;
  if (sub == null) return Response.forbidden('invalid token');
  if (sub == targetSub) return null;
  if (!config.adminEnabled) return Response.forbidden('not allowed');
  final account = await tokens.get(sub);
  if (account == null || account.email != config.adminEmail) {
    return Response.forbidden('not allowed');
  }
  return null;
}

/// Wire shape: every field the client hydrates from a single GET.
/// Internal-only fields (refreshToken, fcmTokens) are NOT included
/// — those are server-side only and never leave the process.
Map<String, dynamic> _encodeAccountRecord(AccountRecord r) => {
      'sub': r.sub,
      'email': r.email,
      'backupPrefs': r.backupPrefs.toJson(),
      'budgetPrefs': r.budgetPrefs.toJson(),
      if (r.timezone != null) 'timezone': r.timezone,
      if (r.filterRules != null) 'filterRules': r.filterRules,
      'lastSyncAt': r.lastSyncAt?.millisecondsSinceEpoch,
      'lastBackupAt': r.lastBackupAt?.millisecondsSinceEpoch,
      'createdAt': r.createdAt?.millisecondsSinceEpoch,
      'updatedAt': r.updatedAt?.millisecondsSinceEpoch,
    };
