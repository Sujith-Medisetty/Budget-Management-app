import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';

import 'auth.dart';
import 'budget_rollover.dart';
import 'budgets_repo.dart';
import 'token_store.dart';

/// `GET /budgets` and `GET /budgets?month=YYYY-MM` — list the
/// budgets owned by the authenticated sub. With `month`, returns
/// only rows starting inside that calendar month; without it,
/// every row for the sub.
///
/// Auth: `Authorization: Bearer <apiToken>`. Sub comes from the
/// JWT claims — never the path. The mobile app is the only
/// caller today.
Future<Response> Function(Request) budgetsListHandler(
  TokenStore tokens,
  TokenAuth auth,
  BudgetsRepo budgets,
) {
  final log = Logger('budgets-list');
  return (Request req) async {
    final h = req.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) {
      return Response(401, body: 'missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(h.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) return Response(401, body: 'bad apiToken');
      sub = s;
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    } catch (e) {
      log.warning('token verify failed: $e');
      return Response.forbidden('auth error');
    }

    final monthParam = req.url.queryParameters['month'];
    List<Budget> rows;
    if (monthParam != null && monthParam.isNotEmpty) {
      final parsed = _parseMonth(monthParam);
      if (parsed == null) {
        return Response.badRequest(
            body: 'month must be YYYY-MM, got "$monthParam"');
      }
      rows = await budgets.listForSubInMonth(sub, parsed);
    } else {
      rows = await budgets.listForSub(sub);
    }
    return Response.ok(
      jsonEncode({
        'sub': sub,
        'budgets': rows.map((b) => b.toJson()).toList(growable: false),
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// `GET /budgets/ensure-current` — ensure the authenticated sub has
/// a budget row for the current calendar month. If they have
/// `autoMonthlyBudget=true` (the default) AND no row exists, mint
/// one with name like `"October Expenses"` and the previous auto
/// cap. Idempotent — calling it twice in a row produces exactly one
/// row.
///
/// Mobile calls this on sign-in / app open so brand-new mid-month
/// accounts get their "October Expenses" row immediately. The
/// 1st-of-month cron calls into the same helper (without going
/// through this endpoint) for everyone who hasn't signed in during
/// the rollover window.
///
/// Response shape:
///   `{ "sub": "...", "budget": &lt;Budget|null&gt;, "result":
///       "alreadyExisted" | "createdNow" | "userOptedOut" }`
///
/// The mobile app uses `result` to decide whether to show a toast
/// ("created your October budget") or stay silent. `userOptedOut`
/// means the user has the auto-create toggle off; no row was
/// minted and pre-existing rows (if any) are returned as-is.
Future<Response> Function(Request) budgetsEnsureCurrentHandler(
  TokenStore tokens,
  TokenAuth auth,
  BudgetsRepo budgets,
) {
  final log = Logger('budgets-ensure');
  return (Request req) async {
    final h = req.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) {
      return Response(401, body: 'missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(h.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) return Response(401, body: 'bad apiToken');
      sub = s;
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    } catch (e) {
      log.warning('token verify failed: $e');
      return Response.forbidden('auth error');
    }

    final account = await tokens.get(sub);
    if (account == null) {
      return Response.notFound('no account for $sub');
    }
    final outcome = await ensureCurrentMonthBudget(
      sub: sub,
      prefs: account.budgetPrefs,
      budgets: budgets,
    );
    return Response.ok(
      jsonEncode({
        'sub': sub,
        'budget': outcome.budget?.toJson(),
        'result': outcome.result.name,
      }),
      headers: {'content-type': 'application/json'},
    );
  };
}

/// Parses `YYYY-MM` into the 1st-of-that-month in UTC. Returns null
/// on malformed input — caller turns that into a 400.
DateTime? _parseMonth(String s) {
  final m = RegExp(r'^(\d{4})-(0[1-9]|1[0-2])$').firstMatch(s);
  if (m == null) return null;
  final y = int.parse(m.group(1)!);
  final mo = int.parse(m.group(2)!);
  return DateTime.utc(y, mo, 1);
}

/// `PATCH /budgets/match` — update alert prefs on the row identified
/// by `(sub, name, startDate)`. Body:
///
/// ```
/// {
///   "name":           "September Expenses",
///   "startDate":      "2026-09-01",
///   "alertEvery":     true,
///   "alertThresholds": "50,80,100,101"
/// }
/// ```
///
/// `alertEvery` and `alertThresholds` are required (the mobile always
/// sends both). The match is exact on `(name, start_date)` — same
/// key the hydrator uses — so the mobile doesn't need to track the
/// server's UUID `id` for a budget it created via the auto-create
/// path.
///
/// Auth: `Authorization: Bearer <apiToken>`. Sub comes from the JWT
/// claims, never the body.
///
/// Response:
///   - 200 with the updated [Budget] on success.
///   - 404 when no matching row exists for this sub (the budget is
///     locally-only on the phone — manual creation, never mirrored
///     to the server). The mobile treats 404 as a successful no-op
///     and moves on without surfacing an error.
///   - 400 on malformed body.
Future<Response> Function(Request) budgetsPatchMatchHandler(
  TokenStore tokens,
  TokenAuth auth,
  BudgetsRepo budgets,
) {
  final log = Logger('budgets-patch-match');
  return (Request req) async {
    final h = req.headers['authorization'];
    if (h == null || !h.startsWith('Bearer ')) {
      return Response(401, body: 'missing bearer');
    }
    String sub;
    try {
      final claims = auth.verifyApiToken(h.substring(7));
      final s = claims['sub'] as String?;
      if (s == null) return Response(401, body: 'bad apiToken');
      sub = s;
    } on FormatException {
      return Response(401, body: 'bad apiToken');
    } catch (e) {
      log.warning('token verify failed: $e');
      return Response.forbidden('auth error');
    }

    Map<String, dynamic> body;
    try {
      body = jsonDecode(await req.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return Response.badRequest(body: 'invalid json');
    }

    final name = body['name'] as String?;
    final startDateRaw = body['startDate'] as String?;
    final alertEvery = body['alertEvery'];
    final alertThresholds = body['alertThresholds'];
    if (name == null || name.isEmpty) {
      return Response.badRequest(body: 'name required');
    }
    if (startDateRaw == null || startDateRaw.isEmpty) {
      return Response.badRequest(body: 'startDate required (YYYY-MM-DD)');
    }
    if (alertEvery is! bool) {
      return Response.badRequest(body: 'alertEvery must be a bool');
    }
    if (alertThresholds is! String) {
      return Response.badRequest(
          body: 'alertThresholds must be a string (comma-separated)');
    }

    final startDate = DateTime.tryParse(startDateRaw);
    if (startDate == null) {
      return Response.badRequest(
          body: 'startDate must be YYYY-MM-DD, got "$startDateRaw"');
    }

    final updated = await budgets.updateAlertPrefs(
      sub: sub,
      name: name,
      startDate: startDate,
      alertEvery: alertEvery,
      alertThresholds: alertThresholds,
    );
    if (updated == null) {
      // Locally-only budget on the phone — the form screen treats
      // 404 as a successful no-op, so the response shape here is
      // identical to the 200 path minus the body. Logged so an
      // operator can see how often this fires (it should be the
      // majority of cases for users with `autoMonthlyBudget=false`).
      log.info('patch-match: no row for sub=$sub, '
          'name=$name, start=$startDateRaw — '
          'returning 404 (mobile treats as no-op)');
      return Response(404,
          body: jsonEncode({'error': 'no matching budget'}),
          headers: {'content-type': 'application/json'});
    }
    log.info('patch-match: updated sub=$sub, '
        'name=$name, alertEvery=$alertEvery');
    return Response.ok(
      jsonEncode(updated.toJson()),
      headers: {'content-type': 'application/json'},
    );
  };
}
