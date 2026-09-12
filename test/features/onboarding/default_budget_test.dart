import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/data/database/database_helper.dart';
import 'package:pocket/data/models/budget.dart';
import 'package:pocket/features/onboarding/default_budget.dart';
import 'package:pocket/providers/providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactory, databaseFactoryFfi;

void main() {
  late ProviderContainer container;
  late DatabaseHelper helper;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    helper = DatabaseHelper.test();
    await helper.database;
    container = ProviderContainer(
      overrides: [databaseHelperProvider.overrideWithValue(helper)],
    );
  });

  tearDown(() async {
    container.dispose();
    await helper.close();
  });

  group('defaultBudgetNameFor', () {
    test('returns "[Month] Expenses" using the month name', () {
      expect(defaultBudgetNameFor(DateTime(2026, 1, 15)), 'January Expenses');
      expect(defaultBudgetNameFor(DateTime(2026, 9, 5)), 'September Expenses');
      expect(defaultBudgetNameFor(DateTime(2026, 12, 31)), 'December Expenses');
    });
  });

  group('ensureDefaultBudget', () {
    test('inserts a monthly budget named "[Month] Expenses" at \$500', () async {
      final repo = container.read(budgetRepoProvider);
      final created = await ensureDefaultBudget(repo);
      expect(created, isNotNull);
      expect(created!.name, 'September Expenses');
      expect(created.amount, 500);
      expect(created.period, BudgetPeriod.monthly);
      expect(created.active, isTrue);
      expect(created.alertThresholds, [80, 100]);
      expect(created.alertEvery, isFalse);
    });

    test('the period range matches the current month boundaries', () async {
      final repo = container.read(budgetRepoProvider);
      final created = await ensureDefaultBudget(repo);
      expect(created, isNotNull);
      // Sept 2026: 1st → 30th (Sep has 30 days).
      expect(created!.startDate, DateTime(2026, 9, 1));
      expect(created.endDate, DateTime(2026, 9, 30));
    });

    test('is idempotent — second call returns null', () async {
      final repo = container.read(budgetRepoProvider);
      final first = await ensureDefaultBudget(repo);
      expect(first, isNotNull);
      final second = await ensureDefaultBudget(repo);
      expect(second, isNull);
    });

    test('respects existing budgets — does not insert when one already exists',
        () async {
      final repo = container.read(budgetRepoProvider);
      final now = DateTime(2026, 9, 5);
      await repo.insert(
        Budget(
          id: null,
          name: 'My pre-existing budget',
          amount: 100,
          period: BudgetPeriod.weekly,
          startDate: now,
          endDate: now.add(const Duration(days: 6)),
          alertEvery: false,
          alertThresholds: const [80, 100],
          active: true,
          createdAt: now,
        ),
      );
      final created = await ensureDefaultBudget(repo);
      expect(created, isNull);
      final all = await repo.all();
      expect(all, hasLength(1));
      expect(all.first.name, 'My pre-existing budget');
    });
  });
}