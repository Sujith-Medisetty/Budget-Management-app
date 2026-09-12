import 'dart:convert';
import 'dart:io' show File;

import 'package:http/http.dart' as http;

import 'config.dart';
import 'http_client.dart';

/// Fetches Gmail messages since a stored historyId. When
/// `config.gmailTestMode` is on, returns canned responses from
/// `test/canned-history.json` so we can run the full Pub/Sub →
/// FCM path locally without real Google credentials.
///
/// In prod we use raw HTTP + a per-request access_token derived
/// from the user's stored refresh_token. The generated googleapis_auth
/// path requires domain-wide delegation or a signed JWT — both more
/// moving parts than this app needs for two endpoints.
class GmailFetcher {
  GmailFetcher(this.config);

  final ServerConfig config;
  final http.Client _http = safeHttpClient();

  /// Set by [withAccessToken] before each call; the helpers below
  /// pick it up. Volatile, but the pubsub handler runs requests
  /// serially per process so there's no race.
  String? _accessToken;

  Future<List<String>> messagesSince(String startHistoryId) async {
    if (config.gmailTestMode) {
      final canned = await _loadCanned();
      return List<String>.from(canned['messageIds'] as List);
    }

    final token = _accessToken!;
    final uri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/history'
        '?startHistoryId=$startHistoryId&historyTypes=messageAdded');
    final res = await _http.get(uri, headers: {'authorization': 'Bearer $token'});
    if (res.statusCode != 200) {
      throw StateError('history.list failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final history = (body['history'] as List?) ?? const [];
    final ids = <String>{};
    for (final h in history.cast<Map<String, dynamic>>()) {
      final added = h['messagesAdded'] as List? ?? const [];
      for (final m in added.cast<Map<String, dynamic>>()) {
        final id = (m['message'] as Map?)?['id'] as String?;
        if (id != null) ids.add(id);
      }
      final msgs = h['messages'] as List? ?? const [];
      for (final m in msgs.cast<Map<String, dynamic>>()) {
        final id = m['id'] as String?;
        if (id != null) ids.add(id);
      }
    }
    return ids.toList();
  }

  Future<EmailEnvelope> fetchEnvelope(String messageId) async {
    if (config.gmailTestMode) {
      final canned = await _loadCanned();
      final list = (canned['envelopes'] as List).cast<Map<String, dynamic>>();
      final hit = list.firstWhere((e) => e['messageId'] == messageId);
      return EmailEnvelope.fromJson(hit);
    }

    final token = _accessToken!;
    final uri = Uri.parse(
        'https://gmail.googleapis.com/gmail/v1/users/me/messages/$messageId?format=full');
    final res = await _http.get(uri, headers: {'authorization': 'Bearer $token'});
    if (res.statusCode != 200) {
      throw StateError('messages.get failed: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final payload = body['payload'] as Map<String, dynamic>?;
    final headers = <String, String>{};
    for (final h in (payload?['headers'] as List? ?? const [])
        .cast<Map<String, dynamic>>()) {
      final name = (h['name'] as String? ?? '').toLowerCase();
      headers[name] = h['value'] as String? ?? '';
    }
    return EmailEnvelope(
      messageId: messageId,
      from: headers['from'] ?? '',
      subject: headers['subject'] ?? '',
      // Gmail API returns `internalDate` as a string (int64 epoch-ms
      // encoded per Google's JSON conventions). Pass it through as a
      // dynamic — parseEmailDate accepts both int and string and only
      // falls back to DateTime.now() if neither parses.
      date: parseEmailDate(
        headerValue: headers['date'],
        internalDateMs: body['internalDate'],
      ),
      text: '',
      rawPayload: payload,
    );
  }

  /// Sets the access_token to use for the next Gmail API calls, then
  /// runs [body]. Caller is responsible for refreshing the token if
  /// it expires mid-run.
  Future<T> withAccessToken<T>(String token, Future<T> Function() body) async {
    _accessToken = token;
    try {
      return await body();
    } finally {
      _accessToken = null;
    }
  }

  Future<Map<String, dynamic>> _loadCanned() async {
    final file = await _readAsset('test/canned-history.json');
    return jsonDecode(file) as Map<String, dynamic>;
  }

  Future<String> _readAsset(String path) async {
    final file = File(path);
    return file.readAsString();
  }
}

/// Parses an RFC 2822 email `Date:` header into UTC.
///
/// Dart's `DateTime.tryParse` silently ignores the trailing `+HHMM` /
/// `-HHMM` offset and reads it as UTC, which shifts real-world dates
/// by hours. We parse the offset manually and convert. Common
/// formats encountered:
///   - `Sat, 5 Sep 2026 12:34:56 -0700`
///   - `Sat, 5 Sep 2026 12:34:56 +0530`
///   - `5 Sep 2026 12:34:56 -0700` (no weekday — some bulk senders)
///   - `Sat, 5 Sep 26 12:34:56 +0530` (two-digit year)
///   - `Sat, 5 Sep 2026 12:34:56 GMT`
///
/// Falls back to Gmail's `internalDate` (UTC epoch ms = when Gmail
/// received the message) if the header is missing or unparseable;
/// finally falls back to `DateTime.now()`.
/// `internalDateMs` may arrive as int or String — Gmail's API encodes
/// epoch-ms as a JSON string to avoid 32-bit overflow on large values.
DateTime parseEmailDate({String? headerValue, dynamic internalDateMs}) {
  if (headerValue != null && headerValue.isNotEmpty) {
    final parsed = _tryParseRfc2822(headerValue.trim());
    if (parsed != null) return parsed.toUtc();
  }
  if (internalDateMs != null) {
    final ms = internalDateMs is int
        ? internalDateMs
        : int.tryParse(internalDateMs.toString());
    if (ms != null && ms > 0) {
      return DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
  }
  return DateTime.now().toUtc();
}

/// One regex covering weekday + day + month + (2- or 4-digit year) +
/// time + zone. We capture the offset digits (`+HHMM` / `-HHMM`) and
/// the literal `GMT` so we can normalize both to a real UTC moment.
final _rfc2822 = RegExp(
  r'^(?:[A-Za-z]{3},\s+)?'
  r'(\d{1,2})\s+'
  r'([A-Za-z]{3})\s+'
  r'(\d{2}|\d{4})\s+'
  r'(\d{2}):(\d{2})(?::(\d{2}))?\s*'
  r'([+-]\d{4}|[A-Z]{1,5})',
);

const _monthNames = <String, int>{
  'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
  'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
};

DateTime? _tryParseRfc2822(String s) {
  final m = _rfc2822.firstMatch(s);
  if (m == null) return null;
  final day = int.parse(m.group(1)!);
  final month = _monthNames[m.group(2)!] ?? 0;
  if (month == 0) return null;
  final yearRaw = m.group(3)!;
  // Two-digit year: RFC 2822 says 00-49 → 20xx, 50-99 → 19xx.
  final year = yearRaw.length == 2
      ? (int.parse(yearRaw) < 50 ? 2000 + int.parse(yearRaw)
                                  : 1900 + int.parse(yearRaw))
      : int.parse(yearRaw);
  final hour = int.parse(m.group(4)!);
  final minute = int.parse(m.group(5)!);
  final secStr = m.group(6);
  final second = int.parse(secStr ?? '0');
  final zone = m.group(7)!;
  // Treat the wall time as floating (no zone) and apply the parsed
  // offset explicitly — that's how the email author meant it.
  var dt = DateTime.utc(year, month, day, hour, minute, second);
  if (zone == 'GMT' || zone == 'UT' || zone == 'Z') {
    // Already UTC.
  } else {
    final sign = zone[0] == '-' ? -1 : 1;
    final offHours = int.parse(zone.substring(1, 3));
    final offMins = int.parse(zone.substring(3, 5));
    final offsetMin = sign * (offHours * 60 + offMins);
    // Wall time was UTC+offsetMin; subtract the offset to get UTC.
    dt = dt.subtract(Duration(minutes: offsetMin));
  }
  return dt;
}

class EmailEnvelope {
  const EmailEnvelope({
    required this.messageId,
    required this.from,
    required this.subject,
    required this.date,
    required this.text,
    this.rawPayload,
  });

  final String messageId;
  final String from;
  final String subject;
  final DateTime date;
  final String text;
  final Map<String, dynamic>? rawPayload;

  factory EmailEnvelope.fromJson(Map<String, dynamic> j) => EmailEnvelope(
        messageId: j['messageId'] as String,
        from: j['from'] as String? ?? '',
        subject: j['subject'] as String? ?? '',
        date: DateTime.parse(j['date'] as String),
        text: j['text'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'messageId': messageId,
        'from': from,
        'subject': subject,
        'date': date.toIso8601String(),
        'text': text,
      };
}