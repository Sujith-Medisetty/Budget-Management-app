import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/budget.dart';
import '../models/transaction.dart';
import '../repositories/ai_log_store.dart';
import '../repositories/budget_repository.dart';
import '../repositories/transaction_repository.dart';
import '../../providers/backup_provider.dart';
import 'ai_key_store.dart';
import 'gmail_auth.dart';
import 'gmail_filter_rules.dart';
import 'gmail_sync.dart';
import 'notification_service.dart';

/// Local data access for the AI agent. Everything here runs against the
/// local DB — no model calls. The agent service calls these to build a
/// snapshot, then sends the snapshot to the LLM as context. Numbers in
/// the visible answer always come from these helpers, never from the
/// model: the model only picks labels / chart kind / verbosity.
class AgentData {
  AgentData({
    required TransactionRepository txns,
    required BudgetRepository budgets,
    required SharedPreferences prefs,
    required AiKeyStore aiKeyStore,
    required FlutterSecureStorage secure,
    required GmailAuth gmailAuth,
    required GmailSync gmailSync,
    required FilterRuleStore filterStore,
    required BackupPreferences Function() readBackupPrefs,
  })  : _txns = txns,
        _budgets = budgets,
        _prefs = prefs,
        _aiKeyStore = aiKeyStore,
        _secure = secure,
        _gmailAuth = gmailAuth,
        _gmailSync = gmailSync,
        _filterStore = filterStore,
        _readBackupPrefs = readBackupPrefs;

  final TransactionRepository _txns;
  final BudgetRepository _budgets;
  final SharedPreferences _prefs;
  final AiKeyStore _aiKeyStore;
  final FlutterSecureStorage _secure;
  final GmailAuth _gmailAuth;
  final GmailSync _gmailSync;
  final FilterRuleStore _filterStore;
  final BackupPreferences Function() _readBackupPrefs;

  // Cache a rules snapshot so every AgentData call hits disk once per
  // build. The settings UI is the only writer; if it changes the rules
  // it invalidates this provider, which forces a rebuild.
  FilterRuleSet? _rulesCache;
  FilterRuleSet _readRules() => _rulesCache ??= _filterStore.read();

  /// How long a built snapshot stays valid before the next [snapshot]
  /// call forces a rebuild. The agent chat often fires several turns
  /// in a row inside the same "session" — user types a question, model
  /// answers, user asks a follow-up — and the underlying data almost
  /// never changes between those turns. Rebuilding the full snapshot
  /// on every call is wasteful on the bigger queries (active budget +
  /// budgets list + recent AI log + GCP infra). 30s covers a typical
  /// "look at three things in a row" burst and still bounds staleness.
  /// The agent service calls [invalidateSnapshotCache] right after any
  /// successful mutation so the next follow-up turn sees fresh state
  /// without waiting on TTL.
  static const _snapshotTtl = Duration(seconds: 30);

  /// Cached snapshot keyed by (rangeFrom, rangeTo). Null after a
  /// TTL elapse or after [invalidateSnapshotCache]. Different date
  /// range = different cache slot (the per-budget spent_this_period
  /// numbers depend on it).
  _SnapshotCache? _snapshotCache;

  /// Forces the next [snapshot] call to rebuild instead of returning
  /// the cached value. Call after any successful agent mutation —
  /// see [AgentService.invalidateSnapshotCache] for the caller path.
  void invalidateSnapshotCache() {
    _snapshotCache = null;
  }

