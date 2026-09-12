import 'package:intl/intl.dart';

/// Centralized time/date formatting for every user-facing timestamp in
/// Pocket. Two rules drive every helper here:
///
///   1. **Always local.** Callers pass a UTC `DateTime` (the way they
///      arrive from SQLite / server) and the helper runs `.toLocal()`
///      for them. No more "my server timestamp looks like 3am" — the
///      user sees the time in their device's timezone.
///
///   2. **Always 12-hour for time-of-day.** `4:53 PM`, never `16:53`.
///      This matches the home-region default (US) and the agent card
///      copy. Dates stay ISO-friendly (`Mar 5`, `Mar 5, 2026`).
///
/// Why a single module instead of inline `DateFormat.jm()` calls: the
/// app had 8+ ad-hoc formatters across screens and exports, some 12h
/// some 24h, none consistently local. Funneling through this file
/// makes "all timestamps in the app" a single grep target and lets us
/// flip the locale later by editing one place.
class TimeFormat {
  TimeFormat._();

  static final DateFormat _shortTime = DateFormat('h:mm a');      // 4:53 PM
  static final DateFormat _shortDate = DateFormat('MMM d');       // Mar 5
  static final DateFormat _shortDateYear = DateFormat('MMM d, yyyy'); // Mar 5, 2026
  static final DateFormat _dateWithDay = DateFormat('EEE, MMM d'); // Thu, Mar 5
  static final DateFormat _dateTime = DateFormat('MMM d  h:mm a'); // Mar 5  4:53 PM
  static final DateFormat _fileStamp = DateFormat('yyyyMMdd-HHmma'); // 20260305-0453PM
  static final DateFormat _csvDate = DateFormat('yyyy-MM-dd');
  static final DateFormat _csvTime = DateFormat('h:mm a');         // 4:53 PM

  /// 12-hour local time, e.g. "4:53 PM". Pass any DateTime — UTC or
  /// already-local, the helper normalizes.
  static String shortTime(DateTime t) => _shortTime.format(t.toLocal());

  /// Short date with no year, e.g. "Mar 5". Local.
  static String shortDate(DateTime t) => _shortDate.format(t.toLocal());

  /// Short date with year, e.g. "Mar 5, 2026". Local.
  static String shortDateYear(DateTime t) =>
      _shortDateYear.format(t.toLocal());

  /// "Thu, Mar 5". Local. Used for transaction-day headers.
  static String dateWithDay(DateTime t) => _dateWithDay.format(t.toLocal());

  /// "Mar 5  4:53 PM" — combined date + time. Local.
  static String dateTime(DateTime t) => _dateTime.format(t.toLocal());

  /// "yyyy-MM-dd" — for CSV date columns and filename dates. Local.
  static String csvDate(DateTime t) => _csvDate.format(t.toLocal());

  /// 12-hour "h:mm a" — for CSV time columns. Local.
  static String csvTime(DateTime t) => _csvTime.format(t.toLocal());

  /// Filename-safe stamp from a moment in the local timezone, e.g.
  /// "20260305-0453PM". Used by CSV / share exports.
  static String fileStamp(DateTime t) => _fileStamp.format(t.toLocal());

  /// Compact relative phrase like "5m ago" / "3h ago" / "2d ago".
  /// After 7 days, falls back to a short ISO date so the user still
  /// gets a concrete reference instead of "47d ago".
  static String relative(DateTime t) {
    final local = t.toLocal();
    final delta = DateTime.now().difference(local);
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return _shortDate.format(local);
  }
}
