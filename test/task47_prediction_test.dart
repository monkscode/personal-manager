// TASK-47 — offline prediction for the settled-debit guard on card buckets.
//
// Spec A Part 2 gave each card its own bucket by making its tail readable. Two
// of the buckets it opened are not credit cards, and each got a line in "Needs
// your attention" claiming a bill that will never arrive:
//
//   Card 7102  ₹3,56,000  23 rows, every one `Withdrawn ... Bal ...` — HDFC ATM
//                         cash-outs, stored as `pos` because the body names the
//                         debit card. The money left the bank in 2025-10..2026-07.
//   Card 7113  ₹4,235     6 rows, `Paid ... Bal ...` — debit-card POS purchases,
//                         already settled.
//
// Before Part 2 both sat unnamed in the shared `unknown` bucket and were
// windowed out by a payment credit, contributing ₹0. Naming them split them into
// buckets with no payment credit of their own, so `windowStart == null` and the
// figure became a lifetime total.
//
// This measures the guard against a real export, per the TASK-43/44/45/46
// precedent: predict, then install. It runs the production path —
// load -> normalize -> reduce -> reconciliation items — because the defect is
// only visible once the items are built, and a prediction that stops at the
// estimator is not predicting what the user sees.
//
// It is pinned at TWO clocks on purpose. The rejected alternative — keep only
// buckets that carry credit-card evidence (`avl lmt` and friends) — looked
// right at one date and silently dropped genuine cards 7114 (₹93,706) and 7105
// (₹3,419) at another, because the 13-month lookback slides and starves a
// bucket of the rows that carried its evidence. Card identity must not depend
// on the calendar, so a second clock is part of the gate, not a nicety.
//
// USAGE
//   1. Pull the device database to `.private/transactions.db` (gitignored —
//      this repository is public and the export is real SMS data).
//   2. flutter test test/task47_prediction_test.dart
//   3. Delete the export when done.
//
// Skips silently when no export is present, so the suite stays green.
import 'dart:io';

import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_decision_store.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/money_lens.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _rs(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

/// The cardPurchase lines the user actually reads, at [now].
Future<Map<String, int>> _cardLines(String path, DateTime now) async {
  final db = await SmsDatabase.openWithFactory(
    factory: databaseFactoryFfi,
    path: path,
  );
  final lookbackStart = DateTime(
    now.year,
    now.month - kAnalysisLookbackMonths,
    1,
  );
  final history = await TransactionRepository(db).allSince(lookbackStart);
  final snapshot = SmsAnalysisSnapshot.reduce(
    history: const SmsLiveNormalizer().normalize(history),
    obligations: await ObligationRepository(db).allActive(),
    riskDecisions: await ForecastRiskDecisionStore(db).all(),
    configuredPlans: const [],
    now: now,
  );
  await db.close();
  return {
    for (final item in snapshot.reconciliationItems)
      if (item.owner == ForecastOwner.cardPurchase)
        item.label: item.amountPaise ?? 0,
  };
}

void main() {
  // Absolute for the reason TASK-46's header gives: sqflite_common_ffi resolves
  // a relative path against its own directory and would quietly create an empty
  // database rather than fail.
  final exportPath = File(
    Platform.environment['TASK47_DB'] ?? '.private/transactions.db',
  ).absolute.path;

  test('TASK-47 — no card bill is claimed for money already out of the bank',
      () async {
    if (!File(exportPath).existsSync()) {
      markTestSkipped(
        'No device export at $exportPath — see the header of this file. '
        'Skipping so the suite stays green.',
      );
      return;
    }
    sqfliteFfiInit();

    for (final now in [DateTime(2026, 8, 7, 12), DateTime(2026, 9, 7, 12)]) {
      final lines = await _cardLines(exportPath, now);
      final total = lines.values.fold<int>(0, (s, v) => s + v);

      // ignore: avoid_print
      print(
        '\n=== TASK-47 prediction @ $now ===\n'
        '${lines.entries.map((e) => '  ${_rs(e.value).padRight(14)} ${e.key}\n').join()}'
        '  ${'-' * 58}\n'
        '  ${_rs(total)} total\n',
      );

      expect(
        lines.keys.any((l) => l.contains('7102')),
        isFalse,
        reason: 'card 7102 is 23 ATM cash-outs; the money left the bank months '
            'ago and no card will bill for it',
      );
      expect(
        lines.keys.any((l) => l.contains('7113')),
        isFalse,
        reason: 'card 7113 is 6 settled debit-card purchases, already inside '
            'the spend total — a bill line for them double-counts',
      );
      expect(
        lines.keys.any((l) => l.contains('7117')),
        isTrue,
        reason: 'card 7117 is the one genuine credit card, and its line is '
            'correct — the guard must not swallow it',
      );
      expect(total, 59000, reason: 'only 7117\'s ₹590 survives');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('TASK-47 — the balance and limit vocabularies never overlap', () async {
    if (!File(exportPath).existsSync()) {
      markTestSkipped('No device export at $exportPath.');
      return;
    }
    sqfliteFfiInit();
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: exportPath,
    );
    // Every stored row, no lookback: whether a card is a credit card is a
    // property of the card, not of the window it is read through.
    final cards = (await TransactionRepository(db).allSince(DateTime(2000)))
        .where((t) => t.instrument == PaymentInstrument.card)
        .toList();
    await db.close();

    final both = cards.where((t) {
      final body = t.rawBodyRedacted.toLowerCase();
      return MoneyLens.reportsBankBalance(t) &&
          kCreditCardPurchaseMarkers.any(body.contains);
    }).toList();

    expect(
      both,
      isEmpty,
      reason: 'a row reporting both a running balance and an available limit '
          'would mean the two vocabularies do not separate debit from credit, '
          'which is the entire basis of the guard',
    );
    expect(
      cards.where(MoneyLens.reportsBankBalance).length,
      29,
      reason: 'the guard is expected to fire on exactly the 23 rows of card '
          '7102 and the 6 of card 7113 — a different count means the export '
          'moved and the prediction needs re-deriving',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
