import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import 'gmail_auth.dart';
import 'gmail_filter_rules.dart';

/// Pushes the user's [FilterRuleSet] to the server's `/filters/sync`
/// endpoint, which mirrors the rules to the user's Gmail account via
/// the Gmail filters API. So when the user enables a rule on the
/// phone, a matching Gmail-side filter is also created — Gmail then
/// drops matching emails before Pub/Sub ever fires.
///
/// The server is the source of truth for Gmail-side filter IDs: the
/// phone sends the rule set (with whatever IDs it knows), the server
/// diffs against its last-saved set, applies create/delete operations
/// to Gmail, and returns the merged set with whatever IDs Gmail
/// assigned. The phone persists that merged set into BOTH
/// SharedPreferences and the in-memory controller state so future
/// edits can PATCH / DELETE by ID — without this, the next sync
/// tells the server "I have no Gmail-ids" and triggers a
/// delete+recreate churn on every save.
///
/// Auto-sync was removed: an earlier version debounced a sync on
/// every keystroke, but intermediate states (half-typed rules,
/// pending deletes) hit the server and triggered spurious
/// delete/recreate churn on Gmail. The Email filters Save button
/// now calls [saveNow] directly; the agent widget does the same
/// after its controller updates. [syncIfChanged] remains available
/// for callers that want debounced background sync, but no
/// app-level path wires it today.
class RuleSyncService {
  RuleSyncService({
    required this.auth,
    this.onSynced,
    this._filterStore,
    Dio? http,
    Duration? waitForInFlightTimeout,
  })  : _http = http ?? _defaultDio(),
        _waitForInFlightTimeout =
            waitForInFlightTimeout ?? const Duration(seconds: 25);

  final GmailAuth auth;
  final void Function(FilterRuleSet merged)? onSynced;
  /// Local store for the server-merged set. Injected so tests can
  /// pass a no-op; production wiring in `providers.dart` passes the
  /// shared `FilterRuleStore` so the next save can find Gmail ids.
  final FilterRuleStore? _filterStore;
  final Dio _http;
  // How long saveNow() will block waiting for an already-in-flight
  // sync to actually complete before giving up and returning false.
  // Production default is 25s (covers a worst-case cold wake + slow
  // payload); tests override to a few ms so the timeout-mechanism
  // path itself can be verified in <1s.
  final Duration _waitForInFlightTimeout;

  /// Per-rule create failures from the last /filters/sync response.
  /// Keys are rule-index strings ("0", "1", ...), values are the
  /// Gmail-side error messages. Cleared on every fresh sync — only
  /// surfaces "the last save hit problems" rather than getting stuck
  /// on an old failure. Null when the server didn't include any
  /// errors map (the happy path).
  Map<String, dynamic>? lastSyncErrors;

  /// Total rules that came back without a Gmail-side id in the most
  /// recent sync — either they were intentionally untranslatable
  /// (regex-only) or they failed to mirror. Cheap shortcut for the UI
  /// to render a "rules without Gmail mirror" count without indexing
  /// into the FilterRuleSet.
  int get lastSyncUnmirroredCount {
    final s = _lastMergedSet;
    if (s == null) return 0;
    return s.rules.where((r) => r.id == null).length;
  }

  FilterRuleSet? _lastMergedSet;

  Timer? _debounce;
  String? _lastSyncedJson;
  // Tracks the in-flight sync via a Completer so saveNow() can wait
  // for it to *actually* complete before starting its own request.
  // Earlier this was a `bool _inFlight` + `_pendingSave` snapshot —
  // that pair had two bugs: (1) saveNow() returned true once the
  // pending was dequeued (not when its sync actually finished), so a
  // failed second-sync still surfaced as success; (2) the pending
  // snapshot pinned rules at tap-time, so a keystroke between Save
  // and the deferred sync was silently lost. The Completer-based
  // wait eliminates both: saveNow() awaits the in-flight future
  // itself, with a 25s timeout, then reads the latest rules and
  // re-syncs if the user's snapshot still differs.
  Completer<void>? _activeSync;

