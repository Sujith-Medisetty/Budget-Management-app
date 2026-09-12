/// Build-time configuration for the Pocket backend. Defaults to the
/// Oracle VM deployment so a vanilla `flutter build apk` works out of
/// the box. Override at compile with:
///
///   flutter run --dart-define=SERVER_URL=https://staging-xxx.example
///
/// only when you need a non-prod endpoint (local emulator, staging,
/// etc).
///
/// If the VM URL ever changes, update the `defaultValue` here and
/// rebuild — no `--dart-define` needed for the user's device.
const String kServerUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'https://pocket.karmacode.online',
);