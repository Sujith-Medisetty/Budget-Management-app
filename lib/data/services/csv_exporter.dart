import 'package:csv/csv.dart';

import '../../core/format/time_format.dart';
import '../models/budget.dart';
import '../models/transaction.dart';

/// Pure CSV serialization for transactions and budgets. The output is
/// prefixed with a UTF-8 BOM so Excel opens it with the right encoding,
/// and a leading `#` comment row documents the sign convention for
/// transaction amounts.
class CsvExporter {
  CsvExporter._();

  static const _bom = '﻿';

  static String _dateFmt(DateTime t) => TimeFormat.csvDate(t);
  static String _timeFmt(DateTime t) => TimeFormat.csvTime(t);

  /// CSV for the given transactions.
  /// Columns: `date, time, amount, merchant, source, reason`.
  /// Convention: positive amount = spend, negative = refund.
  static String transactions(List<Transaction> txns) {
    final rows = <List<String>>[
      ['date', 'time', 'amount', 'merchant', 'source', 'reason'],
    ];
    for (final t in txns) {
      rows.add([
        _dateFmt(t.occurredAt),
        _timeFmt(t.occurredAt),
        t.amount.toStringAsFixed(2),
        t.merchant,
        t.source,
        t.reason ?? '',
      ]);
    }
    return _bom + _serializeWithComment(
      rows,
      comment: '# sign: positive=spend, negative=refund',
    );
  }

  /// CSV for the given budgets.
  static String budgets(List<Budget> list) {
    final rows = <List<String>>[
      [
        'name',
        'amount',
        'period',
        'start',
        'end',
        'alert_every',
        'alert_thresholds',
        'active',
        'created_at',
      ],
    ];
    for (final b in list) {
      rows.add([
        b.name,
        b.amount.toStringAsFixed(2),
        b.period.name,
        _dateFmt(b.startDate),
        _dateFmt(b.endDate),
        b.alertEvery.toString(),
        b.alertThresholds.join(','),
        b.active ? '1' : '0',
        b.createdAt.toIso8601String(),
      ]);
    }
    return _bom + _serialize(rows);
  }

  static final _csv = Csv();

  static String _serializeWithComment(
    List<List<String>> rows, {
    required String comment,
  }) {
    final body = _csv.encode(rows);
    return '$comment\n$body';
  }

  static String _serialize(List<List<String>> rows) => _csv.encode(rows);
}
