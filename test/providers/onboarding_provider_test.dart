import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/providers/onboarding_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  test('starts false on a fresh install', () async {
    final completed = await container.read(onboardingCompletedProvider.future);
    expect(completed, isFalse);
  });

  test('starts true when previously marked complete', () async {
    SharedPreferences.setMockInitialValues({
      'pocket.onboarding_completed': true,
    });
    final fresh = ProviderContainer();
    addTearDown(fresh.dispose);
    final completed = await fresh.read(onboardingCompletedProvider.future);
    expect(completed, isTrue);
  });

  test('markOnboardingCompleted writes the flag and the provider reflects it after invalidate',
      () async {
    expect(
      await container.read(onboardingCompletedProvider.future),
      isFalse,
    );

    await markOnboardingCompleted();
    container.invalidate(onboardingCompletedProvider);

    expect(
      await container.read(onboardingCompletedProvider.future),
      isTrue,
    );
  });

  test('resetOnboardingCompleted clears the flag', () async {
    await markOnboardingCompleted();
    container.invalidate(onboardingCompletedProvider);
    expect(
      await container.read(onboardingCompletedProvider.future),
      isTrue,
    );

    await resetOnboardingCompleted();
    container.invalidate(onboardingCompletedProvider);

    expect(
      await container.read(onboardingCompletedProvider.future),
      isFalse,
    );
  });
}