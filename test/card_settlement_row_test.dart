// Task 7 spends the pairing (`CardSettlementPairer`, Task 2) on the one
// surface the user actually reads: the activity row. A settlement debit alone
// carries no card number -- its `accountLast4` is the *savings* account -- so
// the subtitle used to say only "Settles a card bill · not spend". Joining the
// debit to the card's own acknowledgement (when one exists) lets the row say
// which card and how many reward points covered the gap.
//
// Fixtures reuse the owner's real 1 Aug 2026 CRED payment (see
// `card_settlement_pairer_test.dart`): Rs.2,282 left the bank, the card
// acknowledged Rs.2,307, Rs.25 came from CRED coins. `cheq-debit` is the other
// case that has to render correctly: a debit that is a settlement by its own
// wording (the self-evidencing body rule `MoneyLens.isCardSettlement` also
// checks) but has no acknowledgement anywhere in history to pair with -- so
// nothing may be invented for it. `cred-debit-no-card-ack` closes the third
// case, and it is not hypothetical: a genuine pair whose acknowledgement
// itself carries no card number. Task 6 hit exactly this on the review screen
// and shipped a literal "null" into a sentence the user reads -- collapsing
// `pair == null || pair.cardLast4 == null` down to just `pair == null` stays
// green everywhere else and only this fixture would catch it.
//
// `TxRow` carries no `smsId`, so rows are located by their unique rendered
// amount label -- the same string `real_insights.dart` builds via `inr()` --
// rather than by an id the production type does not expose.
import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/card_settlement_front_store.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/real_insights.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 8, 20);

final _state = const AppState().copyWith(currentBalance: '', salary: '');

