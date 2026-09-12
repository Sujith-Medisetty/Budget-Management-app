import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kOnboardingCompletedKey = 'pocket.onboarding_completed';

/// Tracks whether the user has finished the first-launch onboarding.
///
/// Resolves to `true` once they tap "Done" on the final step — even if
/// they skipped every optional step. `false` (or unset) on first
/// install drives the gating widget in `main.dart` to show
/// `OnboardingScreen`.
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_kOnboardingCompletedKey) ?? false;
});

/// Marks onboarding complete in SharedPreferences. Callers should
/// invalidate [onboardingCompletedProvider] afterwards to trigger the
/// gate in `main.dart` to rebuild and show `MainShell`.
Future<void> markOnboardingCompleted() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_kOnboardingCompletedKey, true);
}

/// Resets the flag (debug / settings entry point — not wired to UI yet).
Future<void> resetOnboardingCompleted() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kOnboardingCompletedKey);
}