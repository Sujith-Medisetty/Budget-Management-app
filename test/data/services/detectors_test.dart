import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/data/services/category_hints.dart';
import 'package:pocket/data/services/email_detector.dart';

void main() {
  group('isEmailApp', () {
    test('detects Gmail', () {
      expect(
        isEmailApp(
          packageName: 'com.google.android.gm',
          label: 'Gmail',
        ),
        isTrue,
      );
    });

    test('detects Outlook', () {
      expect(
        isEmailApp(
          packageName: 'com.microsoft.office.outlook',
          label: 'Outlook',
        ),
        isTrue,
      );
    });

    test('detects ProtonMail via packageName', () {
      expect(
        isEmailApp(
          packageName: 'ch.protonmail.android',
          label: 'Proton Mail',
        ),
        isTrue,
      );
    });

    test('detects Spark via label', () {
      expect(
        isEmailApp(
          packageName: 'com.readmail.spark',
          label: 'Spark Mail',
        ),
        isTrue,
      );
    });

    test('rejects generic "mail" apps that are not email (false positive guard)', () {
      // "Mail" alone is too generic — only matches if combined with a
      // brand or domain hint. A standalone "Mail" app should not match.
      expect(
        isEmailApp(
          packageName: 'com.example.mailer',
          label: 'Mailer',
        ),
        isFalse,
      );
    });

    test('rejects non-email apps', () {
      expect(
        isEmailApp(packageName: 'com.example.app', label: 'Calculator'),
        isFalse,
      );
    });

    test('rejects apps where the brand is a substring of a longer word', () {
      // "AOL" within a longer word like "AOLMusic" should not match —
      // the word-boundary rule prevents it.
      expect(
        isEmailApp(
          packageName: 'com.example.app',
          label: 'AOLMusic',
        ),
        isFalse,
      );
    });

    test('detects "Hey Mail" (with mail suffix)', () {
      // The hint is "hey " (with trailing space) so "Hey Mail" matches
      // via the label's trailing " Mail" word, not standalone "Hey".
      expect(
        isEmailApp(
          packageName: 'com.hey.android',
          label: 'Hey Mail',
        ),
        isTrue,
      );
    });
  });

  group('matchCategoryHint', () {
    test('matches PayPal as payment', () {
      expect(matchCategoryHint('PayPal'), 'payment');
    });

    test('matches Chase as banking', () {
      expect(matchCategoryHint('Chase Mobile'), 'banking');
    });

    test('matches BoA variant "Bank of America" as banking', () {
      expect(matchCategoryHint('Bank of America'), 'banking');
    });

    test('does NOT match "boa" alone (regression — too risky)', () {
      // "boa" was dropped from the hint list because it produced false
      // positives like "Gboard" containing "boa" as a substring. Users
      // who actually have BoA usually see "Bank of America" as the
      // display label; that one IS matched.
      expect(matchCategoryHint('BOA'), isNull);
    });

    test('does NOT match "Splitwise" as payment/wise', () {
      // Common false positive guard: "wise" was matching "Splitwise".
      // The keyword "wise" matches the brand "Wise" the money service,
      // but if it's part of a longer word it should not match.
      expect(matchCategoryHint('Splitwise'), isNull);
    });

    test('matches standalone "Wise" as payment', () {
      expect(matchCategoryHint('Wise'), 'payment');
    });

    test('matches Amazon as shopping', () {
      expect(matchCategoryHint('Amazon Shopping'), 'shopping');
    });

    test('matches Coinbase as finance', () {
      expect(matchCategoryHint('Coinbase'), 'finance');
    });

    test('does not match unrelated apps', () {
      expect(matchCategoryHint('Calculator'), isNull);
      expect(matchCategoryHint('Camera'), isNull);
      expect(matchCategoryHint('Settings'), isNull);
    });

    test('case-insensitive matching', () {
      expect(matchCategoryHint('PAYPAL'), 'payment');
      expect(matchCategoryHint('paypal'), 'payment');
    });

    test('handles multi-word brands', () {
      expect(matchCategoryHint('Google Pay'), 'payment');
      expect(matchCategoryHint('Google Wallet'), 'payment');
      expect(matchCategoryHint('Samsung Wallet'), 'payment');
    });
  });
}
