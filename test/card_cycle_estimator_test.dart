import 'package:expense_insight/data/card_models.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_cycle_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn cardTxn({
  required int amountPaise,
  required DateTime date,
  TransactionDirection direction = TransactionDirection.debit,
  String cardLast4 = '4321',
  String smsId = 'sms',
  String rawBodyRedacted = 'redacted',
  String categoryKey = 'shopping',
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK',
  direction: direction,
  instrument: PaymentInstrument.card,
  type: TxnType.pos,
  amountPaise: amountPaise,
  txnDate: date,
  accountLast4: cardLast4,
  merchant: 'Amazon',
  payeeType: PayeeType.merchant,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: rawBodyRedacted,
  bodyHash: 'h',
  scanBatchId: 'b',
);

const cycle = CardCycle(
  cardLast4: '4321',
  issuer: 'HDFC',
  cycleStartDay: 6,
  statementDay: 3,
  dueDay: 20,
  paymentAccountHint: '1234',
  confidence: 0.9,
);

void main() {
  const estimator = CardCycleEstimator();

  group('cycle_spend_seen', () {
    test('is Σ purchases − Σ card-routed refunds', () {
      final estimate = estimator.estimate(
        [
          cardTxn(amountPaise: 300000, date: DateTime(2026, 8, 10), smsId: 'p1'),
          cardTxn(amountPaise: 200000, date: DateTime(2026, 8, 12), smsId: 'p2'),
          cardTxn(
            amountPaise: 100000,
            date: DateTime(2026, 8, 15),
            direction: TransactionDirection.credit,
            smsId: 'r1',
          ),
        ],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
      );

      expect(estimate.cycleSpendSeenPaise, 400000);
      expect(estimate.observedPurchasesPaise, 500000);
      expect(estimate.cardRefundsPaise, 100000);
    });

    // A bill payment and a merchant refund are both card credits, but only a
    // refund cancels spend. Treating a payment as a refund makes paying the
    // bill look like you spent less, understating the next statement.
    // Bodies are the real device shape (see TASK-28).
    test('a bill payment is not a refund and does not cancel card spend', () {
      final estimate = estimator.estimate(
        [
          cardTxn(amountPaise: 500000, date: DateTime(2026, 8, 10), smsId: 'p'),
          cardTxn(
            amountPaise: 100000,
            date: DateTime(2026, 8, 15),
            direction: TransactionDirection.credit,
            smsId: 'pay',
            categoryKey: 'income',
            rawBodyRedacted: 'DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] '
                'RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH [number] ON '
                '1-8-[number].YOUR AVAILABLE LIMIT IS [amount]',
          ),
        ],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
      );

      expect(estimate.cardRefundsPaise, 0);
      expect(estimate.cycleSpendSeenPaise, 500000);
    });

    test('the ICICI/BBPS bill-payment wording is also not a refund', () {
      final estimate = estimator.estimate(
        [
          cardTxn(amountPaise: 500000, date: DateTime(2026, 8, 10), smsId: 'p'),
          cardTxn(
            amountPaise: 100000,
            date: DateTime(2026, 8, 15),
            direction: TransactionDirection.credit,
            smsId: 'pay',
            categoryKey: 'income',
            rawBodyRedacted: 'Payment of [amount] has been received on your '
                'ICICI Bank Credit Card [account] through Bharat Bill Payment '
                'System on 01-AUG-26.',
          ),
        ],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
      );

      expect(estimate.cardRefundsPaise, 0);
      expect(estimate.cycleSpendSeenPaise, 500000);
    });

    test('a genuine refund still cancels spend', () {
      final estimate = estimator.estimate(
        [
          cardTxn(amountPaise: 500000, date: DateTime(2026, 8, 10), smsId: 'p'),
          cardTxn(
            amountPaise: 100000,
            date: DateTime(2026, 8, 15),
            direction: TransactionDirection.credit,
            smsId: 'r',
            categoryKey: 'refund',
            rawBodyRedacted: 'Refund of [amount] processed to your HDFC Bank '
                'Card [account] by AMAZON.',
          ),
        ],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
      );

      expect(estimate.cardRefundsPaise, 100000);
      expect(estimate.cycleSpendSeenPaise, 400000);
    });
  });

  group('statement residual and proxy', () {
    test('no per-purchase SMS ⇒ statement total is the expense proxy', () {
      final estimate = estimator.estimate(
        const [],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
        statementTotalPaise: 1000000,
      );

      expect(estimate.observedPurchasesPaise, 0);
      expect(estimate.statementResidualPaise, 1000000);
      expect(estimate.statementEventAmountPaise, 1000000);
    });

    test('partial purchase coverage uses residual, not statement + purchases', () {
      final estimate = estimator.estimate(
        [cardTxn(amountPaise: 300000, date: DateTime(2026, 8, 10))],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
        statementTotalPaise: 1000000,
      );

      // residual = statement − observed purchases + observed card refunds
      expect(estimate.statementResidualPaise, 700000);
      // The card amount is statement (1,000,000), NOT statement + purchases.
      expect(
        estimate.observedPurchasesPaise + estimate.statementResidualPaise!,
        1000000,
      );
    });

    test('card-routed refund reduces statement/outstanding, not bank cash', () {
      final estimate = estimator.estimate(
        [
          cardTxn(amountPaise: 500000, date: DateTime(2026, 8, 10), smsId: 'p'),
          cardTxn(
            amountPaise: 100000,
            date: DateTime(2026, 8, 15),
            direction: TransactionDirection.credit,
            smsId: 'r',
          ),
        ],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
        statementTotalPaise: 600000,
      );

      expect(estimate.statementResidualPaise, 200000); // 600k − 500k + 100k
      expect(estimate.cycleSpendSeenPaise, 400000); // 500k − 100k
      // Refund never becomes a bank inflow event from the estimator.
      expect(estimate.direction, LedgerDirection.outflow);
    });
  });

  group('payment status', () {
    test('partial payment produces an outstanding quantified obligation', () {
      final estimate = estimator.estimate(
        const [],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
        statementTotalPaise: 1000000,
        amountPaidPaise: 400000,
      );

      expect(estimate.paymentStatus, ReconciliationPaymentStatus.partial);
      expect(estimate.outstandingPaise, 600000);
      expect(estimate.statementEventAmountPaise, 600000);
    });

    test('full payment marks the statement paid', () {
      final estimate = estimator.estimate(
        const [],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
        statementTotalPaise: 1000000,
        amountPaidPaise: 1000000,
      );

      expect(estimate.paymentStatus, ReconciliationPaymentStatus.paid);
      expect(estimate.outstandingPaise, 0);
    });
  });

  group('due date and cycle setup', () {
    test('known cycle dates the statement on the due day', () {
      final estimate = estimator.estimate(
        [cardTxn(amountPaise: 300000, date: DateTime(2026, 8, 10))],
        cycle: cycle,
        statementMonth: DateTime(2026, 8),
      );

      expect(estimate.dueDate, DateTime(2026, 8, 20));
      expect(estimate.needsCycleSetup, isFalse);
      expect(estimate.cardCycleKey, 'card:4321:2026-08');
    });

    test('unknown cycle emits a set-card-cycle coverage need without a due date', () {
      final estimate = estimator.estimate(
        [cardTxn(amountPaise: 300000, date: DateTime(2026, 8, 10))],
      );

      expect(estimate.needsCycleSetup, isTrue);
      expect(estimate.dueDate, isNull);
      expect(estimate.cardLast4, '4321');
    });

    test('dueDay 31 clamps to the last day of a short statement month', () {
      final estimate = estimator.estimate(
        [cardTxn(amountPaise: 300000, date: DateTime(2026, 2, 10))],
        cycle: const CardCycle(
          cardLast4: '4321',
          issuer: 'HDFC',
          cycleStartDay: 6,
          statementDay: 3,
          dueDay: 31,
          paymentAccountHint: '1234',
          confidence: 0.9,
        ),
        statementMonth: DateTime(2026, 2),
      );

      expect(estimate.dueDate, DateTime(2026, 2, 28));
    });

    test('dueDay 30 clamps to 28 Feb rather than rolling into March', () {
      final estimate = estimator.estimate(
        [cardTxn(amountPaise: 300000, date: DateTime(2026, 2, 10))],
        cycle: const CardCycle(
          cardLast4: '4321',
          issuer: 'HDFC',
          cycleStartDay: 6,
          statementDay: 3,
          dueDay: 30,
          paymentAccountHint: '1234',
          confidence: 0.9,
        ),
        statementMonth: DateTime(2026, 2),
      );

      expect(estimate.dueDate, DateTime(2026, 2, 28));
    });
  });
}
