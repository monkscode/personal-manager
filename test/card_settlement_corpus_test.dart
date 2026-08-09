// The card-settlement rules -- CardSettlementPairer, CardSettlementCandidateFinder,
// MoneyLens.isCardSettlement -- proved against seven years of the owner's real
// SMS, not the fixtures the rest of the suite writes. This is the test that
// would have caught both rejected designs: the unsupervised prefix rule that
// erased 11 innocent rows, and the pairing-only design that leaves `cheq` --
// Rs.1,90,417, the single largest card payment on the device -- counted as
// ordinary shopping because it "never" pairs with anything. (That specific
// claim turns out not to hold on this corpus -- see below.)
//
// MEASURED 2026-08-09 against `.private/transactions.db`, 2,071 rows, 1,026
// bank debits -- the same corpus the design spec measured against
// (`docs/superpowers/specs/2026-08-08-card-settlement-pairing-design.md`),
// confirmed identical in every count checked against the
// `.private/transactions-2026-08-07-stale.db` snapshot beside it. The
// divergences documented below are therefore NOT corpus drift.
//
// MONEY CLASSIFICATION MATCHES THE SPEC EXACTLY. With the owner's 13 real
// answers (9 confirmed, 4 declined -- see `confirmed`/`declined` below), the
// settled total is exactly 58 rows / Rs.7,47,129.31 (spec fact 9's "58 of the
// 59"), no declined merchant is ever excluded, and the August 2026 leak is
// gone. `MoneyLens.isCardSettlement` / `isSpend` are correct on live data.
//
// THE RAW PAIRING COUNT DOES NOT MATCH THE SPEC, AND THE GAP IS NOT DRIFT.
// The spec's fact 8 measured "same day, <= Rs.500: 37 paired, 37 correct,
// 100% precision", and fact 11 states plainly that `cheq` and
// `creditcard payment` "never" pair. On this exact corpus,
// `CardSettlementPairer().pairs(rows)` returns 73, and two of the "never
// pairs" rows now pair validly: `cheq`'s Rs.1,90,417 debit (01-May-2025)
// pairs at a Rs.100 gap with an ICICI Bank credit-card BBPS acknowledgement,
// and `creditcard payment`'s Rs.998 debit (19-May-2021) pairs at an exact
// Rs.0 gap with an Axis Bank credit-card acknowledgement -- both hand-checked
// against the raw SMS body (card tails omitted here on purpose: this
// repository is public); neither looks like coincidence.
//
// Ruled out, in the order the task brief for this file said to check first:
//   1. Matching algorithm (global smallest-gap vs first-debit-wins): a
//      by-hand reproduction of first-debit-wins over this same corpus also
//      returns 73. Not the cause.
//   2. Round 1's candidate set following from pairing: true, but that is a
//      symptom of the count below, not an independent cause.
//   3. SmsLiveNormalizer enrichment: running `.normalize()` over the corpus
//      first changes nothing -- identical 73 pairs, identical merchant set.
//      Not the cause.
//   Also checked and ruled out: the `isCardBillPayment` "credited to your
//   card" wording (added 2026-08-07, before the pairer existed) adds 8 raw
//   acknowledgement rows, but all 8 are exact duplicates -- within the
//   existing dedupe window -- of acknowledgements the narrower, earlier
//   wording already matched. Net effect on the pair count: zero.
//
// The likeliest explanation is that the spec's own fact-8/fact-11 tables came
// from a since-lost scratchpad script that missed real pairs, not that the
// corpus or the shipped code moved underneath it. Three of the new pairs do
// look like the coincidental same-day/near-amount collisions fact 10 already
// warns about -- `milkbasket` (a grocery-delivery merchant), a P2P payment to
// a named individual (UPI/P2A), and a debit-card POS purchase whose merchant
// field is a raw, unredacted payment-terminal code -- each landing within the
// Rs.500 cap of an unrelated card's bill acknowledgement purely by chance.
// The latter two are deliberately not quoted literally anywhere in this
// file: one names a person and the other is unredacted transaction-terminal
// data, and this repository is public. None of this misclassifies a rupee: a
// raw pair is only ever a *candidate*, never an auto-exclusion, and the
// money-side tests below prove the set that actually ships is exactly right.
// The practical effect is a bigger review queue than the spec advertised --
// those 3 merchants are still unanswered on the real device today, which the
// second half of the first test below measures by count and by exclusion
// from the known-answered set, not by naming them.
//
// A drifting count should be re-measured, never relaxed -- but re-measuring
// this file's pairer/candidate numbers means repeating the three checks
// above, not just editing the literal. If a future run finds a different
// count, trace the specific new or missing pairs by hand before touching an
// assertion, the way this header's numbers were produced.
//
// LIFETIME, NOT THE APP'S WINDOW. This reads `allSince(DateTime(2000))` --
// every stored row. The running app does not: `TransactionsNotifier.build()`
// reads `allSince(now - kAnalysisLookbackMonths)`, and `kAnalysisLookbackMonths`
// is 13. `cheq` is dated 2025-05-01, old enough to predate that window on a
// device read today, so it is proved reachable by the rules here and may
// never be proposed live. Owner ruling: accept and document, no production
// change -- this file tests the rules, not the window.
//
// USAGE
//   1. Point CARD_SETTLEMENT_DB at a device export, or drop one at
//      .private/transactions.db (gitignored -- this repository is public and
//      the export is real SMS data).
//   2. flutter test test/card_settlement_corpus_test.dart
//
// Skips silently -- markTestSkipped, not a failure -- when no export is
// present, so CI (which has no .private/) stays green.
import 'dart:io';

