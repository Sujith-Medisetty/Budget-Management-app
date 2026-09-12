import 'dart:convert';

import 'package:pocket_server/mime.dart';
import 'package:test/test.dart';

void main() {
  const mime = MimeExtractor();

  String b64(String s) => base64Url.encode(utf8.encode(s));

  test('extracts text/plain from a single-part payload', () {
    final payload = {
      'mimeType': 'text/plain',
      'body': {'data': b64('You spent \$4.50 at Starbucks.')},
    };
    expect(mime.extractPlainText(payload), 'You spent \$4.50 at Starbucks.');
  });

  test('walks a multipart/alternative and prefers text/plain', () {
    final payload = {
      'mimeType': 'multipart/alternative',
      'parts': [
        {
          'mimeType': 'text/plain',
          'body': {'data': b64('Amazon: \$29.99 charged')},
        },
        {
          'mimeType': 'text/html',
          'body': {'data': b64('<p>Amazon: <b>\$29.99</b> charged</p>')},
        },
      ],
    };
    expect(mime.extractPlainText(payload), 'Amazon: \$29.99 charged');
  });

  test('falls back to stripped text/html when no text/plain present', () {
    final payload = {
      'mimeType': 'multipart/alternative',
      'parts': [
        {
          'mimeType': 'text/html',
          'body': {
            'data': b64('<div>Chase&nbsp;&amp; Co: <b>\$120.00</b> debit</div>'),
          },
        },
      ],
    };
    expect(mime.extractPlainText(payload), 'Chase & Co: \$120.00 debit');
  });

  test('returns empty string when payload has no useful body', () {
    final payload = {
      'mimeType': 'multipart/alternative',
      'parts': [
        {'mimeType': 'text/html', 'body': {'data': ''}},
      ],
    };
    expect(mime.extractPlainText(payload), '');
  });
}
