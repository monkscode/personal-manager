// One card-bill payment reaches the phone as up to two SMS on two rails: the
// savings-account debit, and the card's own acknowledgement. Only the
// acknowledgement names the card; only the debit names the money that actually
// left the bank. Pairing them is what lets the app say which card a CRED or
// Cheq payment settled, and how much of the bill was paid with reward points.
//
// The window is same-day with a Rs.500 cap. The design spec originally
// claimed this was the only setting measured at 100% precision over the
// owner's 1,026 bank debits (37 pairs, 0 false positives), and that +-2 days
// drops to 95% by wrongly swallowing two ordinary payees: Corner Store Rs.65
// and a private payee Rs.30. That measurement does not reproduce -- the
// same-day/Rs.500 setting actually returns 73 pairs on the identical corpus,
// not 37, and precision on the 73 is UNMEASURED (nobody has hand-labelled
// them). The +-2 day row, including the Corner Store and private-payee
// examples, was not re-checked either way. See `CardSettlementPairer`'s
// module docstring (`lib/services/card_settlement_pairer.dart`) for the full
// correction and the evidence trail. No precision percentage may be quoted
// for either window until a fresh measurement produces one.
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_settlement_pairer.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _txn({
  required int amountPaise,
  required String body,
  required DateTime date,
  TransactionDirection direction = TransactionDirection.debit,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String? merchant,
  String? accountLast4,
  String? smsId,
}) => ParsedTxn(
  smsId: smsId ?? 'sms:${body.hashCode}:$amountPaise:${date.day}',
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

ParsedTxn _cred(int paise, DateTime date, {String? smsId}) => _txn(
  amountPaise: paise,
  date: date,
  merchant: 'CRED Club',
  accountLast4: '4501',
  smsId: smsId,
  body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\nTo CRED Club',
);

ParsedTxn _ack(int paise, DateTime date, String cardLast4, {String? smsId}) =>
    _txn(
      amountPaise: paise,
      date: date,
      direction: TransactionDirection.credit,
      instrument: PaymentInstrument.card,
      accountLast4: cardLast4,
      smsId: smsId,
      body:
          'DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] RECEIVED TOWARDS '
          'YOUR CREDIT CARD ENDING WITH [number]',
    );

void main() {
  const pairer = CardSettlementPairer();

  test('a same-day debit pairs with the acknowledgement it settled', () {
    // The owner's real 1 Aug 2026 payment: Rs.2,282 left the bank, the card
    // acknowledged Rs.2,307, and Rs.25 came from CRED coins.
    final debit = _cred(228200, DateTime(2026, 8, 1));
    final ack = _ack(230700, DateTime(2026, 8, 1), '4321');

    final pairs = pairer.pairs([debit, ack]);

    expect(pairs, hasLength(1));
    expect(pairs.single.debit.smsId, debit.smsId);
    expect(pairs.single.cardLast4, '4321');
    expect(pairs.single.pointsPaise, 2500);
  });

  test('an exact-amount payment pairs with no points', () {
    final pairs = pairer.pairs([
      _cred(1118000, DateTime(2025, 7, 28)),
      _ack(1118000, DateTime(2025, 7, 28), '7110'),
    ]);

    expect(pairs.single.pointsPaise, 0);
  });

  test('a debit a day away from the acknowledgement does not pair', () {
    // Corner Store Rs.65 on 9 Nov 2024 sits one day from a Rs.115
    // acknowledgement. The design spec claimed a +-2 day window would wrongly
    // erase it as a card payment -- unverified by this branch's corpus
    // re-measurement (see CardSettlementPairer's module docstring). This test
    // only needs the same-day window to reject it, which does not depend on
    // that +-2 day claim being true.
    final pairs = pairer.pairs([
      _txn(
        amountPaise: 6500,
        date: DateTime(2024, 11, 9),
        merchant: 'Corner Store',
        body: 'Sent [amount] To Corner Store',
      ),
      _ack(11500, DateTime(2024, 11, 10), '7110'),
    ]);

    expect(pairs, isEmpty);
  });

  test('a gap wider than Rs.500 does not pair', () {
    final pairs = pairer.pairs([
      _cred(100000, DateTime(2026, 8, 1)),
      _ack(160000, DateTime(2026, 8, 1), '4321'),
    ]);

    expect(pairs, isEmpty);
  });

  test('an acknowledgement smaller than the debit does not pair', () {
    // Points only ever reduce what leaves the bank, so the card can never
    // acknowledge less than the debit. A smaller ack is a different event.
    final pairs = pairer.pairs([
      _cred(230700, DateTime(2026, 8, 1)),
      _ack(228200, DateTime(2026, 8, 1), '4321'),
    ]);

    expect(pairs, isEmpty);
  });

  test('the duplicate HDFC acknowledgement is consumed once', () {
    // HDFC sends the same payment twice: "RECEIVED TOWARDS" on the day, and
    // "was credited to your card ... value Date" the day after. Two
    // acknowledgements, one payment.
    final pairs = pairer.pairs([
      _cred(118100, DateTime(2026, 6, 29), smsId: 'debit-a'),
      _ack(119600, DateTime(2026, 6, 29), '4321', smsId: 'ack-a'),
      _txn(
        amountPaise: 119600,
        date: DateTime(2026, 6, 30),
        direction: TransactionDirection.credit,
        instrument: PaymentInstrument.card,
        accountLast4: '4321',
        smsId: 'ack-b',
        body:
            'HDFC Bank Cardmember, Online Payment of [amount] vide [ref] was '
            'credited to your card ending [account] On 29/JUN/[number]',
      ),
    ]);

    expect(pairs, hasLength(1));
    expect(pairs.single.pointsPaise, 1500);
  });

  test('one acknowledgement is claimed by only one debit', () {
    final pairs = pairer.pairs([
      _cred(228200, DateTime(2026, 8, 1), smsId: 'debit-a'),
      _cred(228300, DateTime(2026, 8, 1), smsId: 'debit-b'),
      _ack(230700, DateTime(2026, 8, 1), '4321'),
    ]);

    expect(pairs, hasLength(1));
    // Smallest gap wins: Rs.2,283 is Rs.24 away, Rs.2,282 is Rs.25 away.
    expect(pairs.single.debit.smsId, 'debit-b');
  });

  test('a card refund is not an acknowledgement', () {
    // A merchant refund credits the card too, and must keep netting against
    // spend rather than closing a bill.
    final pairs = pairer.pairs([
      _cred(50000, DateTime(2026, 8, 1)),
      _txn(
        amountPaise: 50000,
        date: DateTime(2026, 8, 1),
        direction: TransactionDirection.credit,
        instrument: PaymentInstrument.card,
        accountLast4: '4321',
        body:
            'Dear Customer, Refund of [amount] from FLIPKART PAYMENTS has been '
            'credited to your Credit Card [account]',
      ),
    ]);

    expect(pairs, isEmpty);
  });
}
