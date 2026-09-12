import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'config.dart';
import 'http_client.dart';

/// Manages a custom Gmail label that owns the Pub/Sub watch surface
/// for a connected Pocket account. The flow:
///
/// 1. On sign-in (or first Pub/Sub push for a legacy account), call
///    [ensurePocketLabelId]. If a label named `pocketLabelName`
///    already exists in the user's Gmail, hand back its id. If not,
///    create one and hand back the new id.
/// 2. Server-side filters add this label to matching emails (via
///    Gmail's `addLabelIds` filter action). Gmail applies the label
///    at SMTP-receive time on Google's servers — our container
///    never sees the email during label application.
/// 3. `users.watch` is configured with `labelIds=[pocketLabelId]`
///    and `labelFilterAction='include'`. Pub/Sub fires only when
///    this label is added/removed — so non-matching emails never
///    trigger a push.
///
/// The name is "Pocket/Keep" — the slash is just Gmail's display
/// convention for nested-style labels; the actual id is opaque
/// (`Label_42` or similar).
class GmailLabelManager {
  GmailLabelManager({
    required this.accessToken,
    http.Client? client,
    this.config,
  }) : _http = client ?? safeHttpClient();

  final String accessToken;
  final http.Client _http;
  final ServerConfig? config;
  final _log = Logger('gmail-labels');

  static const _base =
      'https://gmail.googleapis.com/gmail/v1/users/me/labels';

  /// The label name we own. Exposed as a constant so tests and
  /// callers can refer to it without hard-coding.
  static const pocketLabelName = 'Pocket/Keep';

  int _fakeIdCounter = 0;

  /// Returns the id of the Pocket label, creating it if absent.
  /// Idempotent — safe to call on every sign-in and every push.
  Future<String> ensurePocketLabelId() async {
    final existing = await findLabelByName(pocketLabelName);
    if (existing != null) {
      _log.info('pocket label already exists: id=$existing');
      return existing;
    }
    _log.info('pocket label missing — creating "$pocketLabelName"');
    return createLabel(pocketLabelName);
  }

  /// Lists Gmail-side labels and returns the id of the one whose
  /// `name` matches [name], or null if none.
  Future<String?> findLabelByName(String name) async {
    if (config?.gmailTestMode ?? false) {
      // Test mode: pretend the label doesn't exist so the caller
      // falls through to `createLabel`, which also short-circuits
      // and returns a fake id. We don't want to hit gmailapis.com
      // for a label list — the JWT skip path is for /pubsub/push,
      // not Gmail API calls.
      return null;
    }
    final res = await _http.get(
      Uri.parse(_base),
      headers: {'authorization': 'Bearer $accessToken'},
    );
    if (res.statusCode != 200) {
      throw StateError(
          'gmail labels.list failed: ${res.statusCode} ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final labels = (json['labels'] as List?) ?? const <dynamic>[];
    for (final raw in labels) {
      final l = raw as Map<String, dynamic>;
      if (l['name'] == name && l['id'] is String) {
        return l['id'] as String;
      }
    }
    return null;
  }

  /// Creates a new Gmail label with the given name and returns its id.
  Future<String> createLabel(String name) async {
    if (config?.gmailTestMode ?? false) {
      // Test mode: skip the real Gmail call. Still hand back an id so
      // the rest of the flow (watch registration, filter actions)
      // exercises end-to-end. IDs look like 'test-label-N' for easy
      // spotting in logs.
      _fakeIdCounter++;
      final fakeId = 'test-label-$_fakeIdCounter';
      _log.info('GMAIL_TEST_MODE: created fake label $fakeId (name="$name")');
      return fakeId;
    }
    final res = await _http.post(
      Uri.parse(_base),
      headers: {
        'authorization': 'Bearer $accessToken',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'name': name,
        // labelListVisibility=labelShow shows the label in the
        // label list pane on the left of Gmail's web UI — useful so
        // the user can verify "yes, Pocket is labeling my mail".
        // messageListVisibility=show lets messages with this label
        // appear in the label's view in Gmail.
        'labelListVisibility': 'labelShow',
        'messageListVisibility': 'show',
      }),
    );
    if (res.statusCode != 200) {
      throw StateError(
          'gmail labels.create failed: ${res.statusCode} ${res.body}');
    }
    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final id = json['id'] as String?;
    if (id == null) {
      throw StateError(
          'gmail labels.create returned no id: ${res.body}');
    }
    _log.info('created gmail label $id (name="$name")');
    return id;
  }
}