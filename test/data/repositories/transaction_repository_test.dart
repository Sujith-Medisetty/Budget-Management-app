import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/data/database/database_helper.dart';
import 'package:pocket/data/models/transaction.dart' as txn_model;
import 'package:pocket/data/repositories/transaction_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show sqfliteFfiInit, databaseFactory, databaseFactoryFfi;

txn_model.Transaction _t({
  String? key,
  String source = 'paypal',
  double amount = 10.0,
  String merchant = 'Coffee Shop',
  DateTime? at,
}) =>
    txn_model.Transaction(
      id: null,
      notificationKey: key ?? 'n-${DateTime.now().microsecondsSinceEpoch}-${merchant.hashCode}',
      source: source,
      amount: amount,
      merchant: merchant,
      reason: null,
      occurredAt: at ?? DateTime(2026, 9, 5, 12),
    );

void main() {
  late DatabaseHelper helper;
  late TransactionRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    helper = DatabaseHelper.test();
    // Touch the DB to ensure schema is created.
    await helper.database;
    repo = TransactionRepository(helper);
  });

  tearDown(() async {
    await helper.close();
  });

  test('insertManual assigns id and returns the row', () async {
    final t = _t(key: 'manual-1', merchant: 'Amazon');
    final inserted = await repo.insertManual(t);
    expect(inserted.id, isNotNull);
    expect(inserted.merchant, 'Amazon');
  });

  test('insertIfNew dedups by notification_key', () async {
    final first = await repo.insertIfNew(_t(key: 'paypal-1'));
    expect(first.inserted, isTrue);

    final second = await repo.insertIfNew(_t(key: 'paypal-1', merchant: 'Different Merchant'));
    expect(second.inserted, isFalse);
    expect(second.row.id, first.row.id);
    expect(second.row.merchant, first.row.merchant); // original merchant preserved
  });

  test('findByKey returns the inserted row', () async {
    final t = await repo.insertManual(_t(key: 'k1'));
    final found = await repo.findByKey('k1');
    expect(found, isNotNull);
    expect(found!.id, t.id);
  });

  test('findByKey returns null for missing key', () async {
    expect(await repo.findByKey('nope'), isNull);
  });

  test('recent returns rows newest first', () async {
    await repo.insertManual(_t(key: 'a', at: DateTime(2026, 9, 1)));
    await repo.insertManual(_t(key: 'b', at: DateTime(2026, 9, 5)));
    await repo.insertManual(_t(key: 'c', at: DateTime(2026, 9, 3)));

    final out = await repo.recent();
    expect(out.map((t) => t.notificationKey).toList(), ['b', 'c', 'a']);
  });

  test('inRange filters by occurred_at bounds', () async {
    await repo.insertManual(_t(key: 'a', at: DateTime(2026, 9, 1)));
    await repo.insertManual(_t(key: 'b', at: DateTime(2026, 9, 5)));
    await repo.insertManual(_t(key: 'c', at: DateTime(2026, 9, 10)));

    final out = await repo.inRange(
      DateTime(2026, 9, 3),
      DateTime(2026, 9, 7),
    );
    expect(out.map((t) => t.notificationKey).toList(), ['b']);
  });

  test('spentBetween sums positive amounts only (refunds excluded)', () async {
    await repo.insertManual(_t(key: 'a', amount: 10));
    await repo.insertManual(_t(key: 'b', amount: 25));
    await repo.insertManual(_t(key: 'c', amount: -5)); // refund — should not count

    final total = await repo.spentBetween(
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 30),
    );
    expect(total, 35.0);
  });

  test('update modifies the row in place', () async {
    final t = await repo.insertManual(_t(key: 'a', merchant: 'Old'));
    final updated = t.copyWith(merchant: 'New');
    await repo.update(updated);

    final fetched = await repo.findByKey('a');
    expect(fetched!.merchant, 'New');
  });

  test('update throws if transaction has no id', () async {
    final t = _t(key: 'a').copyWith(id: null);
    expect(() => repo.update(t), throwsArgumentError);
  });

  test('deleteById removes the row', () async {
    final t = await repo.insertManual(_t(key: 'a'));
    await repo.deleteById(t.id!);
    expect(await repo.findByKey('a'), isNull);
  });
}
