import 'package:flutter_timezone/flutter_timezone.dart';

/// Returns the device's IANA timezone name (e.g. `America/Chicago`,
/// `Asia/Kolkata`). Backed by the `flutter_timezone` plugin which
/// wraps the platform-specific TZ lookup (Java `TimeZone.getDefault()
/// .getID()` on Android, `[NSTimeZone localTimeZone].name` on iOS).
///
/// Used by `BackupPreferencesController.save()` to attach the
/// timezone to every PATCH so the server can convert the user's
/// local HH:MM to UTC for the per-user systemd timer. Without this
/// the server has to guess — and a user who travels (CST → PST)
/// would otherwise keep firing at the wrong wall-clock hour until
/// they next opened the Backup screen.
///
/// Failures fall back to `UTC` rather than throwing — `flutter_timezone`
/// has been known to misbehave on rooted Android where the system
/// property is empty. The server treats `UTC` as the safe default,
/// so a wrong device value at worst fires one timer at the wrong
/// hour, not a crash.
class TimezoneService {
  const TimezoneService();

  /// Synchronous-feeling future — the plugin itself is async on most
  /// platforms but returns in single-digit ms in practice. We await
  /// it inside save() where the latency budget is fine.
  Future<String> getLocalIanaName() async {
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      final id = info.identifier;
      if (id.isEmpty) return 'UTC';
      return id;
    } catch (_) {
      return 'UTC';
    }
  }
}
