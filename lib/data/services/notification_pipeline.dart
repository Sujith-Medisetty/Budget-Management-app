import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/raw_notification.dart';
import '../models/transaction.dart';
import '../repositories/ai_log_store.dart';
import '../repositories/transaction_repository.dart';
import 'budget_alerter.dart';
import 'notification_service.dart';
import 'parser_router.dart';

/// Bridge from raw notifications → DB rows → budget alerts + capture
/// notifications.
///
/// One public method [handle] does the whole thing: parse via the
/// cloud AI parser, dedup by notification_key, insert if new, fire
/// the user-visible "captured" notification, then kick the budget
/// alerter so thresholds can fire for the current period.
class NotificationPipeline {
  NotificationPipeline(
    this._parser,
    this._txRepo,
    this._alerter, {
    this._notifier,
  });

  final ParserRouter _parser;
  final TransactionRepository _txRepo;
  final BudgetAlerter _alerter;
  final NotificationService? _notifier;

  /// Returns the inserted row, or null if it was a duplicate or
  /// every parser failed.
  Future<Transaction?> handle(RawNotification n) async {
    final parsed = await _parser.parse(n);
    if (parsed == null) {
      if (kDebugMode) {
        debugPrint(
          '[pipe] parser returned null for ${n.notificationKey} — dropped',
        );
      }
      return null;
    }

    final candidate = Transaction(
      id: null,
      notificationKey: n.notificationKey,
      source: parsed.source,
      amount: parsed.amount,
      merchant: parsed.merchant,
      reason: parsed.reason,
      occurredAt: n.postedAt,
    );

    final result = await _txRepo.insertIfNew(candidate);
    if (!result.inserted) {
      if (kDebugMode) {
        debugPrint(
          '[pipe] duplicate key=${candidate.notificationKey} — already in DB',
        );
      }
      // The parser already recorded a KEPT row for this key. Log a
      // duplicate marker so the activity log shows that the same
      // notification re-fired and we skipped the second insert.
      unawaited(
        AiLogStore.record(
          package: n.packageName,
          sourceText: n.text,
          decision: 'dropped',
          reason: 'duplicate of an already-saved transaction',
          parsedAmount: candidate.amount,
          parsedMerchant: candidate.merchant,
          parsedSource: candidate.source,
        ),
      );
      return null;
    }

    if (kDebugMode) {
      debugPrint(
        '[pipe] inserted id=${result.row.id} '
        'source=${result.row.source} '
        'amount=${result.row.amount} '
        'merchant="${result.row.merchant}"',
      );
    }

    // The RawNotification's text is "$subject\n$body" for Gmail-shaped
    // notifications; pull subject back out so the capture notification
    // can show what email it came from. For non-Gmail sources the text
    // is a flat string — split() just returns [text] and the subject
    // ends up empty, which is the right behavior.
    final lines = n.text.split('\n');
    final subject = lines.length > 1 ? lines.first.trim() : null;

    // Pull the active-budget snapshot BEFORE firing the capture
    // notification so the notification can show the same spent /
    // remaining / per-day numbers the user sees on the dashboard.
    // snapshot() reads spent AFTER the insertIfNew above, so the
    // figure includes this transaction.
    BudgetAlertContent? budgetContext;
    try {
      final snap = await BudgetAlerter.activeBudgetSnapshot(
        _txRepo,
        _alerter.budgetRepo,
      );
      if (snap != null) {
        budgetContext = BudgetAlerter.buildContent(
          budget: snap.budget,
          trigger: result.row,
          spent: snap.spent,
          periodEnd: snap.periodEnd,
        );
      }
    } on Object catch (e) {
      // Never let a budget lookup kill the capture notification —
      // log and fall through with no budget context.
      debugPrint('[pipe] budget snapshot failed: $e');
    }

    // Fire the user-visible "we saved this" notification BEFORE the
    // budget alerter so the capture appears even when the alerter
    // decides no threshold was crossed.
    await _notifier?.showTransactionCaptured(
      merchant: result.row.merchant,
      amount: result.row.amount,
      source: result.row.source,
      emailFrom: n.title.isEmpty ? null : n.title,
      subject: subject,
      reason: result.row.reason,
      occurredAt: result.row.occurredAt,
      budgetContext: budgetContext,
    );

    // Skip the separate budget alert when the capture already showed
    // budget context. Otherwise the user gets TWO notifications per
    // email (capture + "Budget 80% used") even though the capture body
    // already says "X / Y used". The alerter still runs when there's
    // no active budget (budgetContext is null) so future budgets
    // picked up via /sync get evaluated.
    if (budgetContext == null) {
      await _alerter.evaluate(result.row);
    }
    return result.row;
  }
}
