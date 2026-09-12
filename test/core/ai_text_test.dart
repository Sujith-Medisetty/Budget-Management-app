import 'package:flutter_test/flutter_test.dart';
import 'package:pocket/core/format/ai_text.dart';

void main() {
  group('stripThinkTags', () {
    test('removes <think> block (DeepSeek style)', () {
      const input =
          '<think>The user paid \$20 to Amazon. Let me categorize.</think>'
          '{"amount": 20, "merchant": "Amazon", "direction": "out", "skip": false}';
      expect(stripThinkTags(input), contains('"merchant": "Amazon"'));
      expect(stripThinkTags(input), isNot(contains('<think>')));
      expect(stripThinkTags(input), isNot(contains('</think>')));
      expect(stripThinkTags(input), isNot(contains('The user paid')));
    });

    test('removes <thinking> block', () {
      const input =
          '<thinking>scratchpad reasoning here\nwith multiple lines</thinking>'
          'Final answer: yes';
      final out = stripThinkTags(input);
      expect(out, equals('Final answer: yes'));
    });

    test('removes <reasoning> block (Anthropic style)', () {
      const input =
          '<reasoning>step 1: figure out direction\nstep 2: pick merchant</reasoning>'
          'It is a refund.';
      expect(stripThinkTags(input), equals('It is a refund.'));
    });

    test('removes <reflection> block', () {
      const input =
          '<reflection>I should be careful here.</reflection>\n\nHere is the answer.';
      expect(stripThinkTags(input), equals('Here is the answer.'));
    });

    test('case-insensitive', () {
      const input = '<THINKING>x</THINKING>answer';
      expect(stripThinkTags(input), equals('answer'));
    });

    test('multiple blocks all stripped', () {
      const input =
          '<thinking>first thought</thinking>middle<reasoning>second thought</reasoning>end';
      expect(stripThinkTags(input), equals('middleend'));
    });

    test('preserves text without think tags', () {
      const input = 'plain answer with no reasoning blocks';
      expect(stripThinkTags(input), equals('plain answer with no reasoning blocks'));
    });

    test('returns empty string unchanged', () {
      expect(stripThinkTags(''), equals(''));
    });

    test('collapses leftover blank-line runs', () {
      const input =
          '<thinking>thought</thinking>\n\n\n\n\nvisible text';
      final out = stripThinkTags(input);
      // 3+ consecutive newlines collapse to 2
      expect(out, equals('visible text'));
      expect(out.contains('\n\n\n'), isFalse);
    });

    test('preserves malformed JSON (unescaped braces) inside thinking', () {
      const input = '<thinking>{not json}</thinking>{"amount": 5}';
      expect(stripThinkTags(input), contains('"amount": 5'));
    });
  });
}
