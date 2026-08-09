// The hardcoded merchant list is gone. What excludes a bank debit now is the
// user's own answer, and nothing else.
//
// The list it replaces was wrong in both directions on the owner's device: it
// missed Rs.5,44,676 across 21 rows -- Cheq Digital alone was Rs.5,35,438 --
// while `\bcred\b` erased Rs.599 of real CRED Store shopping.
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/money_lens.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _bankDebit({
  required int amountPaise,
  required String merchant,
  String? body,
}) => ParsedTxn(
  smsId: 'debit:$merchant:$amountPaise',
  sender: 'VM-HDFCBK-S',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: DateTime(2026, 8, 1),
  accountLast4: '4501',
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted:
      body ?? 'Sent [amount] From HDFC Bank A/C [account] To $merchant',
  bodyHash: 'h',
  scanBatchId: 'b',
);

void main() {
  const noFronts = <String>{};

  test('the amount is never consulted', () {
    // The user's two scenarios. A bill of Rs.100 paid in full, and the same
    // bill paid as Rs.90 after Rs.10 of CRED coins. One code path.
    final full = _bankDebit(amountPaise: 10000, merchant: 'CRED Club');
    final discounted = _bankDebit(amountPaise: 9000, merchant: 'CRED Club');

    expect(MoneyLens.isCardSettlement(full, {'cred club'}), isTrue);
    expect(MoneyLens.isCardSettlement(discounted, {'cred club'}), isTrue);
    expect(MoneyLens.isSpend(full, {'cred club'}), isFalse);
    expect(MoneyLens.isSpend(discounted, {'cred club'}), isFalse);
    expect(MoneyLens.isEverydayCashSpend(discounted, {'cred club'}), isFalse);
  });

  test('a confirmed front settles with no acknowledgement anywhere', () {
    // Some of what a confirmed front settles has no card-side ack to pair
    // with at all -- re-measured 2026-08-09 at 6 of the 58 settled rows,
    // Rs.38,036.98 (see sms_storage_schema.dart's
    // createCardSettlementFrontsTable docstring; the spec's original
    // Rs.3,17,559 does not survive the corpus re-measurement documented in
    // card_settlement_pairer.dart). Only a remembered merchant reaches rows
    // like these.
    final txn = _bankDebit(amountPaise: 19041680, merchant: 'Cheq');

    expect(MoneyLens.isSpend(txn, {'cheq'}), isFalse);
    expect(MoneyLens.isSpend(txn, noFronts), isTrue);
  });

  test('a prefix of a confirmed front is still spend', () {
    // `amazon` is a proper prefix of `amazon pay credit c`. Confirming the
    // payment front must not swallow ordinary Amazon shopping.
    const fronts = {'amazon pay credit c'};
    for (final merchant in ['Amazon', 'Amazon India', 'Amazon Pay']) {
      final txn = _bankDebit(amountPaise: 62800, merchant: merchant);
      expect(
        MoneyLens.isCardSettlement(txn, fronts),
        isFalse,
        reason: '$merchant must stay spend',
      );
      expect(MoneyLens.isSpend(txn, fronts), isTrue);
    }
  });

  test('a sibling of a confirmed front is still spend', () {
    // The Rs.599 the old `\bcred\b` rule erased.
    final txn = _bankDebit(amountPaise: 59900, merchant: 'CRED Store');

    expect(MoneyLens.isCardSettlement(txn, {'cred club'}), isFalse);
    expect(MoneyLens.isSpend(txn, {'cred club'}), isTrue);
    expect(MoneyLens.isEverydayCashSpend(txn, {'cred club'}), isTrue);
  });

  test('the body rule still settles without any confirmed front', () {
    // Self-evidencing, and measured at zero false positives. It carries the
    // settlement debits that name the card in words, whatever the merchant.
    final txn = _bankDebit(
      amountPaise: 4500000,
      merchant: 'HDFC',
      body:
          'Payment of Rs.45,000 towards your HDFC Credit Card debited from '
          'A/c XX1234',
    );

    expect(MoneyLens.isCardSettlement(txn, noFronts), isTrue);
    expect(MoneyLens.isSpend(txn, noFronts), isFalse);
  });

  test('an unconfirmed payment front is counted as spend, loudly', () {
    // Between upgrade and the user's first answer, a front is not yet a front.
    // This is the interim the release constraint covers -- it must be a visible
    // miscount, not a silent one.
    final txn = _bankDebit(amountPaise: 228200, merchant: 'CRED Club');

    expect(MoneyLens.isSpend(txn, noFronts), isTrue);
  });

  test('merchant matching is case and whitespace insensitive', () {
    final txn = _bankDebit(amountPaise: 100000, merchant: '  CRED   Club  ');

    expect(MoneyLens.isCardSettlement(txn, {'cred club'}), isTrue);
  });

  test('a credit is never a settlement', () {
    final txn = ParsedTxn(
      smsId: 'credit-1',
      sender: 'VM-HDFCBK-S',
      direction: TransactionDirection.credit,
      instrument: PaymentInstrument.bank,
      type: TxnType.upi,
      amountPaise: 100000,
      txnDate: DateTime(2026, 8, 1),
      merchant: 'CRED Club',
      payeeType: PayeeType.merchant,
      categoryKey: 'other',
      confidence: 0.9,
      reviewStatus: ReviewStatus.autoAdded,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted: 'Received [amount] From CRED Club',
      bodyHash: 'h',
      scanBatchId: 'b',
    );

    expect(MoneyLens.isCardSettlement(txn, {'cred club'}), isFalse);
  });

  test('both rails stay out while the purchase they settle stays in', () {
    // The whole point of the feature, in one assertion. Three SMS for two
    // events: a Rs.500 purchase in August, then in September the bank debit
    // and the card's acknowledgement of the bill that paid for it.
    const fronts = {'cred club'};
    final purchase = ParsedTxn(
      smsId: 'purchase',
      sender: 'VM-HDFCBK-S',
      direction: TransactionDirection.debit,
      instrument: PaymentInstrument.card,
      type: TxnType.pos,
      amountPaise: 50000,
      txnDate: DateTime(2026, 8, 6),
      accountLast4: '4321',
      merchant: 'Swiggy',
      payeeType: PayeeType.merchant,
      categoryKey: 'food',
      confidence: 0.9,
      reviewStatus: ReviewStatus.autoAdded,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted:
          'Spent [amount] On HDFC Bank Card [account] At SWIGGY. Avl Lmt '
          '[amount]',
      bodyHash: 'h',
      scanBatchId: 'b',
    );
    final bankLeg = _bankDebit(amountPaise: 228200, merchant: 'CRED Club');
    final cardLeg = ParsedTxn(
      smsId: 'ack',
      sender: 'VM-HDFCBK-S',
      direction: TransactionDirection.credit,
      instrument: PaymentInstrument.card,
      type: TxnType.pos,
      amountPaise: 230700,
      txnDate: DateTime(2026, 9, 20),
      accountLast4: '4321',
      payeeType: PayeeType.merchant,
      categoryKey: 'other',
      confidence: 0.9,
      reviewStatus: ReviewStatus.autoAdded,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted:
          'DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] RECEIVED TOWARDS '
          'YOUR CREDIT CARD ENDING WITH [number]',
      bodyHash: 'h',
      scanBatchId: 'b',
    );

    // The purchase counts, on its own date, as spend.
    expect(MoneyLens.isSpend(purchase, fronts), isTrue);
    // Neither leg of the settlement does.
    expect(MoneyLens.isSpend(bankLeg, fronts), isFalse);
    expect(
      MoneyLens.isSpend(cardLeg, fronts),
      isFalse,
      reason: 'a payment acknowledgement is not a refund',
    );
    expect(MoneyLens.isEverydayCashSpend(bankLeg, fronts), isFalse);
  });
}
