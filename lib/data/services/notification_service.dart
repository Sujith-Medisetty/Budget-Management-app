import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/transaction.dart';

/// Rich budget alert payload — everything the renderer needs to draw
/// the expanded notification body and the inline progress indicator.
///
/// We pass structured fields instead of a pre-formatted string so the
/// notification layer owns formatting (so future tweaks don't require
/// changes in `BudgetAlerter`).
class BudgetAlertContent {
  const BudgetAlertContent({
    required this.budgetName,
    required this.recentExpenseMerchant,
    required this.recentExpenseAmount,
    required this.recentExpenseAt,
    required this.spent,
    required this.budgetAmount,
    required this.remaining,
    required this.perDayLeft,
    required this.percentUsed,
    required this.periodEnd,
  });

  final String budgetName;
  final String recentExpenseMerchant;
  final double recentExpenseAmount;
  final DateTime? recentExpenseAt;
  final double spent;
  final double budgetAmount;
  final double remaining;
  final double perDayLeft;
  final int percentUsed;
  final DateTime periodEnd;
}

/// Wraps flutter_local_notifications with the single channel Pocket uses:
/// budget alerts. Initialized once at app start.
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  static const _budgetChannelId = 'pocket_budget_alerts';
  static const _budgetChannelName = 'Budget alerts';
  static const _budgetChannelDesc =
      'Fired when a budget crosses 50%, 80%, or 100%.';

  // Separate channel so users can mute capture alerts without
  // silencing budget threshold pings (or vice versa).
  static const _captureChannelId = 'pocket_gmail_capture';
  static const _captureChannelName = 'Gmail captures';
  static const _captureChannelDesc =
      'Fired when Pocket parses a transaction from a Gmail push.';

  /// Android raw-resource name (without extension) for the custom
  /// budget chime — see `res/raw/budget_alert.mp3`. Three ascending
  /// bell-like notes (E5 → A5 → E6) generated via ffmpeg with each
  /// note carrying its fundamental plus 2 harmonics (octave + fifth)
  /// for a richer chime than a pure sine tone. ~1 second total —
  /// long enough to be heard over background noise, short enough not
  /// to feel sluggish when consecutive transactions fire. The
  /// capture channel stays silent on purpose: capture notifications
  /// fire on every Gmail push, and a chime per message would be
  /// exhausting. Budget alerts are infrequent and load-bearing.
  static const _budgetAlertSound = 'budget_alert';

  Future<void> init() async {
    if (_initialized) return;
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidInit);
      await _plugin.initialize(settings);

      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          _budgetChannelId,
          _budgetChannelName,
          description: _budgetChannelDesc,
          importance: Importance.high,
          playSound: true,
          // The channel binds the sound; per-notification sound attribute
          // is omitted so future platform-wide swaps take effect.
          sound: RawResourceAndroidNotificationSound(_budgetAlertSound),
        ),
      );
      await androidImpl?.createNotificationChannel(
        const AndroidNotificationChannel(
          _captureChannelId,
          _captureChannelName,
          description: _captureChannelDesc,
          // Default importance — capture notifications shouldn't pop up
          // over the user's foreground app as aggressively as a budget
          // threshold. They appear in the shade but won't heads-up.
          importance: Importance.defaultImportance,
          // Same bell chime as the budget channel — the user asked
          // for one unique "payment notification sound" on every
          // capture. With playSound: false earlier, capture notifications
          // were silent and the user thought the channel wasn't working.
          playSound: true,
          sound: RawResourceAndroidNotificationSound(_budgetAlertSound),
        ),
      );
      _initialized = true;
    } on Object catch (e) {
      // Background isolate has no Activity context — plugin calls can
      // throw before the platform binding is up. Mark initialized so
      // we don't retry on every show(); the show itself will also try
      // and fail silently via its own try/catch.
      debugPrint('[notifications] init failed: $e');
    }
  }

  /// Triggers the Android 13+ POST_NOTIFICATIONS prompt. Safe to call
  /// more than once — if the user has already granted or denied, the
  /// system no-ops. Used by the onboarding "Allow notifications" step
  /// even though `init()` has already run during app boot (otherwise
  /// that step would be a no-op and the user couldn't grant later).
  ///
  /// We swallow platform exceptions here because the underlying plugin
  /// call hits ContextCompat.checkSelfPermission(applicationContext),
  /// which throws if there's no Activity attached yet. That used to crash
  /// app boot when the launcher came up faster than MainActivity
  /// finished wiring up. The user can always re-grant via the
  /// onboarding step or system settings.
  Future<void> requestPermission() async {
    try {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
    } on Object catch (e) {
      debugPrint('[notifications] requestPermission failed: $e');
    }
  }

  /// Returns whether the app currently has POST_NOTIFICATIONS granted.
  /// On Android < 13 this is always `true` (the permission is implicit).
  Future<bool> areNotificationsEnabled() async {
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final value = await androidImpl?.areNotificationsEnabled();
    return value ?? true;
  }

  /// Fire the rich budget alert. [tone] controls the title copy:
  /// 'over' for >100%, 'full' for ~100%, 'milestone' for lower %.
  ///
  /// When [threshold] is non-null, the expanded body prepends a
  /// `Budget crossed X% threshold` header line — used by the
  /// threshold-crossed alerter path. Pass null for the always-on
  /// "every transaction" path.
  Future<void> showBudgetAlert({
    required BudgetAlertContent content,
    required String tone,
    int? threshold,
    int id = 0,
  }) async {
    await init();

    final title = _titleFor(content);
    final expandedBody = _formatBody(content, threshold: threshold);
    // Compact body line for the heads-up view. The full-width
    // progress bar (see `showProgress` below) carries the percent
    // visually, so the body text just needs to convey the WHY — on a
    // threshold alert we lead with "Budget crossed X% threshold" so
    // the user immediately knows why a notification surfaced. The
    // always-on path needs no body text at all because the title +
    // progress bar are self-explanatory.
    final compactBody = threshold != null
        ? 'Budget crossed $threshold% threshold'
        : null;

    final details = AndroidNotificationDetails(
      _budgetChannelId,
      _budgetChannelName,
      channelDescription: _budgetChannelDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.status,
      // showWhen + chronometer shows the elapsed budget-period clock.
      showWhen: true,
      // System horizontal progress bar at the bottom of the
      // notification. Spans the full notification width and tints
      // with the app's indigo (see `color` below). Replaces the
      // earlier Unicode-bar approach — that rendered as a thin
      // monochrome string inside the body text and didn't visually
      // read as "progress". The system bar is wide, full-width,
      // and clearly the same shape as a progress bar the user has
      // seen in WhatsApp / Telegram download notifications, so it
      // doesn't need any explanation.
      showProgress: true,
      maxProgress: 100,
      progress: content.percentUsed.clamp(0, 100),
      // Don't auto-cancel when tapped — user may want to read it
      // again. Visibility public so it shows on the lock screen.
      autoCancel: false,
      visibility: NotificationVisibility.public,
      // Indigo — colors the small icon AND tints the progress bar.
      color: const Color(0xFF4F46E5),
      // BigTextStyle for the expanded (pull-down) layout. The
      // 5-line block renders when the user expands the notification.
      styleInformation: BigTextStyleInformation(
        expandedBody,
        contentTitle: title,
        summaryText: _summaryForThreshold(content, threshold),
      ),
      // Group all Pocket budget alerts together so consecutive
      // transactions collapse into a single shade entry instead of
      // each one taking its own row.
      groupKey: _budgetGroupKey,
    );

    await _plugin.show(
      id,
      title,
      compactBody,
      NotificationDetails(android: details),
    );
  }

  static const _budgetGroupKey = 'com.limitless.pocket.budget_alerts';
  static const _captureGroupKey = 'com.limitless.pocket.gmail_captures';

  /// Fire-and-forget "we saved a transaction" notification. Fires
  /// from BOTH the foreground `onMessage` path and the background
  /// isolate (`_onBackgroundEntry`) so the user sees the capture
  /// regardless of app state. Caller is responsible for the
  /// areNotificationsEnabled() check if the user might have muted
  /// captures globally — we always attempt the show so callers
  /// don't have to know the platform state.
  Future<void> showTransactionCaptured({
    required String merchant,
    required double amount,
    required String source,
    String? emailFrom,
    String? subject,
    String? reason,
    DateTime? occurredAt,
    BudgetAlertContent? budgetContext,
    int id = 0,
  }) async {
    await init();
    final sourceLabel = Transaction.labelFor(source);
    final absAmount = amount.abs();

    // Title reads top-to-bottom as the user asked: merchant, amount,
    // then time. Time uses the device-local clock so a 4:53 PM
    // Eastern email renders as 4:53 PM Eastern regardless of where
    // the server's UTC moment points. The middle-dot (·) separator
    // sits at Unicode's vertical-center position so it visually pops
    // apart from the decimal point (.) in $5.99 — system notifications
    // can't selectively bold individual characters, so we lean on
    // each character's natural alignment. Earlier this used `<b>`
    // HTML tags to bold the separator, but those only render in the
    // EXPANDED view (BigTextStyleInformation's contentTitle), not in
    // the heads-up / collapsed view — which left a literal `<b>` in
    // the title on screen. Plain text works in both views.
    final localTime = occurredAt?.toLocal();
    final timeLabel = localTime != null ? _shortTime(localTime) : null;
    final title = timeLabel != null
        ? '$merchant · ${_money(absAmount)} · $timeLabel'
        : '$merchant · ${_money(absAmount)}';

    final hasBudget = budgetContext != null;

    // Compact body (heads-up view). The full-width system progress
    // bar (see showProgress below) carries the percent visually —
    // no text indicator needed in the body. For captures without
    // budget context, fall back to source · merchant so the user
    // still knows which channel fired.
    final compactBody = hasBudget ? null : '$sourceLabel · $merchant';

    // Expanded body (pull-down view): same 5-line layout as the
    // budget threshold alert so both notification types read
    // identically — budget name + spent / remaining / per-day in the
    // body, with the system progress bar at the bottom.
    final expanded = hasBudget
        ? _expandedCaptureWithBudget(
            merchant: merchant,
            amount: absAmount,
            sourceLabel: sourceLabel,
            occurredAt: localTime,
            context: budgetContext,
          )
        : _expandedCapture(
            amountLine: '${_money(absAmount)} · $merchant',
            occurredAt: localTime,
          );

    // Summary text on the right edge of the expanded view — show
    // the budget percent when we have one. That's the glance value
    // the user wants after every transaction.
    final summary = hasBudget
        ? '${budgetContext.percentUsed}% of budget'
        : _shortRelative(occurredAt ?? DateTime.now());

    final details = AndroidNotificationDetails(
      _captureChannelId,
      _captureChannelName,
      channelDescription: _captureChannelDesc,
      // High importance so the capture surfaces as a heads-up even
      // when the app isn't open — Gmail's own transaction alerts
      // do the same and users expect parity.
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      showWhen: true,
      // System horizontal progress bar at the bottom of the
      // notification — full notification width, tinted indigo via
      // `color` below. Replaces the earlier Unicode-bar approach.
      // Without a budget context, no progress to show — the field
      // would render as 0/0 which looks broken.
      showProgress: hasBudget,
      maxProgress: hasBudget ? 100 : 0,
      progress: hasBudget ? budgetContext.percentUsed.clamp(0, 100) : 0,
      // BigTextStyle for the expanded (pull-down) view.
      styleInformation: BigTextStyleInformation(
        expanded,
        contentTitle: title,
        summaryText: summary,
      ),
      // Persist in the shade until the user explicitly swipes it
      // away — every capture represents money the user spent, and
      // dismissing on tap meant the user could lose the heads-up
      // before realizing what just hit their budget.
      autoCancel: false,
      visibility: NotificationVisibility.public,
      // Indigo matches the budget alert so both notification types
      // feel like part of the same product. The `color` field also
      // tints the progress bar.
      color: const Color(0xFF4F46E5),
      groupKey: _captureGroupKey,
    );

    try {
      await _plugin.show(
        id,
        title,
        compactBody,
        NotificationDetails(android: details),
      );
    } on Object catch (e) {
      // Background isolate has no Activity context — plugin calls can
      // throw MissingPluginException or PlatformException. Swallow so a
      // notification failure never breaks the capture pipeline.
      debugPrint('[notifications] showTransactionCaptured failed: $e');
    }
  }

  String _expandedCaptureWithBudget({
    required String merchant,
    required double amount,
    required String sourceLabel,
    required DateTime? occurredAt,
    required BudgetAlertContent context,
  }) {
    // Five lines, in this order:
    //   1. budget name
    //   2. spent / budget used
    //   3. remaining (or over-budget) line
    //   4. per-day allowance line OR period-end marker
    // The percent-used is rendered as the system progress bar at
    // the bottom of the notification (showProgress above) and the
    // summary text on the right edge — duplicating it as the first
    // body line would be visual noise.
    // The merchant / amount / time live on the title row, so we
    // don't repeat them here. Subject + From + Reason are dropped —
    // the user said "the notification should be clean" and the email
    // headers are noise once the transaction is parsed.
    final lines = <String>[
      context.budgetName,
      '${_money(context.spent)} / ${_money(context.budgetAmount)} used',
      context.remaining > 0
          ? '${_money(context.remaining)} remaining'
          : '${_money(-context.remaining)} over budget',
      if (context.perDayLeft.isFinite && context.perDayLeft > 0)
        '${_money(context.perDayLeft)}/day until ${_shortDate(context.periodEnd)}'
      else
        'Budget window ends ${_shortDate(context.periodEnd)}',
    ];
    return lines.join('\n');
  }

  String _expandedCapture({
    required String amountLine,
    DateTime? occurredAt,
  }) {
    // No budget context — keep it short. Just the merchant /
    // amount (already on the title) and the local time so the
    // user can match it against their statement.
    final lines = <String>[amountLine];
    if (occurredAt != null) {
      lines.add(_shortDateTime(occurredAt.toLocal()));
    }
    return lines.join('\n');
  }

  String _shortRelative(DateTime t) {
    final delta = DateTime.now().difference(t);
    if (delta.inSeconds < 60) return 'Just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return _shortDate(t);
  }

  String _shortDateTime(DateTime d) => '${_shortDate(d)} ${_shortTime(d)}';

  /// 12-hour local time like "4:53 PM". Used in the notification
  /// title and expanded body. Always renders in the device's local
  /// timezone — caller is expected to pass a local DateTime (i.e.
  /// already via `.toLocal()`). Keeping the rule at the call site
  /// makes the formatting helper itself agnostic and reusable.
  String _shortTime(DateTime d) {
    final h = d.hour;
    final m = d.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'PM' : 'AM';
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:$m $period';
  }

  // Lightweight test helper used by the debug menu — keeps the legacy
  // simple "title + body" shape so we can verify the channel works
  // without constructing a full BudgetAlertContent.
  Future<void> showRaw({
    required String title,
    required String body,
    int id = 0,
  }) async {
    await init();
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        _budgetChannelId,
        _budgetChannelName,
        channelDescription: _budgetChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    await _plugin.show(id, title, body, details);
  }

  String _titleFor(BudgetAlertContent c) {
    // Title always reads "merchant · amount · time" — the trigger
    // transaction, not the budget name. The tone is encoded in the
    // body's first line (header on threshold crossings) so the heads-
    // up view stays the same regardless of how the alert fired.
    //
    // Plain text only — system notification titles do NOT render
    // HTML in the heads-up / collapsed view. Earlier this used
    // `<b>·</b>` to bold the field separator vs. the decimal point;
    // that worked in the expanded view but surfaced as a literal
    // `<b>` on the heads-up view. The middle-dot character (·) sits
    // at Unicode's vertical-center position, so it visually pops
    // apart from the decimal (.) without needing any styling.
    final localTime = c.recentExpenseAt?.toLocal();
    final timeLabel = localTime != null ? _shortTime(localTime) : null;
    final money = _money(c.recentExpenseAmount);
    if (timeLabel != null) {
      return '${c.recentExpenseMerchant} · $money · $timeLabel';
    }
    return '${c.recentExpenseMerchant} · $money';
  }

  String _summaryForThreshold(BudgetAlertContent c, int? threshold) {
    // Right-edge summary text on the expanded view. Always uses the
    // percent used so the glance value stays consistent across
    // always-on and threshold variants.
    return '${c.percentUsed}% used';
  }

  String _formatBody(BudgetAlertContent c, {int? threshold}) {
    // Same five-line shape as the capture notification so both
    // notification types look identical. When [threshold] is
    // non-null we prepend a "Budget crossed X% threshold" header
    // so the user can tell threshold alerts apart from always-on
    // pings at a glance. The percent-used is rendered as the
    // system progress bar at the bottom of the notification, not
    // as the first body line.
    final lines = <String>[
      if (threshold != null) 'Budget crossed $threshold% threshold',
      c.budgetName,
      '${_money(c.spent)} / ${_money(c.budgetAmount)} used',
      c.remaining > 0
          ? '${_money(c.remaining)} remaining'
          : '${_money(-c.remaining)} over budget',
      if (c.perDayLeft.isFinite && c.perDayLeft > 0)
        '${_money(c.perDayLeft)}/day until ${_shortDate(c.periodEnd)}'
      else
        'Budget window ends ${_shortDate(c.periodEnd)}',
    ];
    return lines.join('\n');
  }

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  String _shortDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}';
  }
}