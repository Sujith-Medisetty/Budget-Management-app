import 'package:pocket_server/gmail_fetch.dart';
import 'package:test/test.dart';

/// Locks the RFC 2822 → UTC conversion in [parseEmailDate]. Without
/// this we'd silently lose hours when an email arrives with a
/// non-UTC offset (PayPal Pacific, Indian bank IST, etc.) because
/// Dart's stock `DateTime.tryParse` ignores the trailing `+HHMM`.
void main() {
  group('parseEmailDate', () {
    test('parses -0700 (US Pacific)', () {
      // Wall time 12:34 in California is 19:34 UTC.
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 2026 12:34:56 -0700');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 19, 34, 56));
    });

    test('parses +0530 (India)', () {
      // Wall time 12:34 in IST is 07:04 UTC.
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 2026 12:34:56 +0530');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 7, 4, 56));
    });

    test('parses +0000 (UK GMT literal)', () {
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 2026 12:34:56 +0000');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 12, 34, 56));
    });

    test('parses GMT literal', () {
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 2026 12:34:56 GMT');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 12, 34, 56));
    });

    test('parses two-digit year (RFC 2822 §4.3)', () {
      // 26 → 2026, with the same +0530 IST offset as above.
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 26 12:34:56 +0530');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 7, 4, 56));
    });

    test('parses 90 → 1990 (two-digit pivot, RFC 2822 §4.3)', () {
      // RFC 2822: 00-79 → 20xx, 80-99 → 19xx. So '90' is 1990.
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 90 12:00:00 -0700');
      expect(d.toUtc(), DateTime.utc(1990, 9, 5, 19, 0, 0));
    });

    test('parses 49 → 2049 (upper bound of 20xx window)', () {
      final d = parseEmailDate(headerValue: 'Sat, 5 Sep 49 12:00:00 -0700');
      expect(d.toUtc(), DateTime.utc(2049, 9, 5, 19, 0, 0));
    });

    test('accepts header without weekday', () {
      final d = parseEmailDate(headerValue: '5 Sep 2026 12:34:56 -0700');
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 19, 34, 56));
    });

    test('falls back to internalDate when header is unparseable', () {
      final epoch = DateTime.utc(2026, 9, 5, 12).millisecondsSinceEpoch;
      final d = parseEmailDate(
        headerValue: 'not a date',
        internalDateMs: epoch,
      );
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 12));
    });

    test('falls back to internalDate when header is missing', () {
      final epoch = DateTime.utc(2026, 9, 5, 12).millisecondsSinceEpoch;
      final d = parseEmailDate(internalDateMs: epoch);
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 12));
    });

    test('accepts internalDate as String (Gmail JSON int64 encoding)', () {
      // Gmail API returns `internalDate` as a JSON string, not an int,
      // because the value is int64 and JSON numbers lose precision past
      // 2^53. Old code did `body['internalDate'] as int?` and crashed.
      final epoch = DateTime.utc(2026, 9, 5, 12).millisecondsSinceEpoch;
      final d = parseEmailDate(internalDateMs: epoch.toString());
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 12));
    });

    test('unparseable internalDate falls through to now()', () {
      // Defensive: a malformed response shouldn't crash the whole push.
      final before = DateTime.now().toUtc();
      final d = parseEmailDate(internalDateMs: 'not a number');
      final after = DateTime.now().toUtc();
      expect(d.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(d.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('returns now when both header and internalDate are absent', () {
      final before = DateTime.now().toUtc();
      final d = parseEmailDate();
      final after = DateTime.now().toUtc();
      expect(d.isAfter(before.subtract(const Duration(seconds: 1))), isTrue);
      expect(d.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('prefers header over internalDate', () {
      // Header says Sep 5 2026, internalDate says 2020.
      // The header is the sender's "when the transaction happened" so
      // it wins.
      final d = parseEmailDate(
        headerValue: 'Sat, 5 Sep 2026 12:34:56 -0700',
        internalDateMs: DateTime.utc(2020, 1, 1).millisecondsSinceEpoch,
      );
      expect(d.toUtc(), DateTime.utc(2026, 9, 5, 19, 34, 56));
    });
  });
}