  /// Current calendar month, midnight to 23:59:59.999.
  ({DateTime from, DateTime to}) currentMonthRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, 1);
    final end0 = DateTime(now.year, now.month + 1, 1);
    final end = end0.subtract(const Duration(milliseconds: 1));
    return (from: start, to: end);
  }

  /// Cheap keyword date-intent detector. Returns a window the user is
  /// probably asking about, or null when the message is generic and we
  /// should fall back to the calendar-month default.
  ///
  /// Supported:
  ///   "today" / "tdy"                  → today only
  ///   "yesterday"                      → yesterday only
  ///   "N days ago" / "N day ago"       → N days back (single day)
  ///   "last <weekday>" / "<weekday>"   → most recent past <weekday>
  ///   "this week" / "current week"     → Mon..Sun of the current week
  ///   "last week" / "previous week"    → previous Mon..Sun
  ///   "past N days" / "last N days"    → N days back through today
  ///   "this month" / "current month"   → current calendar month
  ///   "last month" / "previous month"  → previous calendar month
  ///   "in <month name>" / "<month name>" → that month in the current
  ///                                        year (or last year if it
  ///                                        hasn't happened yet)
  ///   "9/5" / "9-5" / "9/5/26"          → that month + day in current
  ///                                        year (or prior year if future)
  ({DateTime from, DateTime to, String label})? detectDateRange(String msg) {
    final m = msg.toLowerCase();
    final now = DateTime.now();
    DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);
    DateTime endOfDay(DateTime d) => DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

    if (RegExp(r'\btoday\b|\btdy\b').hasMatch(m)) {
      final d = startOfDay(now);
      return (from: d, to: endOfDay(now), label: 'today');
    }
    if (RegExp(r'\byesterday\b').hasMatch(m)) {
      final y = now.subtract(const Duration(days: 1));
      return (from: startOfDay(y), to: endOfDay(y), label: 'yesterday');
    }
    // "3 days ago" / "5 days back" / "a week ago" — single-day window.
    // "a week" = 7 days so the user can ask "show me a week ago".
    final nDaysAgo = RegExp(
      r'\b(\d+|a)\s+days?\s+(ago|back)\b|\ba\s+week\s+ago\b',
    ).firstMatch(m);
    if (nDaysAgo != null) {
      final raw = nDaysAgo.group(1);
      final n = (raw == 'a') ? 7 : int.tryParse(raw ?? '') ?? 0;
      if (n > 0 && n < 365) {
        final d = now.subtract(Duration(days: n));
        return (
          from: startOfDay(d),
          to: endOfDay(d),
          label: n == 1 ? 'yesterday' : '$n days ago',
        );
      }
    }
    // "past 7 days" / "last 7 days" — rolling window back from today.
    // Capped at 365 so a fat-fingered number doesn't surprise the
    // model with a multi-year range.
    final pastN = RegExp(
      r'\b(?:past|last|previous)\s+(\d+)\s+days?\b',
    ).firstMatch(m);
    if (pastN != null) {
      final n = int.tryParse(pastN.group(1) ?? '');
      if (n != null && n > 0 && n <= 365) {
        final from = startOfDay(now.subtract(Duration(days: n - 1)));
        return (
          from: from,
          to: endOfDay(now),
          label: 'last $n days',
        );
      }
    }
    // "last Friday" / "this past Tuesday" — most recent past occurrence
    // of the named weekday. Sunday = 7 in Dart's weekday numbering.
    const weekdays = <String, int>{
      'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4,
      'friday': 5, 'saturday': 6, 'sunday': 7,
    };
    for (final entry in weekdays.entries) {
      if (RegExp(
        '(?:last|this past|previous)\\s+${entry.key}\\b|\\bon\\s+${entry.key}\\b',
        caseSensitive: false,
      ).hasMatch(m)) {
        // Days to subtract: if today is Wed (3) and they said "Friday"
        // (5), Friday is 5-3=2 days ahead — fall back to last Friday,
        // which is 7-2 = 5 days back.
        var delta = entry.value - now.weekday;
        if (delta <= 0) delta += 7;
        if (delta == 7) delta = 0; // "Friday" said on Friday = today
        final target = now.subtract(Duration(days: delta));
        return (
          from: startOfDay(target),
          to: endOfDay(target),
          label: 'last ${entry.key}',
        );
      }
    }
    // Short dates "9/5" / "9-5" / "9/5/2026" / "9/5/26". Two-digit
    // years: 00-69 = 20xx, 70-99 = 19xx (Excel convention; matches
    // what most users mean).
    final shortDate = RegExp(
      r'\b(\d{1,2})[\/\-](\d{1,2})(?:[\/\-](\d{2}|\d{4}))?\b',
    ).firstMatch(m);
    if (shortDate != null) {
      final mm = int.tryParse(shortDate.group(1) ?? '');
      final dd = int.tryParse(shortDate.group(2) ?? '');
      var yy = now.year;
      final yRaw = shortDate.group(3);
      if (yRaw != null) {
        final yNum = int.tryParse(yRaw);
        if (yNum != null) {
          yy = yRaw.length == 2
              ? (yNum < 70 ? 2000 + yNum : 1900 + yNum)
              : yNum;
        }
      }
      if (mm != null && dd != null && mm >= 1 && mm <= 12 && dd >= 1 && dd <= 31) {
        final candidate = DateTime(yy, mm, dd);
        // Push to last year if the inferred date is still in the future.
        final adjusted = candidate.isAfter(now)
            ? DateTime(yy - 1, mm, dd)
            : candidate;
        return (
          from: startOfDay(adjusted),
          to: endOfDay(adjusted),
          label:
              '${adjusted.year}-${adjusted.month.toString().padLeft(2, '0')}-${adjusted.day.toString().padLeft(2, '0')}',
        );
      }
    }
    if (RegExp(r'\blast\s+week\b|\bprevious\s+week\b').hasMatch(m)) {
      final thisMon = now.subtract(Duration(days: now.weekday - 1));
      final lastMon = startOfDay(thisMon).subtract(const Duration(days: 7));
      final lastSun = lastMon.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
      return (from: lastMon, to: lastSun, label: 'last week');
    }
    if (RegExp(r'\bthis\s+week\b|\bcurrent\s+week\b').hasMatch(m)) {
      final mon = startOfDay(now.subtract(Duration(days: now.weekday - 1)));
      final sun = mon.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
      return (from: mon, to: sun, label: 'this week');
    }
    if (RegExp(r'\blast\s+month\b|\bprevious\s+month\b').hasMatch(m)) {
      final firstOfThis = DateTime(now.year, now.month, 1);
      final lastOfPrev = firstOfThis.subtract(const Duration(milliseconds: 1));
      final firstOfPrev = DateTime(lastOfPrev.year, lastOfPrev.month, 1);
      return (from: firstOfPrev, to: lastOfPrev, label: 'last month');
    }
    if (RegExp(r'\bthis\s+month\b|\bcurrent\s+month\b').hasMatch(m)) {
      final r = currentMonthRange();
      return (from: r.from, to: r.to, label: 'this month');
    }
    const months = {
      'january': 1, 'february': 2, 'march': 3, 'april': 4, 'may': 5,
      'june': 6, 'july': 7, 'august': 8, 'september': 9, 'october': 10,
      'november': 11, 'december': 12,
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'jun': 6, 'jul': 7,
      'aug': 8, 'sep': 9, 'sept': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    for (final entry in months.entries) {
      final re = RegExp(
        '\\bin\\s+${entry.key}\\b|\\bon\\s+${entry.key}\\b|\\b${entry.key}\\b',
        caseSensitive: false,
      );
      if (re.hasMatch(m)) {
        var year = now.year;
        final monthEnd = DateTime(year, entry.value + 1, 1)
            .subtract(const Duration(milliseconds: 1));
        // If the named month hasn't happened yet this year, fall back
        // to last year (e.g. user asks "in March" in April).
        if (entry.value > now.month) {
          year -= 1;
        }
        final monthStart = DateTime(year, entry.value, 1);
        return (
          from: monthStart,
          to: DateTime(year, entry.value + 1, 1)
              .subtract(const Duration(milliseconds: 1)),
          label: '${entry.key} $year',
        );
      }
    }
    return null;
  }

  /// Last [n] full weeks (Mon–Sun), oldest first. The current week is
  /// excluded so each bucket represents a *closed* period — easier for
  /// the model to reason about ("last 4 weeks" should be 4 complete
  /// numbers, not 4 weeks where one is half-finished).
  Future<List<({String label, DateTime from, DateTime to, double total})>>
  weeklyTotals({int weeks = 8}) async {
    final now = DateTime.now();
    final thisWeekStart = now.subtract(Duration(days: now.weekday - 1));
    final startOfThisWeekMidnight =
        DateTime(thisWeekStart.year, thisWeekStart.month, thisWeekStart.day);
    final out = <({String label, DateTime from, DateTime to, double total})>[];
    for (int i = weeks; i >= 1; i--) {
      final from = startOfThisWeekMidnight.subtract(Duration(days: 7 * i));
      final to = from.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));
      final total = await _txns.spentBetween(from, to);
      out.add((label: _weekLabel(from), from: from, to: to, total: total));
    }
    return out;
  }

  static String _weekLabel(DateTime d) {
    final m = d.month;
    final day = d.day;
    return '$m/$day';
  }

  /// Top-N merchants by spend in a window. Returns plain rows the
  /// table renderer can drop straight in.
  Future<List<List<String>>> topMerchantsTable({
    DateTime? from,
    DateTime? to,
    int limit = 10,
  }) async {
    final range = (from != null && to != null)
        ? (from: from, to: to)
        : currentMonthRange();
    final all = await _txns.inRange(range.from, range.to);
    final byMerchant = <String, double>{};
    for (final t in all) {
      if (t.amount <= 0) continue;
      byMerchant[t.merchant] = (byMerchant[t.merchant] ?? 0) + t.amount;
    }
    final sorted = byMerchant.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(limit)
        .map((e) => [e.key, e.value.toStringAsFixed(2)])
        .toList(growable: false);
  }

  /// Computes "spent in the current period" for [b]. Uses the budget's
  /// own [BudgetPeriod.range] so a weekly budget gets Mon..Sun, a
  /// monthly budget gets 1st..last day, and a custom budget uses its
  /// stored start..end.
  Future<double> spentForPeriod(Budget b) async {
    final r = b.period.range(
      DateTime.now(),
      customRange: (start: b.startDate, end: b.endDate),
    );
    return _txns.spentBetween(r.start, r.end);
  }

  /// Total transactions by source in [range]. Powers the "where do my
  /// transactions come from?" question.
  Future<Map<String, double>> spendBySource(DateTime from, DateTime to) async {
    final all = await _txns.inRange(from, to);
    final out = <String, double>{
      'gmail': 0,
      'paypal': 0,
      'google_pay': 0,
      'manual': 0,
    };
    for (final t in all) {
      if (t.amount <= 0) continue;
      out[t.source] = (out[t.source] ?? 0) + t.amount;
    }
    return out;
  }

  /// Compact JSON snapshot of the user's data, sent to the LLM as
  /// context. Keys are short and explicit so the model can refer to
  /// them in answers ("see summary.total_spent").
  ///
  /// [range], when supplied, overrides the default calendar-month window
  /// for the headline `month.*` numbers and the per-budget `spent_this_period`
  /// (which is recomputed against the override).
  ///
  /// Snapshots are cached for [_snapshotTtl] keyed on the date-range
  /// override — a chat burst of "show me this month → and last week →
  /// and the breakdown" only pays for one full rebuild per unique
  /// range. The agent service bumps the cache after each mutation so
  /// the next follow-up turn sees fresh state without waiting on TTL.
  Future<Map<String, Object?>> snapshot({
    DateTime? rangeFrom,
    DateTime? rangeTo,
    String? rangeLabel,
  }) async {
    final month = currentMonthRange();
    final from = rangeFrom ?? month.from;
    final to = rangeTo ?? month.to;
    final label = rangeLabel ?? 'this month';

    final cacheKey = (from, to);
    final now = DateTime.now();
    final cached = _snapshotCache;
    if (cached != null &&
        cached.rangeKey == cacheKey &&
        now.difference(cached.builtAt) < _snapshotTtl) {
      return cached.value;
    }

    final built = await _buildSnapshot(from: from, to: to, label: label);
    _snapshotCache = _SnapshotCache(
      rangeKey: cacheKey,
      builtAt: now,
      value: built,
    );
    return built;
  }

  /// Actual snapshot construction — called by [snapshot] after the
  /// TTL check passes. Public callers should always go through
  /// [snapshot] so the cache stays warm.
  Future<Map<String, Object?>> _buildSnapshot({
    required DateTime from,
    required DateTime to,
    required String label,
  }) async {
    final txns = await _txns.inRange(from, to);
    final activeBudget = await _budgets.firstActive();
    final budgets = await _budgets.all();
    final now = DateTime.now();
    // The `month` block in the snapshot always shows the calendar
    // month, NOT the user's date-range override — even when they ask
    // "last week", the model needs to know what month they're in for
    // the budget period math.
    final currentMonth = currentMonthRange();

    final spend = txns
        .where((t) => t.amount > 0)
        .fold<double>(0, (acc, t) => acc + t.amount);
    final refund = txns
        .where((t) => t.amount < 0)
        .fold<double>(0, (acc, t) => acc + t.amount.abs());

    final byMerchant = <String, double>{};
    for (final t in txns) {
      if (t.amount <= 0) continue;
      byMerchant[t.merchant] = (byMerchant[t.merchant] ?? 0) + t.amount;
    }
    final topMerchants = byMerchant.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top5 = topMerchants
        .take(5)
        .map((e) => {'merchant': e.key, 'total': double.parse(e.value.toStringAsFixed(2))})
        .toList(growable: false);

    // Per-budget spent_this_period — uses the budget's own period range.
    // Two numbers per budget: amount+period (always) and spent (always,
    // zero when the period is empty). Progress percentage is computed in
    // the model so it stays flexible.
    final budgetSummaries = <Map<String, Object?>>[];
    for (final b in budgets) {
      final r = b.period.range(now, customRange: (start: b.startDate, end: b.endDate));
      final spent = await _txns.spentBetween(r.start, r.end);
      final alerts = await _budgets.hasFiredAlert(
        budgetId: b.id ?? 0,
        threshold: 100,
        periodStart: r.start,
      );
      budgetSummaries.add({
        'id': b.id,
        'name': b.name,
        'amount': b.amount,
        'period': b.period.name,
        'start_date': b.startDate.toIso8601String().substring(0, 10),
        'end_date': b.endDate.toIso8601String().substring(0, 10),
        'active': b.active,
        'spent_this_period': double.parse(spent.toStringAsFixed(2)),
        'remaining': double.parse((b.amount - spent).clamp(0, double.infinity).toStringAsFixed(2)),
        'alert_every': b.alertEvery,
        'alert_thresholds': b.alertThresholds,
        'fired_100_alert_this_period': alerts && b.id != null,
      });
    }

    // Settings: provider/model/base URL existence (NEVER the key),
    // connected Gmail state, last sync ts, filter rule count.
    final cfg = await _aiKeyStore.read();
    final gmailEmail = await _gmailAuth.signedInEmail();
    final lastSyncMs = _prefs.getInt('gmail_last_sync_ms');
    final rules = _readRules();

    // Recent AI activity log — last 10 rows so the agent can answer
    // "why did you drop that notification yesterday?" without a second
    // round-trip.
    final recentLog = await AiLogStore.list();
    final recentLogOut = recentLog
        .take(10)
        .map((e) => {
              'ts': e.ts.toIso8601String(),
              'package': e.package,
              'decision': e.decision,
              'reason': e.reason,
              'parsed_merchant': e.parsedMerchant,
              'parsed_amount': e.parsedAmount,
              'parsed_source': e.parsedSource,
              // Truncate source_text aggressively — full text blows up
              // the prompt and the model doesn't need it for self-debug.
              'source_text_preview': _truncate(e.sourceText, 200),
            })
        .toList(growable: false);

    // Full activity log (capped at the store's maxRows) for the
    // `view_activity_log` / `delete_activity_log_entry` verbs. Each
    // row carries its db `id` so the agent can refer to entries by id
    // when proposing a delete.
    final fullLog = await AiLogStore.list();
    final fullLogOut = fullLog
        .map((e) => {
              'id': e.id,
              'ts': e.ts.toIso8601String(),
              'package': e.package,
              'decision': e.decision,
              'reason': e.reason,
              'parsed_merchant': e.parsedMerchant,
              'parsed_amount': e.parsedAmount,
              'parsed_source': e.parsedSource,
              'source_text_preview': _truncate(e.sourceText, 160),
            })
        .toList(growable: false);

    // Notification permission state — read directly so the model can
    // tell the user "you haven't granted notification permission yet"
    // without bouncing through the agent verb just to check.
    final notifEnabled = await NotificationService.instance
        .areNotificationsEnabled();

    // Backup preferences — auto-backup on/off, schedule (hour:minute
    // in device-local time, frequency), per-event notification
    // toggles, last upload timestamp. The agent verb that mutates
    // these (`update_backup_preferences`) takes the same shape, so
    // the model can diff "current" against the user's request and
    // emit only the fields that changed.
    final backup = _readBackupPrefs();

    // Source totals — answered in the snapshot because "am I getting
    // Gmail captures?" comes up often.
    final bySource = await spendBySource(from, to);

    // ----- Analytics pre-computation -----
    // Every analytic the agent is likely to be asked about is computed
    // here so the model can cite pre-computed numbers instead of
    // trying to re-derive them from `recent_transactions`. Saves a
    // class of mistakes (off-by-one averages, projected vs actual,
    // weekday vs weekend), and lets the system prompt say "cite the
    // field, don't recompute".

    // Active-budget pacing: days elapsed in the budget's own period,
    // remaining days, average daily burn, projected end-of-period.
    // Pulls from the budget's own period range so a weekly budget gets
    // day-of-week math against Mon..Sun rather than calendar month.
    final activeRange = activeBudget == null
        ? null
        : activeBudget.period.range(
            now,
            customRange: (
              start: activeBudget.startDate,
              end: activeBudget.endDate,
            ),
          );
    final activeSpentValue = activeBudget == null
        ? 0.0
        : (budgetSummaries.firstWhere(
            (m) => m['id'] == activeBudget.id,
            orElse: () => {'spent_this_period': 0.0},
          )['spent_this_period'] as num)
            .toDouble();
    final activeDaysInPeriod = activeRange == null
        ? 0
        : activeRange.end.difference(activeRange.start).inDays + 1;
    final startOfToday = DateTime(now.year, now.month, now.day);
    final activeElapsedDays = activeRange == null
        ? 0
        : startOfToday.difference(activeRange.start).inDays + 1;
    final activeElapsedDaysClamped =
        activeElapsedDays.clamp(1, activeDaysInPeriod.clamp(1, 1 << 30));
    final activeAvgDaily = activeSpentValue / activeElapsedDaysClamped;
    final activeProjected = activeAvgDaily * activeDaysInPeriod;
    final activePacingPct = (activeBudget != null && activeBudget.amount > 0)
        ? activeProjected / activeBudget.amount * 100
        : 0.0;

    // Biggest single transaction in the chosen range (this period).
    Transaction? biggest;
    for (final t in txns) {
      if (t.amount > 0 && (biggest == null || t.amount > biggest.amount)) {
        biggest = t;
      }
    }
    final biggestOut = biggest == null
        ? null
        : {
            'id': biggest.id,
            'amount': double.parse(biggest.amount.toStringAsFixed(2)),
            'merchant': biggest.merchant,
            'occurred_at': biggest.occurredAt.toIso8601String().substring(0, 10),
            'source': biggest.source,
          };

    // Top 25 merchants for "what did I spend at <merchant>" / "show me
    // every category" questions that go deeper than top 5.
    final top25Out = topMerchants
        .take(25)
        .map(
          (e) => {
            'merchant': e.key,
            'total': double.parse(e.value.toStringAsFixed(2)),
          },
        )
        .toList(growable: false);

    // Weekday vs weekend split — answers "do I spend more on weekends?"
    // without the model having to walk every transaction.
    double weekdaySpend = 0, weekendSpend = 0;
    int weekdayCount = 0, weekendCount = 0;
    for (final t in txns) {
      if (t.amount <= 0) continue;
      if (t.occurredAt.weekday <= 5) {
        weekdaySpend += t.amount;
        weekdayCount++;
      } else {
        weekendSpend += t.amount;
        weekendCount++;
      }
    }

    // Last 7 days sparkline — oldest first so the chart x-axis reads
    // left-to-right. Powers "show me the past week" / pacing charts.
    final last7 = <Map<String, Object?>>[];
    for (int i = 6; i >= 0; i--) {
      final day = startOfToday.subtract(Duration(days: i));
      final dayStart = day;
      final dayEnd = DateTime(
        day.year,
        day.month,
        day.day,
        23,
        59,
        59,
        999,
      );
      final total = await _txns.spentBetween(dayStart, dayEnd);
      last7.add({
        'date': day.toIso8601String().substring(0, 10),
        'total': double.parse(total.toStringAsFixed(2)),
      });
    }
    final last7Total = last7.fold<double>(0, (a, b) => a + (b['total'] as double));
    final last7AvgDaily = last7Total / 7;

    // Last calendar week (Mon..Sun) totals — common follow-up
    // ("what about last week?"). Computed once, served from the
    // snapshot instead of forcing a second DB read.
    final thisMonStart = startOfToday.subtract(Duration(days: now.weekday - 1));
    final lastMonStart = thisMonStart.subtract(const Duration(days: 7));
    final lastSunEnd = lastMonStart.add(
      const Duration(days: 6, hours: 23, minutes: 59, seconds: 999),
    );
    final lastWeekTxns = await _txns.inRange(lastMonStart, lastSunEnd);
    final lastWeekSpend = lastWeekTxns
        .where((t) => t.amount > 0)
        .fold<double>(0, (a, t) => a + t.amount);
    final lastWeekRefund = lastWeekTxns
        .where((t) => t.amount < 0)
        .fold<double>(0, (a, t) => a + t.amount.abs());

    // Days-in-period math for the calendar month — used when the user
    // asks "avg daily spend this month". Inclusive of both endpoints.
    final currentMonthDays = currentMonth.to.difference(currentMonth.from).inDays + 1;
    final currentMonthDaysElapsed = startOfToday.difference(currentMonth.from).inDays + 1;
    final currentMonthDaysRemaining =
        (currentMonthDays - currentMonthDaysElapsed).clamp(0, currentMonthDays);
    final currentMonthAvgDaily = spend / currentMonthDaysElapsed.clamp(1, currentMonthDays);
    final currentMonthProjected = currentMonthAvgDaily * currentMonthDays;

    return {
      'as_of': now.toIso8601String(),
      'range': {
        'label': label,
        'from': from.toIso8601String().substring(0, 10),
        'to': to.toIso8601String().substring(0, 10),
      },
      'month': {
        'from': currentMonth.from.toIso8601String().substring(0, 10),
        'to': currentMonth.to.toIso8601String().substring(0, 10),
        'total_spent': double.parse(spend.toStringAsFixed(2)),
        'total_refunded': double.parse(refund.toStringAsFixed(2)),
        'transaction_count': txns.length,
        'top_merchants': top5,
        'top_merchants_full': top25Out,
        'spend_by_source': bySource.map(
          (k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2))),
        ),
      },
      'active_budget': activeBudget == null
          ? null
          : {
              'id': activeBudget.id,
              'name': activeBudget.name,
              'amount': activeBudget.amount,
              'period': activeBudget.period.name,
              'spent_this_period': double.parse(activeSpentValue.toStringAsFixed(2)),
              'remaining': double.parse(
                (activeBudget.amount - activeSpentValue)
                    .clamp(0, double.infinity)
                    .toStringAsFixed(2),
              ),
              'period_start': activeRange?.start.toIso8601String().substring(0, 10),
              'period_end': activeRange?.end.toIso8601String().substring(0, 10),
              'days_in_period': activeDaysInPeriod,
              'days_elapsed_in_period': activeElapsedDaysClamped,
              'days_remaining_in_period':
                  (activeDaysInPeriod - activeElapsedDaysClamped).clamp(0, activeDaysInPeriod),
              'avg_daily_spend_period':
                  double.parse(activeAvgDaily.toStringAsFixed(2)),
              'projected_spend_at_period_end':
                  double.parse(activeProjected.toStringAsFixed(2)),
              'pacing_pct': double.parse(activePacingPct.toStringAsFixed(1)),
            },
      'budgets': budgetSummaries,
      // All pre-computed analytics live here. See the "ANALYTICS"
      // section of the agent system prompt for the field-to-question
      // mapping — every field here was added to ground one
      // recurring question so the model stops inventing numbers.
      'analytics': {
        'biggest_single_transaction': biggestOut,
        'last_7_days_totals': last7,
        'last_7_days_total': double.parse(last7Total.toStringAsFixed(2)),
        'last_7_days_avg_daily': double.parse(last7AvgDaily.toStringAsFixed(2)),
        'weekday_weekend_split': {
          'weekday_spend': double.parse(weekdaySpend.toStringAsFixed(2)),
          'weekday_count': weekdayCount,
          'weekend_spend': double.parse(weekendSpend.toStringAsFixed(2)),
          'weekend_count': weekendCount,
        },
        'current_month': {
          'days_in_period': currentMonthDays,
          'days_elapsed': currentMonthDaysElapsed,
          'days_remaining': currentMonthDaysRemaining,
          'avg_daily_spend': double.parse(currentMonthAvgDaily.toStringAsFixed(2)),
          'projected_total_at_month_end':
              double.parse(currentMonthProjected.toStringAsFixed(2)),
        },
      },
      // Common follow-up windows, pre-computed so the model doesn't
      // have to ask "what window did you mean" when the user says
      // "what about last week?".
      'periods': {
        'last_week': {
          'from': lastMonStart.toIso8601String().substring(0, 10),
          'to': lastSunEnd.toIso8601String().substring(0, 10),
          'total_spent': double.parse(lastWeekSpend.toStringAsFixed(2)),
          'total_refunded': double.parse(lastWeekRefund.toStringAsFixed(2)),
          'transaction_count': lastWeekTxns.length,
        },
      },
      'recent_transactions': txns
          .take(15)
          .map((t) => {
                'id': t.id,
                'amount': t.amount,
                'merchant': t.merchant,
                'source': t.source,
                'occurred_at': t.occurredAt.toIso8601String(),
                'reason': t.reason,
              })
          .toList(growable: false),
      'recent_ai_log': recentLogOut,
      'activity_log_full': fullLogOut,
      'settings': {
        'ai_provider': cfg.provider.name,
        'ai_model': cfg.model,
        'has_base_url': cfg.baseUrl != null,
        'has_api_key': cfg.hasKey,
        'gmail_connected': gmailEmail != null,
        'gmail_account_email': gmailEmail,
        'gmail_last_sync_iso': lastSyncMs == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(lastSyncMs)
                .toIso8601String(),
        'notif_permission_granted': notifEnabled,
        'backup': {
          'enabled': backup.enabled,
          'hour': backup.hour,
          'minute': backup.minute,
          'frequency': backup.frequency.name,
          'notify_on_backup_complete': backup.notifyOnBackupComplete,
          'notify_on_backup_failed': backup.notifyOnBackupFailed,
          'notify_on_restore_complete': backup.notifyOnRestoreComplete,
          'last_upload_iso': backup.lastUploadAt?.toIso8601String(),
        },
      },
      'filter_rules': {
        'enabled': rules.enabled,
        'logic': rules.logic.name,
        'count': rules.rules.length,
        'rules': rules.rules
            .map((r) => {
                  if (r.sender != null)
                    'sender': {'value': r.sender!.value, 'match': r.sender!.matchType.name},
                  if (r.subject != null)
                    'subject': {'value': r.subject!.value, 'match': r.subject!.matchType.name},
                  if (r.body != null)
                    'body': {'value': r.body!.value, 'match': r.body!.matchType.name},
                })
            .toList(growable: false),
      },
    };
  }

  /// Pretty-printed snapshot — used in the empty-state and for the
  /// user to see what context the agent has access to.
  Future<String> snapshotAsString() async {
    final s = await snapshot();
    return const JsonEncoder.withIndent('  ').convert(s);
  }
}

/// One cached snapshot entry. The key is the (from, to) date range so
/// two chat turns asking about different windows don't collide — the
/// per-budget spent_this_period numbers depend on the range. The
/// builtAt stamp drives the TTL check.
class _SnapshotCache {
  _SnapshotCache({
    required this.rangeKey,
    required this.builtAt,
    required this.value,
  });
  final (DateTime, DateTime) rangeKey;
  final DateTime builtAt;
  final Map<String, Object?> value;
}

/// Helper to extract a JSON object from a string the model returned.
Map<String, Object?>? extractJson(String body) {
  final trimmed = body.trim();
  try {
    return jsonDecode(trimmed) as Map<String, Object?>;
  } catch (_) {}
  final fence = RegExp(r'```(?:json)?\s*(\{[\s\S]*?\})\s*```');
  final m = fence.firstMatch(trimmed);
  if (m != null) {
    try {
      return jsonDecode(m.group(1)!) as Map<String, Object?>;
    } catch (_) {}
  }
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start >= 0 && end > start) {
    try {
      return jsonDecode(trimmed.substring(start, end + 1))
          as Map<String, Object?>;
    } catch (_) {}
  }
  return null;
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