import 'package:expense_insight/data/card_settlement_front_store.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/card_settlement_candidates.dart';
import 'package:expense_insight/services/card_settlement_pairer.dart';
import 'package:expense_insight/services/money_lens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Every stored row, oldest first -- not a lookback window. See the module
/// docstring on why lifetime is the right read for this file even though the
/// running app never reads this far back.
Future<List<ParsedTxn>> _corpus(String path) async {
  final db = await SmsDatabase.openWithFactory(
    factory: databaseFactoryFfi,
    path: path,
  );
  final rows = await TransactionRepository(db).allSince(DateTime(2000));
  await db.close();
  return rows;
}

void main() {
  // Absolute for the reason TASK-46/47's header gives: sqflite_common_ffi
  // resolves a relative path against its own directory and would quietly
  // create an empty database rather than fail.
  final exportPath = File(
    Platform.environment['CARD_SETTLEMENT_DB'] ?? '.private/transactions.db',
  ).absolute.path;

  /// Skips the calling test and returns true when there is no export to read.
  /// Call at the top of every test in this file, before touching the export.
  bool skipWithoutExport() {
    if (File(exportPath).existsSync()) return false;
    markTestSkipped(
      'No device export at $exportPath. Skipping so the suite stays green.',
    );
    return true;
  }

  // The owner's 13 real answers, verified below to settle exactly the spec's
  // ground truth (58 rows / Rs.7,47,129.31, zero innocent rows). Payment-app
  // names, not account or card identifiers -- already public in the plan.
  const confirmed = {
    'cred club',
    'cred',
    'cheq digital privat',
    'cheq digital private limi',
    'cheq digital private limited',
    'credclub',
    'amazon pay credit c',
    'cheq',
    'creditcard payment',
  };
  const declined = {
    'shree arbuda statio',
    'amazon',
    'amazon pay',
    'cred store',
  };

  test(
    'round 1 proposes the merchants the corpus pairs today, and only the '
    'genuinely new ones survive the owner\'s real 13 answers',
    () async {
      if (skipWithoutExport()) return;
      sqfliteFfiInit();
      final rows = await _corpus(exportPath);
      const finder = CardSettlementCandidateFinder();

      // See the module docstring: this is 12, not the spec's 8 -- `cheq` and
      // `creditcard payment` now pair directly instead of needing adjacency,
      // and 3 further merchants pair that the spec never mentions at all.
      // Two of those three are not named literally here (see the docstring);
      // asserted by count and superset instead of exact-set equality.
      final round1 = finder.find(rows, CardSettlementFronts.empty);
      expect(round1, hasLength(12));
      expect(
        round1.map((c) => c.merchantNorm).toSet(),
        containsAll({
          'cred club',
          'cred',
          'cheq digital privat',
          'cheq digital private limi',
          'cheq digital private limited',
          'credclub',
          'amazon pay credit c',
          'cheq',
          'creditcard payment',
          'milkbasket',
        }),
      );
      expect(
        round1.every((c) => c.source == CardSettlementCandidateSource.paired),
        isTrue,
      );

      // Apply the owner's real, already ground-truthed answers -- the same
      // `confirmed`/`declined` sets the settled-total and no-leak tests below
      // use. `cheq` and `creditcard payment` are already decided (confirmed)
      // so they do not reappear; `amazon`, `amazon pay` and `cred store` are
      // already decided (declined) so they do not reappear either. What
      // survives is exactly the 3 merchants nothing has ever answered --
      // proof, on live data rather than a fixture, that a decided merchant is
      // never re-proposed (Rule 3) and that these 3 are a genuinely open
      // question, not a fixture gap. Checked by count, by source, and by
      // exclusion from every merchant already decided -- not by naming the
      // two undisclosed ones.
      final groundTruth = CardSettlementFronts({
        for (final m in confirmed) m: true,
        for (final m in declined) m: false,
      });
      final stillUnanswered = finder.find(rows, groundTruth);
      expect(stillUnanswered, hasLength(3));
      expect(
        stillUnanswered.map((c) => c.merchantNorm),
        contains('milkbasket'),
      );
      expect(
        stillUnanswered.every(
          (c) => c.source == CardSettlementCandidateSource.paired,
        ),
        isTrue,
      );
      expect(
        stillUnanswered
            .map((c) => c.merchantNorm)
            .toSet()
            .intersection({...confirmed, ...declined}),
        isEmpty,
        reason: 'a merchant already decided must never be re-proposed',
      );
    },
  );

  test('the confirmed fronts settle 58 of the 59 real card payments', () async {
    if (skipWithoutExport()) return;
    sqfliteFfiInit();
    final rows = await _corpus(exportPath);

    final settled = rows.where((t) => MoneyLens.isCardSettlement(t, confirmed));

    expect(settled.length, 58);
    expect(
      settled.fold<int>(0, (sum, t) => sum + t.amountPaise),
      74712931, // Rs.7,47,129.31
    );
  });

  test('no declined merchant is ever excluded', () async {
    if (skipWithoutExport()) return;
    sqfliteFfiInit();
    final rows = await _corpus(exportPath);

    for (final merchant in declined) {
      final rowsFor = rows.where((t) => merchantFrontKey(t) == merchant);
      expect(rowsFor, isNotEmpty, reason: '$merchant should exist in corpus');
      expect(
        rowsFor.every((t) => !MoneyLens.isCardSettlement(t, confirmed)),
        isTrue,
        reason: '$merchant is real spending and must never be settled',
      );
    }
  });

  test('same-day pairing at Rs.500 finds 73 pairs today, not the spec\'s 37',
      () async {
    if (skipWithoutExport()) return;
    sqfliteFfiInit();
    final rows = await _corpus(exportPath);

    final pairs = const CardSettlementPairer().pairs(rows);

    // See the module docstring: 73, not 37. This is not corpus drift and not
    // explained by matching order, SmsLiveNormalizer, or the isCardBillPayment
    // wording widening -- all three were checked by hand and ruled out.
    expect(pairs, hasLength(73));
    for (final pair in pairs) {
      expect(pair.pointsPaise, inInclusiveRange(0, 50000));
      expect(pair.debit.txnLocalDate, pair.ack.txnLocalDate);
    }
  });

  test('August 2026 spend no longer carries a card bill payment', () async {
    if (skipWithoutExport()) return;
    sqfliteFfiInit();
    final rows = await _corpus(exportPath);

    final august = rows.where((t) => t.txnMonth == '2026-08');
    final leaked = august.where(
      (t) =>
          MoneyLens.isSpend(t, confirmed) &&
          merchantFrontKey(t) != null &&
          confirmed.contains(merchantFrontKey(t)),
    );

    expect(leaked, isEmpty);
  });
}