  static Dio _defaultDio() {
    // Short connect/receive timeouts so a wedged TLS handshake or
    // dropped response surfaces as a real error instead of hanging
    // the UI. 15s connect / 20s receive covers a cold Cloud Run
    // wake + worst-case payload round-trip; transient failures fall
    // back to the debounce path for the auto-sync, and to a clear
    // error message for the Save button.
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    ));
  }

  /// Optional debounced background sync. Not wired anywhere today —
  /// auto-sync on every state change was removed because intermediate
  /// states (half-typed rules, in-progress deletes) hit the server
  /// and produced spurious delete/recreate churn on Gmail. The Save
  /// button calls [saveNow] instead, which always fires immediately.
  /// Kept here for callers that explicitly want a debounced background
  /// sync without going through Save (e.g. a future "autosave toggle"
  /// feature, if we ever add one back).
  void syncIfChanged(FilterRuleSet next) {
    final json = jsonEncode(next.toJson());
    if (json == _lastSyncedJson) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      _debounce = null;
      _runSync(next, json);
    });
  }

  /// Forces an immediate sync, bypassing the debounce. Called from the
  /// Email filters Save button so the user gets confirmation right away
  /// instead of waiting 800 ms. Always fires a fresh POST — we don't
  /// short-circuit on a matching payload because the user's explicit
  /// intent ("click Save") is to commit to the server, regardless of
  /// whether the rules happen to match what was last sent. Returns
  /// true on HTTP 200 with a usable merged response, false on any error.
  ///
  /// If another sync is in flight (auto-sync from a debounce), waits
  /// for it to finish — up to [_waitForInFlightTimeout] (25s in
  /// production) — then sends a fresh request with [rules].
  Future<bool> saveNow(FilterRuleSet rules) async {
    _debounce?.cancel();
    _debounce = null;

    // Wait for any in-flight sync to ACTUALLY finish — not just for
    // its queued run to be dequeued. This is the difference between
    // a truthful Save result and a false success.
    final inFlight = _activeSync;
    if (inFlight != null) {
      try {
        await inFlight.future.timeout(_waitForInFlightTimeout);
      } on TimeoutException {
        // The in-flight sync is wedged. Don't try to start another
        // request on top of it — return false so the UI shows the
        // retry button and the user can decide.
        return false;
      }
    }

    final json = jsonEncode(rules.toJson());
    return _runSync(rules, json);
  }

  Future<bool> _runSync(FilterRuleSet next, String json) async {
    if (_activeSync != null) {
      // Coalesce: a newer change arrived mid-sync (auto-sync path
      // only — saveNow() awaits the active sync before calling us).
      // Reschedule via the debounce so the next run picks up the
      // latest rules and the latest in-flight state.
      syncIfChanged(next);
      return false;
    }
    _activeSync = Completer<void>();
    try {
      final apiToken = await auth.tryRestore();
      if (apiToken == null) {
        debugPrint('[rule-sync] no apiToken — skipping (not signed in)');
        return false;
      }
      final res = await _http.post<dynamic>(
        '$kServerUrl/filters/sync',
        data: {'rules': json},
        options: Options(
          headers: {
            'authorization': 'Bearer $apiToken',
            'content-type': 'application/json',
          },
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 || res.data == null) {
        debugPrint('[rule-sync] server returned ${res.statusCode}: '
            '${res.data}');
        return false;
      }
      final body = res.data;
      final mergedRaw = body is String
          ? body
          : (body['rules'] as String?);
      if (mergedRaw == null) {
        debugPrint('[rule-sync] response missing rules field: $body');
        return false;
      }
      // The server may include an `errors` map when it managed to
      // receive + persist the rules but couldn't mirror some of them
      // to Gmail (e.g. a 400 from Gmail's filters API). We propagate
      // the count so the UI can show "Saved, but 1 rule didn't mirror"
      // instead of a generic success — silent failures were the root
      // cause of the "saved successfully / screen went empty" bug.
      final errors = body is Map
          ? (body['errors'] as Map?)?.cast<String, dynamic>()
          : null;
      if (errors != null && errors.isNotEmpty) {
        lastSyncErrors = errors;
        debugPrint('[rule-sync] server reported ${errors.length} '
            'create failure(s): $errors');
      } else {
        lastSyncErrors = null;
      }
      // Persist the server-merged set so future edits can find their
      // Gmail-side filter by ID.
      final decoded = jsonDecode(mergedRaw);
      if (decoded is! Map) {
        debugPrint('[rule-sync] merged rules not a map: $mergedRaw');
        return false;
      }
      final merged = FilterRuleSet.fromJson(decoded.cast<String, Object?>());
      await _filterStore?.write(merged);
      // Cache the merged set so the UI can render an "unmirrored"
      // count without re-fetching. Cleared on the next sync.
      _lastMergedSet = merged;
      // Update _lastSyncedJson to the MERGED json (not the one we
      // sent). The server may have reassigned Gmail-ids, so the
      // controller state we propagate must match what the listener
      // will see, otherwise the next listener fire would re-sync.
      _lastSyncedJson = jsonEncode(merged.toJson());
      // Push the merged set into the in-memory controller state.
      // Without this, the next sync POSTs rules with id=null and
      // triggers a delete+recreate cycle on the server.
      onSynced?.call(merged);
      debugPrint('[rule-sync] synced ${merged.rules.length} rules');
      return true;
    } catch (e) {
      debugPrint('[rule-sync] failed: $e');
      return false;
    } finally {
      // Complete the active-sync completer BEFORE clearing the
      // reference, so saveNow() callers see a fully-finished sync
      // (including its return value) the moment they wake up.
      final completer = _activeSync;
      _activeSync = null;
      completer?.complete();
    }
  }

  /// Visible-for-testing: clears dedup state so the next call
  /// unconditionally fires. Used by widget tests that mount a fresh
  /// RuleSyncService and need a sync to actually happen.
  @visibleForTesting
  void resetForTest() {
    _debounce?.cancel();
    _debounce = null;
    _lastSyncedJson = null;
    final stale = _activeSync;
    _activeSync = null;
    stale?.complete();
  }

  /// Pulls the current canonical [FilterRuleSet] from the server via
  /// `GET /filters/status`. The server's reply is the stored set after
  /// it's been reconciled against Gmail's live filter list — any rule
  /// whose Gmail-side id no longer exists in the user's Gmail (e.g.
  /// they deleted it from Gmail's own UI) gets pruned here, and the
  /// pruned set is persisted back to Firestore.
  ///
  /// We propagate the cleaned set through the same [onSynced] hook
  /// used by `saveNow`/`_runSync`, so the in-memory controller state
  /// stays in sync with what Firestore and Gmail hold — without this,
  /// a Gmail-side delete would leave a phantom id in the phone's
  /// state until the next save.
  ///
  /// Returns true on success, false if the user isn't signed in or
  /// the request failed (network/502/etc). Never throws.
  Future<bool> refresh() async {
    final apiToken = await auth.tryRestore();
    if (apiToken == null) {
      debugPrint('[rule-sync] no apiToken — refresh skipped (not signed in)');
      return false;
    }
    try {
      final res = await _http.get<dynamic>(
        '$kServerUrl/filters/status',
        options: Options(
          headers: {'authorization': 'Bearer $apiToken'},
          validateStatus: (_) => true,
        ),
      );
      if (res.statusCode != 200 || res.data == null) {
        debugPrint('[rule-sync] refresh returned ${res.statusCode}');
        return false;
      }
      final body = res.data;
      final rulesRaw = body is String ? body : (body['rules'] as String?);
      if (rulesRaw == null) {
        debugPrint('[rule-sync] refresh missing rules field: $body');
        return false;
      }
      final decoded = jsonDecode(rulesRaw);
      if (decoded is! Map) {
        debugPrint('[rule-sync] refresh rules not a map: $rulesRaw');
        return false;
      }
      final cleaned = FilterRuleSet.fromJson(decoded.cast<String, Object?>());
      await _filterStore?.write(cleaned);
      _lastMergedSet = cleaned;
      lastSyncErrors = null;
      _lastSyncedJson = jsonEncode(cleaned.toJson());
      onSynced?.call(cleaned);
      debugPrint('[rule-sync] refreshed to ${cleaned.rules.length} rules');
      return true;
    } catch (e) {
      debugPrint('[rule-sync] refresh failed: $e');
      return false;
    }
  }
}
