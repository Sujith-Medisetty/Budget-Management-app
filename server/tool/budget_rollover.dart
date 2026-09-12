import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:logging/logging.dart';

import 'package:pocket_server/accounts_repo.dart';
import 'package:pocket_server/budget_rollover.dart';
import 'package:pocket_server/budgets_repo.dart';

/// 1st-of-month budget-rollover job. Iterates every account, runs
/// `ensureCurrentMonthBudget` for each, and reports a summary.
///
/// Runs as a systemd oneshot unit (see
/// `systemd/pocket-budget-rollover.service`) triggered by
/// `systemd/pocket-budget-rollover.timer` at 00:05 UTC on the 1st
/// of every month. The same helper backs
/// `GET /budgets/ensure-current`, so a user who signs in mid-rollover
/// also gets the new month minted immediately.
///
/// Args:
///   --dry-run   Print what would happen without writing. Useful
///               for the operator to confirm the cron's coverage
///               without committing any rows. The script still opens
///               the Postgres connection (to read the account list)
///               but skips the `BudgetsRepo.insert` + activate
///               calls.
///
/// Exit codes:
///   0 — ran to completion (errors against individual subs are
///       logged but don't fail the whole run, since a single broken
///       account shouldn't take down the month's rollover for
///       everyone else)
///   1 — couldn't connect to Postgres / read accounts
Future<void> main(List<String> args) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) {
    // Plain print so journald captures one line per record.
    // ignore: avoid_print
    print('[${r.level.name}] [budget-rollover] ${r.message}');
  });
  final log = Logger('budget-rollover');

  if (args.contains('--help') || args.contains('-h')) {
    // ignore: avoid_print
    print('Usage: dart run tool/budget_rollover.dart [--dry-run]');
    exit(0);
  }
  final dryRun = args.contains('--dry-run');

  final startedAt = DateTime.now().toUtc();
  log.info('start at ${startedAt.toIso8601String()}${dryRun ? " (dry-run)" : ""}');

  try {
    final dotenv = DotEnv(includePlatformEnvironment: true)..load(['.env']);
    final accounts = AccountsRepo(endpoint: pgEndpointFromEnv(dotenv: dotenv));
    await accounts.init();
    final budgets = BudgetsRepo(accounts: accounts);

    final subs = await accounts.all();
    log.info('processing ${subs.length} account(s) for '
        '${startedAt.year}-${startedAt.month.toString().padLeft(2, "0")}');

    var minted = 0;
    var already = 0;
    var optedOut = 0;
    var failed = 0;

    for (final account in subs) {
      if (dryRun) {
        log.info('  sub=${account.sub} email=${account.email} '
            'autoMonthlyBudget=${account.budgetPrefs.autoMonthlyBudget} '
            '(dry-run — skipping)');
        continue;
      }
      try {
        final outcome = await ensureCurrentMonthBudget(
          sub: account.sub,
          prefs: account.budgetPrefs,
          budgets: budgets,
        );
        switch (outcome.result) {
          case EnsureResult.createdNow:
            minted++;
            break;
          case EnsureResult.alreadyExisted:
            already++;
            break;
          case EnsureResult.userOptedOut:
            optedOut++;
            break;
        }
      } catch (e, st) {
        failed++;
        log.warning('sub=${account.sub} FAILED: $e');
        log.warning(st.toString());
      }
    }

    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    log.info('summary: minted=$minted already=$already optedOut=$optedOut '
        'failed=$failed of ${subs.length} in ${elapsedMs}ms');
    log.info('done ok');
    await accounts.close();
    exit(0);
  } catch (e, st) {
    log.severe('FAILED: $e');
    log.severe(st.toString());
    exit(1);
  }
}
