/// Decoded backup snapshot returned by [BackupStore.get]. Single
/// canonical shape so the HTTP handlers don't care which backend is
/// wired in — every [BackupStore] implementation returns the same
/// `BackupSnapshot`.
///
/// Lives in its own file (not inside either store) so neither store
/// owns the type and adding a third backend later doesn't force a
/// circular import.
class BackupSnapshot {
  BackupSnapshot({
    required this.uploadedAt,
    required this.transactions,
    required this.budgets,
  });

  final DateTime uploadedAt;
  final List<Map<String, Object?>> transactions;
  final List<Map<String, Object?>> budgets;
}

/// Common contract for any backup store. Lets the HTTP handlers and
/// the account-cleanup helper take `BackupStore?` instead of binding
/// to a specific backend. The test harness uses the same interface
/// to inject an in-memory fake without standing up GCS or Firestore.
///
/// We deliberately keep this minimal: just the four methods the
/// handlers actually call. Adding more methods (e.g. `list`, `head`)
/// is fine, but anything that pushes us toward a richer query API
/// means we've drifted back toward a Firestore-shaped store — at
/// that point a subcollection design would be more honest.
abstract class BackupStore {
  /// One-time setup. Idempotent — safe to call from every handler
  /// before each request (current call sites cache the future so the
  /// second call short-circuits).
  Future<void> init();

  /// Replaces the user's backup blob atomically. New payload is
  /// always the full snapshot — restore is replace-all on the
  /// device side, and the server never sees a partial diff.
  Future<void> put(
    String sub, {
    required List<Map<String, Object?>> transactions,
    required List<Map<String, Object?>> budgets,
  });

  /// Returns the stored snapshot or null if no backup exists.
  Future<BackupSnapshot?> get(String sub);

  /// Deletes the user's backup blob. Idempotent — calling on a
  /// sub that never had a backup is a no-op, not an error.
  Future<void> remove(String sub);
}

