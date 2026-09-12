import 'package:flutter/foundation.dart';

import 'accounts_repo.dart';

/// Called once after a successful OAuth exchange. Pre-warms the
/// network path so the first Backup screen open (which fires a
/// `GET /accounts/<sub>` for its settings) hits a warm connection
/// instead of cold-starting. With the VM-backed `accountsRepo`, this
/// is a single round-trip — the Firestore-SDK version had a similar
/// role; the trigger that kept Cloud Scheduler in lockstep with
/// `backupPrefs` no longer exists (auto-backup is currently disabled
/// while we settle on R2), so a successful fetch here is just a
/// sanity check that the row is readable.
///
/// Idempotent: safe to call repeatedly. Best-effort: any failure is
/// logged but never thrown — the user is already signed in, so a
/// hydration failure just means the Backup screen will fetch on
/// first open instead of having it pre-populated.
class AccountHydrator {
  AccountHydrator({required this.repo});

  final AccountsRepo repo;

  /// Best-effort hydration. Returns silently — the caller (the
  /// auto-restore at sign-in) doesn't have anything to do with the
  /// outcome besides refreshing dependent providers.
  Future<void> hydrate() async {
    try {
      await repo.fetch();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[hydrator] fetch failed: $e');
      }
    }
  }
}
