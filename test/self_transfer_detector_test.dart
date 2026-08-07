// A transfer between the user's own two accounts is not consumption, but the
// bank never says so: the debit leg reads `Sent ... To <the holder's own name>`
// and the credit leg arrives as a separate alert on a different account. Only
// the pair together proves it.
//
// Measured on the owner's device (2,071 rows), the naive readings both fail:
//
//   payee name == the holder's name        5 hits, 2 of them real payments
//   same amount within +/-1 day, any acct  119 hits, 116 of them wrong
//
// Nearly all of that noise is one shape: a credit-card bill settlement, where
// the bank debit and the card's "payment received" credit are two legs of ONE
// event and match on amount, day and account by construction. Excluding card
// rows takes 119 down to 4.
//
// The last one is a coincidence no rule can see through - a ₹44,604 Flipkart
// purchase and an unrelated ₹44,604 reimbursement 12 minutes later - which is
// why the detector only ever proposes, and the user confirms.
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/self_transfer_detector.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _txn({
  required String smsId,
  required int amountPaise,
  required TransactionDirection direction,
  required String accountLast4,
  required DateTime date,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String body = 'Rs. debited from A/c',
  String? merchant,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: instrument,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: date,
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
  accountLast4: accountLast4,
);

void main() {
  // Shaped after a real pair from the owner's device: ₹50,000 left the HDFC
  // account and arrived in the Axis one the same afternoon, and the credit body
  // names HDFC as the source. Payee names and account tails are synthetic.
  final debit = _txn(
    smsId: 'debit-hdfc',
    amountPaise: 5000000,
    direction: TransactionDirection.debit,
    accountLast4: '7001',
    date: DateTime(2026, 1, 13, 14, 30),
    body: 'Sent [amount] From HDFC Bank A/C [account] To PAYEE NAME',
    merchant: 'payee name',
  );
  final credit = _txn(
    smsId: 'credit-axis',
    amountPaise: 5000000,
    direction: TransactionDirection.credit,
    accountLast4: '7002',
    date: DateTime(2026, 1, 13, 14, 49),
    body: '[amount] credited A/c no. [account] UPI/P2A/[number]/PAYEE/HDFC',
  );

  test('a bank debit met by a same-amount credit on another own account pairs',
      () {
    final found = const SelfTransferDetector().candidates([debit, credit]);

    expect(found, hasLength(1));
    expect(found.single.debit.smsId, 'debit-hdfc');
    expect(found.single.credit.smsId, 'credit-axis');
  });

  test('a credit-card bill settlement is not a transfer between accounts', () {
    // The shape behind 18 of the 21 cross-account matches on the device: one
    // settlement, announced twice. The bank debit leaves the Axis account,
    // the card acknowledges the same rupees on tail 7117, so amount, day and
    // "different account" all agree by construction.
    final billPayment = _txn(
      smsId: 'settle-bank',
      amountPaise: 1898000,
      direction: TransactionDirection.debit,
      accountLast4: '7002',
      date: DateTime(2021, 10, 6, 13),
      merchant: 'cred',
    );
    final cardAcknowledgement = _txn(
      smsId: 'settle-card',
      amountPaise: 1898000,
      direction: TransactionDirection.credit,
      accountLast4: '7117',
      date: DateTime(2021, 10, 6, 13, 5),
      instrument: PaymentInstrument.card,
      body: 'payment of [amount] towards your Axis Bank Credit Card '
          '[account] has been received',
    );

    expect(
      const SelfTransferDetector()
          .candidates([billPayment, cardAcknowledgement]),
      isEmpty,
    );
  });
}
