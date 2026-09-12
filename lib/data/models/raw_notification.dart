/// One notification we received from the OS via the Android
/// NotificationListenerService. Holds the raw fields — parsing happens
/// downstream so the same model can be persisted, logged, or re-parsed.
class RawNotification {
  RawNotification({
    required this.notificationKey,
    required this.packageName,
    required this.title,
    required this.text,
    required this.postedAt,
  });

  final String notificationKey;
  final String packageName;
  final String title;
  final String text;
  final DateTime postedAt;
}