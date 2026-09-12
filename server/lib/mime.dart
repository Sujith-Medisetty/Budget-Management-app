import 'dart:convert';
import 'dart:typed_data';

/// Plain-text body extractor for Gmail API payloads (`format=full`).
///
/// The Gmail payload is a recursive `MessagePart` tree where leaf
/// parts have a `body.data` field of base64url-encoded bytes and
/// `mimeType` like `text/plain` or `text/html`. We walk the tree,
/// prefer `text/plain`, and fall back to a stripped `text/html`.
class MimeExtractor {
  const MimeExtractor();

  /// Returns the best plain-text representation of [payload]. Falls
  /// back to an empty string when nothing usable is found. Body data
  /// is decoded from base64url per RFC 2045 + Gmail's URL-safe variant.
  String extractPlainText(Map<String, dynamic> payload) {
    final buf = StringBuffer();
    _walk(payload, buf);
    return _trim(buf.toString());
  }

  void _walk(Map<String, dynamic> part, StringBuffer out) {
    final plain = _findFirst(part, 'text/plain');
    if (plain != null) {
      final text = _decodeBody(plain);
      if (text != null) out.write(text);
      return;
    }

    final html = _findFirst(part, 'text/html');
    if (html != null) {
      final text = _decodeBody(html);
      if (text != null) out.write(_stripHtml(text));
    }
  }

  Map<String, dynamic>? _findFirst(
    Map<String, dynamic> part,
    String targetMime,
  ) {
    final mimeType = part['mimeType'] as String? ?? '';
    final body = part['body'] as Map<String, dynamic>?;
    if (mimeType == targetMime && body != null && body['data'] is String) {
      return body;
    }
    final parts = part['parts'] as List?;
    if (parts == null) return null;
    for (final child in parts) {
      if (child is Map<String, dynamic>) {
        final hit = _findFirst(child, targetMime);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  String? _decodeBody(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is! String || data.isEmpty) return null;
    try {
      return utf8.decode(_base64UrlDecode(data));
    } on FormatException {
      return null;
    }
  }

  /// Strips tags + decodes the handful of HTML entities that show up
  /// in transaction emails (e.g. `&amp;`, `&#36;`). Good enough for
  /// rule_parser + AI to find amounts; not a full sanitiser.
  String _stripHtml(String html) {
    final noTags = html.replaceAll(RegExp(r'<[^>]+>'), ' ');
    final decoded = noTags
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
    return decoded.replaceAll(RegExp(r'\s+'), ' ');
  }

  String _trim(String s) {
    final collapsed = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    return collapsed.trim();
  }

  Uint8List _base64UrlDecode(String input) {
    var s = input.replaceAll('-', '+').replaceAll('_', '/');
    while (s.length % 4 != 0) {
      s += '=';
    }
    return base64.decode(s);
  }
}