ParsedTxn _txn({
  required String smsId,
  required int amountPaise,
  required String body,
  required DateTime date,
  TransactionDirection direction = TransactionDirection.debit,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String? merchant,
  String? accountLast4,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: instrument,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: date,
  accountLast4: accountLast4,
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: body,
  bodyHash: 'h',
  scanBatchId: 'b',
);

// The debit: Rs.2,282 left the bank, to a merchant the user confirmed is a
// card-bill front (`settlementFronts` below). `accountLast4` here is the
// *savings* account, not a card -- proving the subtitle cannot get "4321" from
// this row alone.
final _credDebit = _txn(
  smsId: 'cred-debit',
  amountPaise: 228200,
  date: DateTime(2026, 8, 1),
  merchant: 'CRED Club',
  accountLast4: '4501',
  body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\nTo CRED Club',
);

// The card's own acknowledgement of the same bill: Rs.2,307, card ending 4321.
// Same local day and within the pairer's Rs.500 cap, so it pairs with
// `_credDebit` -- Rs.25 (2500 paise) is the reward-point gap.
final _credAck = _txn(
  smsId: 'cred-ack',
  amountPaise: 230700,
  date: DateTime(2026, 8, 1),
  direction: TransactionDirection.credit,
  instrument: PaymentInstrument.card,
  accountLast4: '4321',
  body:
      'DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] RECEIVED TOWARDS '
      'YOUR CREDIT CARD ENDING WITH [number]',
);

// A Cheq bank debit that settles a card bill by its own wording (the
// "payment ... towards ... card" body rule `MoneyLens.isCardSettlement`
// matches with no confirmed front needed), on a different day from the only
// acknowledgement in history -- so it never pairs. Nothing may name a card for
// it.
final _cheqDebit = _txn(
  smsId: 'cheq-debit',
  amountPaise: 500000,
  date: DateTime(2026, 8, 5),
  merchant: 'Cheq',
  accountLast4: '4501',
  body:
      'Payment of Rs.5,000 towards your Cheq Credit Card debited from '
      'A/c XX4501',
);

// A genuine pair -- same local day as its acknowledgement, Rs.20 apart, well
// inside the pairer's Rs.500 cap -- whose acknowledgement itself carries no
// card number. The pair is known; the card is not, and none may be guessed.
final _credDebitNoCardAck = _txn(
  smsId: 'cred-debit-no-card-ack',
  amountPaise: 150000,
  date: DateTime(2026, 8, 10),
  merchant: 'CRED Club',
  accountLast4: '4501',
  body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\nTo CRED Club',
);
final _credAckNoCard = _txn(
  smsId: 'cred-ack-no-card',
  amountPaise: 152000,
  date: DateTime(2026, 8, 10),
  direction: TransactionDirection.credit,
  instrument: PaymentInstrument.card,
  // No accountLast4 -- the acknowledgement itself does not name the card.
  body:
      'DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] RECEIVED TOWARDS '
      'YOUR CREDIT CARD ENDING WITH [number]',
);

// The rendered amount label each fixture's activity row must carry --
// `real_insights.dart`'s `txRowFor` builds it as `'$sign${inr(amountPaise /
// 100.0)}'` -- used to find a row without `TxRow` needing to carry a `smsId`.
final _amountLabelBySmsId = {
  _credDebit.smsId: '-${inr(_credDebit.amountPaise / 100.0)}',
  _cheqDebit.smsId: '-${inr(_cheqDebit.amountPaise / 100.0)}',
  _credDebitNoCardAck.smsId: '-${inr(_credDebitNoCardAck.amountPaise / 100.0)}',
};

TxRow _activityRowFor(Insights insights, String smsId) {
  final label = _amountLabelBySmsId[smsId]!;
  for (final group in insights.dateGroups) {
    for (final row in group.items) {
      if (row.amount == label) return row;
    }
  }
  throw StateError('no activity row rendered for $smsId (amount $label)');
}

Set<String> _activityRowIds(Insights insights) {
  final renderedAmounts = {
    for (final group in insights.dateGroups)
      for (final row in group.items) row.amount,
  };
  return {
    for (final entry in _amountLabelBySmsId.entries)
      if (renderedAmounts.contains(entry.value)) entry.key,
  };
}

void main() {
  final insights = computeRealInsights(
    _state,
    snapshot: SmsAnalysisSnapshot.reduce(
      history: [
        _credDebit,
        _credAck,
        _cheqDebit,
        _credDebitNoCardAck,
        _credAckNoCard,
      ],
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: _now,
      settlementFronts: const CardSettlementFronts({'cred club': true}),
    ),
    nowOverride: _now,
  );

  test('a paired settlement row names the card and the points', () {
    final row = _activityRowFor(insights, 'cred-debit');

    expect(row.isCardSettlement, isTrue);
    expect(row.settlementCardLast4, '4321');
    expect(row.settlementPointsPaise, 2500);
    expect(row.subtitle, contains('4321'));
    expect(row.subtitle, contains('points'));
  });

  test('an unpaired settlement row names no card', () {
    // A debit that is a settlement in its own right, with no acknowledgement
    // anywhere in history. There is nothing to name, and nothing is invented.
    final row = _activityRowFor(insights, 'cheq-debit');

    expect(row.isCardSettlement, isTrue);
    expect(row.settlementCardLast4, isNull);
    expect(row.subtitle, 'Settles a card bill · not spend');
  });

  test(
    'a paired settlement row whose acknowledgement carried no card number '
    'still falls back',
    () {
      // The pair is real -- same day, Rs.20 apart, inside the cap -- but the
      // acknowledgement itself never named a card. Nothing may be guessed, and
      // nothing may render the absence as the literal string "null".
      final row = _activityRowFor(insights, 'cred-debit-no-card-ack');

      expect(row.isCardSettlement, isTrue);
      expect(row.settlementCardLast4, isNull);
      expect(row.subtitle, 'Settles a card bill · not spend');
      expect(row.subtitle, isNot(contains('null')));
    },
  );

  test('a settled row stays visible and out of the month total', () {
    expect(_activityRowIds(insights), contains('cred-debit'));
    // Two checks, not one: `spentThisMonthCount` is the exact int length of
    // the spend set -- it proves the fold ran over an empty list, not just
    // that it rounded to a display figure that reads as zero.
    // `spentThisMonthLabel` is the formatted string the user actually sees --
    // `real_insights.dart` derives it from the same paise total `inr()`
    // rounds to the nearest rupee, so the label alone would still read "₹0"
    // for anything in (-50, 50) paise. Both together prove the exact claim.
    expect(insights.spentThisMonthCount, 0);
    expect(insights.spentThisMonthLabel, inr(0));
  });
}
