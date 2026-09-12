import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/data/database/database_helper.dart';
import 'package:pocket/data/models/budget.dart' as budget_model;
import 'package:pocket/data/repositories/budget_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactory, databaseFactoryFfi;

budget_model.Budget _b({
  String name = 'Food',
  double amount = 200,
  budget_model.BudgetPeriod period = budget_model.BudgetPeriod.weekly,
  bool active = true,
  bool alertEvery = false,
  List<int> thresholds = const [80, 100],
  DateTime? createdAt,
}) =>
    budget_model.Budget(
      id: null,
      name: name,
      amount: amount,
      period: period,
      startDate: DateTime(2026, 9, 1),
      endDate: DateTime(2026, 9, 7),
      alertEvery: alertEvery,
      alertThresholds: thresholds,
      active: active,
      createdAt: createdAt ?? DateTime(2026, 9, 1),
    );

void main() {
  late DatabaseHelper helper;
  late BudgetRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    helper = DatabaseHelper.test();
    await helper.database;
    repo = BudgetRepository(helper);
  });

  tearDown(() async {
    await helper.close();
  });

  test('insert assigns id and roundtrips', () async {
    final inserted = (await repo.insert(_b(name: 'Food')))!;
    expect(inserted.id, isNotNull);

    final all = await repo.all();
    expect(all, hasLength(1));
    expect(all.first.name, 'Food');
    expect(all.first.amount, 200.0);
  });

  test('all returns budgets in created_at order', () async {
    await repo.insert(_b(name: 'Older', createdAt: DateTime(2026, 1, 1)));
    await repo.insert(_b(name: 'Newer', createdAt: DateTime(2026, 6, 1)));
    final out = await repo.all();
    expect(out.map((b) => b.name).toList(), ['Older', 'Newer']);
  });

  test('firstActive returns the active budget', () async {
    await repo.insert(_b(name: 'Food', active: true));
    await repo.insert(_b(name: 'Travel', active: false));
    final active = await repo.firstActive();
    expect(active, isNotNull);
    expect(active!.name, 'Food');
  });

  test('firstActive returns null when no budget exists', () async {
    expect(await repo.firstActive(), isNull);
  });

  test('firstActive returns null when only inactive budgets exist', () async {
    await repo.insert(_b(name: 'Travel', active: false));
    expect(await repo.firstActive(), isNull);
  });

  test('activate deactivates others and activates target (single-active invariant)', () async {
    final a = (await repo.insert(_b(name: 'Food', active: true)))!;
    final b = (await repo.insert(_b(name: 'Travel', active: false)))!;

    await repo.activate(b);

    final active = await repo.firstActive();
    expect(active!.id, b.id);

    final all = await repo.all();
    final byId = {for (final x in all) x.id: x};
    expect(byId[a.id]!.active, isFalse);
    expect(byId[b.id]!.active, isTrue);
  });

  test('update modifies the row in place', () async {
    final b = (await repo.insert(_b(name: 'Food', amount: 200)))!;
    await repo.update(b.copyWith(amount: 350));
    final reloaded = (await repo.all()).first;
    expect(reloaded.amount, 350.0);
  });

  test('delete removes the row', () async {
    final b = (await repo.insert(_b(name: 'Food')))!;
    await repo.delete(b.id!);
    expect(await repo.all(), isEmpty);
  });

  test('deleteAndReactivateNext reactivates an alphabetical remaining budget', () async {
    final a = (await repo.insert(_b(name: 'Travel', active: true)))!;
    final b = (await repo.insert(_b(name: 'Food', active: false)))!;
    final c = (await repo.insert(_b(name: 'Misc', active: false)))!;

    final reactivated = await repo.deleteAndReactivateNext(a.id!);
    expect(reactivated, isNotNull);
    // Alphabetically: Food < Misc → Food becomes active.
    expect(reactivated!.id, b.id);

    final remaining = await repo.all();
    final byId = {for (final x in remaining) x.id: x};
    expect(byId[b.id]!.active, isTrue);
    expect(byId[c.id]!.active, isFalse);
  });

  test('deleteAndReactivateNext returns null when deleting an inactive budget', () async {
    final a = (await repo.insert(_b(name: 'Travel', active: false)))!;
    final result = await repo.deleteAndReactivateNext(a.id!);
    expect(result, isNull);
  });

  test('deleteAndReactivateNext returns null when table is empty after delete', () async {
    final a = (await repo.insert(_b(name: 'Food', active: true)))!;
    final result = await repo.deleteAndReactivateNext(a.id!);
    expect(result, isNull);
  });

  group('alert log', () {
    test('hasFiredAlert starts false, recordAlert makes it true', () async {
      final b = (await repo.insert(_b(name: 'Food')))!;
      expect(
        await repo.hasFiredAlert(
          budgetId: b.id!,
          threshold: 80,
          periodStart: DateTime(2026, 9, 1),
        ),
        isFalse,
      );

      await repo.recordAlert(
        budgetId: b.id!,
        threshold: 80,
        periodStart: DateTime(2026, 9, 1),
      );

      expect(
        await repo.hasFiredAlert(
          budgetId: b.id!,
          threshold: 80,
          periodStart: DateTime(2026, 9, 1),
        ),
        isTrue,
      );
    });

    test('recordAlert is idempotent on the same period + threshold', () async {
      final b = (await repo.insert(_b(name: 'Food')))!;
      await repo.recordAlert(budgetId: b.id!, threshold: 80, periodStart: DateTime(2026, 9, 1));
      await repo.recordAlert(budgetId: b.id!, threshold: 80, periodStart: DateTime(2026, 9, 1));
      // Composite PK means duplicate inserts are ignored; we should not crash.
    });

    test('different periods are tracked independently', () async {
      final b = (await repo.insert(_b(name: 'Food')))!;
      await repo.recordAlert(budgetId: b.id!, threshold: 80, periodStart: DateTime(2026, 9, 1));
      expect(
        await repo.hasFiredAlert(
          budgetId: b.id!,
          threshold: 80,
          periodStart: DateTime(2026, 9, 8),
        ),
        isFalse,
      );
    });
  });
}
