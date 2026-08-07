import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/real_insights.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_cycle_estimator.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/money_lens.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

// "Spent this month" must reflect genuine consumption only — matching how
// leading trackers separate spend from cash withdrawals, investments,
// credit-card purchases and not-yet-completed auto-pay notices. Bodies below
// are redacted forms of the user's real device messages.

final _now = DateTime(2026, 8, 1);

final _state = const AppState().copyWith(currentBalance: '', salary: '');

const _salary = SalaryProfile(
  confidence: SalaryConfidence.detectedStable,
  basePaise: 8500000,
  expectedDay: 10,
);

ParsedTxn _txn({
  required int amountPaise,
  required String body,
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.pos,
  PaymentInstrument instrument = PaymentInstrument.bank,
  PayeeType payeeType = PayeeType.unknown,
  DateTime? date,
  String? merchant,
  String categoryKey = 'other',
  String? smsId,
  ReviewStatus reviewStatus = ReviewStatus.autoAdded,
  String? supersededBySmsId,
}) => ParsedTxn(
  smsId: smsId ?? 'sms:${body.hashCode}:$amountPaise',
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 8, 5),
  merchant: merchant,
  payeeType: payeeType,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: reviewStatus,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: body,
  bodyHash: 'h',
  scanBatchId: 'b',
  supersededBySmsId: supersededBySmsId,
);

SmsAnalysisSnapshot _snapshot(List<ParsedTxn> currentMonthTxns) =>
    SmsAnalysisSnapshot(
      targetMonth: DateTime(2026, 8),
      hasData: true,
      commitments: const [],
      reviewCandidates: const [],
      salary: _salary,
      otherIncome: const [],
      seasonal: const SeasonalEstimate(targetMonth: 8, byCategory: {}),
      reconciliationItems: const [],
      cards: const [],
      currentMonthTxns: currentMonthTxns,
      allTxns: currentMonthTxns,
      yearOverYear: const {},
      cashLevel: CashCoverageLevel.none,
      cashDrainRatio: 0,
      currentMonthAtmPaise: 0,
      obligations: const [],
      reservePlan: const ReservePlan.empty(),
      riskDecisions: const [],
    );

// Real consumption that must be counted.
final _swiggy = _txn(
  amountPaise: 250000,
  body:
      'Rs.2500 spent on HDFC Bank Card x3333 at RAZ*SWIGGY on 05-08-26:22:03:27.Not U?',
);
// Cash withdrawal mis-tagged as POS because the body names the debit card.
final _cashOut = _txn(
  amountPaise: 2000000,
  body:
      'Rs.20000 withdrawn from HDFC Bank Card x2222 at MAIN STREET ATM on 05-08-26 Avl bal: 33333.00',
);
// Recurring SIP auto-debit via a mutual-fund clearing house.
final _sip = _txn(
  amountPaise: 1000000,
  type: TxnType.other,
  body:
      'UPDATE: Rs.10000 debited from HDFC Bank ac on 05-AUG-26. Info: ACH D- GROWW INVEST TECH PR',
);
// Credit-card purchase (reports available *limit*, not balance).
final _creditCard = _txn(
  amountPaise: 1055000,
  body:
      'Rs.10550 spent on ICICI Bank Card xx7108 at SANSKRUTIK. Avl Lmt: Rs.95500',
);
// Future auto-pay mandate notice ("will be deducted") — money not yet gone.
final _mandate = _txn(
  amountPaise: 199900,
  type: TxnType.upi,
  body:
      'E-Mandate! Rs.1999 will be deducted on 11/08/26 For Google Asia Pacific Pte.Ltd',
);
// A credit-card bill-due reminder ("is due for payment") — an obligation, not
// a completed debit.
final _billDue = _txn(
  amountPaise: 4225800,
  type: TxnType.other,
  body: 'Rs.42258 is due for payment on 04-09-26 towards Axis Bank CC no. xx',
);
final _transfer = _txn(
  amountPaise: 500000,
  type: TxnType.transfer,
  body: 'Rs.5000 transferred to ac xx via NEFT',
);
final _selfTransfer = _txn(
  amountPaise: 300000,
  type: TxnType.upi,
  payeeType: PayeeType.selfTransfer,
  body: 'Rs.3000 sent to your own account',
);
final _refund = _txn(
  amountPaise: 800000,
  direction: TransactionDirection.credit,
  body: 'Rs.8000 credited to HDFC Bank ac',
);

void main() {
  group('Spent this month counts genuine consumption only', () {
    test('excludes cash, investments, mandates, transfers', () {
      final i = computeRealInsights(
        _state,
        snapshot: _snapshot([
          _swiggy,
          _cashOut,
          _sip,
          _creditCard,
          _mandate,
          _billDue,
          _transfer,
          _selfTransfer,
          _refund,
        ]),
        nowOverride: _now,
      );

      // The Swiggy debit and the ₹10,550 card purchase. The card purchase used
      // to be excluded here — it is not a bank outflow — which put it in the
      // Transactions list and in no total at all. Spec A moves it into the
      // month it was made.
      expect(i.spentThisMonthCount, 2);
      expect(i.spentThisMonthLabel, inr(13050));
    });

    test('sums multiple genuine debits and counts them', () {
      final rent = _txn(
        amountPaise: 1800000,
        body: 'Rs.18000 debited from HDFC Bank ac towards rent',
      );
      final i = computeRealInsights(
        _state,
        snapshot: _snapshot([_swiggy, rent, _cashOut, _sip]),
        nowOverride: _now,
      );

      expect(i.spentThisMonthCount, 2);
      expect(i.spentThisMonthLabel, inr(20500));
    });

    test(
      'an all-excluded month reports zero spend, not the raw debit total',
      () {
        // `_creditCard` is deliberately not here any more: a card purchase is
        // spend under Spec A, so a month containing one is not an all-excluded
        // month.
        final i = computeRealInsights(
          _state,
          snapshot: _snapshot([_cashOut, _sip, _mandate]),
          nowOverride: _now,
        );

        expect(i.spentThisMonthCount, 0);
        expect(i.spentThisMonthLabel, inr(0));
      },
    );
  });

  _cardSettlementClassification();
  _accrualPlacement();
  _refundNetting();
  _planningBaseline();
  _trendChartSingleLens();
  _recurringDepositClassification();
}

// Bodies in their stored (redacted) form, which is what both lenses read.
const _kCardPurchaseBody =
    'Rs.[amount] spent on HDFC Bank Card [account] at AMAZON. Avl Lmt: '
    '[amount]';
const _kSettlementBody =
    'Payment of [amount] towards your HDFC Credit Card debited from A/c '
    '[account]';

SmsAnalysisSnapshot _reduced(List<ParsedTxn> history, DateTime now) =>
    SmsAnalysisSnapshot.reduce(
      history: history,
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: now,
    );

ParsedTxn _cardPurchase({
  required int amountPaise,
  required DateTime date,
  required String smsId,
  String categoryKey = 'shopping',
}) => _txn(
  amountPaise: amountPaise,
  instrument: PaymentInstrument.card,
  merchant: 'amazon',
  categoryKey: categoryKey,
  date: date,
  smsId: smsId,
  body: _kCardPurchaseBody,
);

ParsedTxn _cardRefund({
  required int amountPaise,
  required DateTime date,
  required String smsId,
}) => _txn(
  amountPaise: amountPaise,
  direction: TransactionDirection.credit,
  instrument: PaymentInstrument.card,
  merchant: 'amazon',
  categoryKey: 'shopping',
  date: date,
  smsId: smsId,
  body: 'Rs.400 refunded to your HDFC Bank Card [account]',
);

// ---------------------------------------------------------------------------
// The spend lens (Spec A Part 1). A card purchase counts as spend in the month
// it was made; a card bill payment stops counting as spend anywhere.
//
// These two tests come first because each pins a rule the design got wrong
// once. Neither can be satisfied by a rule table keyed on `instrument`, and
// neither can be satisfied by a substring match on the merchant.
// ---------------------------------------------------------------------------
void _cardSettlementClassification() {
  group('MoneyLens.isCardSettlement keys on the body, not the instrument', () {
    test('a settlement stored as a card row is not spend on either lens', () {
      // `_cardMarker` fires on the bare phrase `credit card`, so the bank's own
      // settlement debit is stored as `instrument: card`. A rule table that
      // reads "card instrument + debit = purchase" therefore counts the bill
      // payment as the very spend this work removes.
      final txn = const SmsTransactionParser().parseOne(
        RawSms(
          providerId: 'settlement-1',
          sender: 'VM-HDFCBK',
          body:
              'Payment of Rs.45,000 towards your HDFC Credit Card debited '
              'from A/c XX1234',
          receivedAt: DateTime(2026, 9, 20),
        ),
        scanBatchId: 'scan',
        bodyHashSalt: 'test-salt',
      )!;

      // The stored shape, asserted rather than assumed.
      expect(txn.instrument, PaymentInstrument.card);
      expect(txn.direction, TransactionDirection.debit);

      expect(MoneyLens.isCardSettlement(txn), isTrue);
      expect(MoneyLens.isSpend(txn), isFalse);
      expect(MoneyLens.isEverydayCashSpend(txn), isFalse);
    });
  });

  group('MoneyLens.isCardSettlement matches whole words only', () {
    ParsedTxn debitTo(String merchant) => _txn(
      amountPaise: 250000,
      merchant: merchant,
      body: 'Rs.2500 debited from HDFC Bank ac',
      smsId: 'sms:$merchant',
    );

    test('an ordinary merchant whose name contains "cred" is still spend', () {
      // `_norm` is lowercase plus whitespace collapse, so a substring test
      // matched SACRED HEART SCHOOL. Under this change that would delete real
      // money from the user's spend total.
      for (final name in const [
        'SACRED HEART SCHOOL',
        'INCREDIBLE INDIA',
        'CREDAI',
      ]) {
        final txn = debitTo(name);
        expect(MoneyLens.isCardSettlement(txn), isFalse, reason: name);
        expect(MoneyLens.isSpend(txn), isTrue, reason: name);
        expect(MoneyLens.isEverydayCashSpend(txn), isTrue, reason: name);
      }
    });

    test('a debit to CRED is a settlement on both lenses', () {
      final txn = debitTo('CRED');
      expect(MoneyLens.isCardSettlement(txn), isTrue);
      expect(MoneyLens.isSpend(txn), isFalse);
      expect(MoneyLens.isEverydayCashSpend(txn), isFalse);
    });
  });

  group('the two card-credit classifiers do not collide', () {
    // Both a merchant refund and the holder's own bill payment arrive as a
    // credit on the card, so only the wording separates them. Reading the
    // payment as a refund would make settling a ₹45,000 bill look like ₹45,000
    // of spend cancelled.
    final paymentReceived = _txn(
      amountPaise: 4500000,
      direction: TransactionDirection.credit,
      instrument: PaymentInstrument.card,
      smsId: 'payment-received',
      body:
          'Dear Cardmember, Payment of [amount] received towards your Credit '
          'Card ending [account]',
    );

    test('a card-side payment credit is not spend, and not a settlement', () {
      expect(isCardBillPayment(paymentReceived), isTrue);
      // `isCardSettlement` names the *debit* that leaves the bank. This is the
      // card's acknowledgement of the same event, and counting both is the
      // double count.
      expect(MoneyLens.isCardSettlement(paymentReceived), isFalse);
      expect(MoneyLens.isSpend(paymentReceived), isFalse);
      expect(MoneyLens.isEverydayCashSpend(paymentReceived), isFalse);
    });

    test('and it is not a refund to the cycle estimator either', () {
      final estimate = const CardCycleEstimator().estimate([paymentReceived]);
      expect(estimate.cardRefundsPaise, 0);
    });
  });

  group('the spend lens conserves what the cycle estimator observed', () {
    test('Σ signed spend equals purchases minus refunds', () {
      final cardTxns = [
        _cardPurchase(
          amountPaise: 100000,
          date: DateTime(2026, 8, 4),
          smsId: 'p1',
        ),
        _cardPurchase(
          amountPaise: 250000,
          date: DateTime(2026, 8, 9),
          smsId: 'p2',
        ),
        _cardRefund(amountPaise: 40000, date: DateTime(2026, 8, 11), smsId: 'r1'),
        // A cash advance is excluded by both sides — the estimator drops
        // `type: atm` from purchases and the lens leaves it to the ATM path.
        _txn(
          amountPaise: 500000,
          instrument: PaymentInstrument.card,
          type: TxnType.atm,
          date: DateTime(2026, 8, 12),
          smsId: 'a1',
          body: 'Rs.5000 withdrawn from HDFC Bank Card [account] at ATM',
        ),
      ];

      final estimate = const CardCycleEstimator().estimate(cardTxns);
      final lensSum = cardTxns
          .where(MoneyLens.isSpend)
          .fold<int>(0, (sum, t) => sum + MoneyLens.signedSpendPaise(t));

      expect(
        lensSum,
        estimate.observedPurchasesPaise - estimate.cardRefundsPaise,
      );
      // Guard: the identity above is worthless if both sides are zero.
      expect(lensSum, 100000 + 250000 - 40000);
    });

    test('and it holds when the set contains a body-worded settlement', () {
      // Part 1 left this false. `observedPurchasesPaise` admitted any
      // card-instrument debit that was not an ATM withdrawal, and a bank
      // writing its settlement as "Payment of Rs.45,000 towards your HDFC
      // Credit Card" is stored exactly that way (`_cardMarker` fires on the
      // bare phrase "credit card"). The lens excluded it and the estimator did
      // not, so the two sides disagreed by a whole statement — in the one line
      // Part 2 puts on screen.
      final cardTxns = [
        _cardPurchase(
          amountPaise: 100000,
          date: DateTime(2026, 8, 4),
          smsId: 'p1',
        ),
        _txn(
          amountPaise: 4500000,
          instrument: PaymentInstrument.card,
          date: DateTime(2026, 8, 20),
          smsId: 's1',
          body: _kSettlementBody,
        ),
      ];

      // The fixture proves itself: this row really is the shape the estimator
      // used to read as a purchase.
      expect(MoneyLens.isCardSettlement(cardTxns[1]), isTrue);
      expect(cardTxns[1].instrument, PaymentInstrument.card);
      expect(cardTxns[1].direction, TransactionDirection.debit);
      expect(cardTxns[1].type, isNot(TxnType.atm));

      final estimate = const CardCycleEstimator().estimate(cardTxns);
      final lensSum = cardTxns
          .where(MoneyLens.isSpend)
          .fold<int>(0, (sum, t) => sum + MoneyLens.signedSpendPaise(t));

      expect(
        lensSum,
        estimate.observedPurchasesPaise - estimate.cardRefundsPaise,
      );
      expect(lensSum, 100000);
    });
  });
}

// ---------------------------------------------------------------------------
// A ₹500 card purchase on 6 August belongs to August. The ₹45,000 bill payment
// on 20 September belongs to no spend total at all.
// ---------------------------------------------------------------------------
void _accrualPlacement() {
  final purchase = _cardPurchase(
    amountPaise: 50000,
    date: DateTime(2026, 8, 6),
    smsId: 'purchase',
  );
  final settlement = _txn(
    amountPaise: 4500000,
    instrument: PaymentInstrument.card,
    date: DateTime(2026, 9, 20),
    smsId: 'settlement',
    body: _kSettlementBody,
  );

  group('Spec A — a card purchase accrues in the month it was made', () {
    test('August counts the purchase that used to be in no total', () {
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([purchase, settlement], DateTime(2026, 8, 15)),
        nowOverride: DateTime(2026, 8, 15),
      );

      expect(i.spentThisMonthCount, 1);
      expect(i.spentThisMonthLabel, inr(500));
    });

    test('September counts neither the bill nor the purchase again', () {
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([purchase, settlement], DateTime(2026, 9, 25)),
        nowOverride: DateTime(2026, 9, 25),
      );

      expect(i.spentThisMonthCount, 0);
      expect(i.spentThisMonthLabel, inr(0));
    });

    test('and both rows stay on screen in the day the bank sent them', () {
      // The rows were always listed; only the totals omitted them. Removing a
      // rupee from a total must not remove it from the list.
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([purchase, settlement], DateTime(2026, 9, 25)),
        nowOverride: DateTime(2026, 9, 25),
      );

      final amounts = [
        for (final group in i.dateGroups)
          for (final row in group.items) row.amount,
      ];
      expect(amounts, containsAll(['-${inr(500)}', '-${inr(45000)}']));
    });
  });
}

void _refundNetting() {
  group('Spec A — a card refund nets in the month it arrives', () {
    final purchase = _cardPurchase(
      amountPaise: 100000,
      date: DateTime(2026, 8, 5),
      smsId: 'purchase',
    );

    test('a refund in the same month reduces that month', () {
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([
          purchase,
          _cardRefund(
            amountPaise: 40000,
            date: DateTime(2026, 8, 10),
            smsId: 'refund',
          ),
        ], DateTime(2026, 8, 15)),
        nowOverride: DateTime(2026, 8, 15),
      );

      expect(i.spentThisMonthLabel, inr(600));
    });

    test('a refund in the next month reduces the next month, not the buy', () {
      final history = [
        purchase,
        _cardRefund(
          amountPaise: 40000,
          date: DateTime(2026, 9, 3),
          smsId: 'refund',
        ),
      ];

      final august = computeRealInsights(
        _state,
        snapshot: _reduced(history, DateTime(2026, 8, 15)),
        nowOverride: DateTime(2026, 8, 15),
      );
      final september = computeRealInsights(
        _state,
        snapshot: _reduced(history, DateTime(2026, 9, 15)),
        nowOverride: DateTime(2026, 9, 15),
      );

      expect(august.spentThisMonthLabel, inr(1000));
      expect(september.spentThisMonthLabel, inr(-400));
    });

    test('a refund after the bill was paid leaves that month negative', () {
      // Correct, and shown rather than floored: the money came back in a month
      // nothing was consumed, and flooring at zero drops the difference.
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([
          purchase,
          _txn(
            amountPaise: 100000,
            merchant: 'CRED',
            date: DateTime(2026, 9, 20),
            smsId: 'settlement',
            body: 'Rs.1000 debited from HDFC Bank ac',
          ),
          _cardRefund(
            amountPaise: 40000,
            date: DateTime(2026, 9, 25),
            smsId: 'refund',
          ),
        ], DateTime(2026, 9, 30)),
        nowOverride: DateTime(2026, 9, 30),
      );

      expect(i.spentThisMonthLabel, inr(-400));
    });
  });
}

void _planningBaseline() {
  group('Spec A — the planning baseline drops the settlement only', () {
    test('a card bill leaves everyday spending; ATM and SIP stay excluded', () {
      final july = DateTime(2026, 7, 10);
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([
          _txn(
            amountPaise: 250000,
            merchant: 'swiggy',
            categoryKey: 'food',
            date: july,
            smsId: 'swiggy',
            body: 'Rs.2500 debited from HDFC Bank ac',
          ),
          _txn(
            amountPaise: 4500000,
            merchant: 'CRED',
            date: july,
            smsId: 'settlement',
            body: 'Rs.45000 debited from HDFC Bank ac',
          ),
          _txn(
            amountPaise: 2000000,
            merchant: 'main street atm',
            date: july,
            smsId: 'atm',
            body: 'Rs.20000 withdrawn from HDFC Bank Card [account] at ATM',
          ),
          _txn(
            amountPaise: 1000000,
            type: TxnType.other,
            merchant: 'groww invest tech',
            date: july,
            smsId: 'sip',
            body:
                'UPDATE: Rs.10000 debited from HDFC Bank ac. Info: ACH D- '
                'GROWW INVEST TECH PR',
          ),
        ], DateTime(2026, 8, 15)),
        nowOverride: DateTime(2026, 8, 15),
      );

      final everyday = (i.needPlan?.requiredRows ?? const [])
          .where((r) => r.label == 'Everyday spending')
          .toList();
      expect(everyday, hasLength(1));
      expect(everyday.single.amount, inr(2500));
    });
  });
}

void _trendChartSingleLens() {
  group('Spec A — the trend chart plots one lens', () {
    test('a past bar and the current bar read the same card purchase', () {
      // The past bars come from `_monthSpendPaise` and the current bar from
      // `spentThisMonthPaise`. Two identical card purchases must produce two
      // identical bars; if one side moved to the planning baseline the July bar
      // would read ₹0 beside an August bar reading ₹5k.
      final i = computeRealInsights(
        _state,
        snapshot: _reduced([
          _cardPurchase(
            amountPaise: 500000,
            date: DateTime(2026, 7, 6),
            smsId: 'july',
          ),
          _cardPurchase(
            amountPaise: 500000,
            date: DateTime(2026, 8, 6),
            smsId: 'august',
          ),
        ], DateTime(2026, 8, 15)),
        nowOverride: DateTime(2026, 8, 15),
      );

      final byLabel = {for (final bar in i.spendTrendBars) bar.label: bar.tag};
      expect(byLabel['Jul'], '₹5k');
      expect(byLabel['Aug'], '₹5k');
    });
  });
}

// ---------------------------------------------------------------------------
// A recurring deposit is money moved into savings, not consumption. The bank
// names it on the rail as `RD/<ref>/<payee>`, and the marker has to carry that
// slash: `_matchesAny` is a plain substring test, so the bare letters `rd`
// match the word *card* and would silence 852 of the 2,071 rows on the owner's
// device — every card purchase in the corpus.
// ---------------------------------------------------------------------------
void _recurringDepositClassification() {
  group('a recurring deposit is savings, not spend', () {
    test('the Axis RD auto-debit counts on neither lens', () {
      // Redacted shape of the 7 monthly ₹12,000 RD debits on the owner's
      // device. The payee name is synthetic.
      final rd = _txn(
        amountPaise: 1200000,
        type: TxnType.other,
        body:
            '[amount] debited from A/c no. [account] on 16-12-20 05:17:59 IST '
            'at RD/[number]/PAYEE NAME. Avl Bal- [amount].',
      );

      expect(MoneyLens.isSpend(rd), isFalse);
      expect(MoneyLens.isEverydayCashSpend(rd), isFalse);
    });

    test('the older Info: MOB-RD form counts on neither lens', () {
      final mobRd = _txn(
        amountPaise: 1200000,
        type: TxnType.other,
        body:
            'Your A/c [account] is debited by [amount] on 15Aug20. '
            'Avbl Bal: [amount]. Info: MOB-RD/[number]/PAYEE NAME.',
      );

      expect(MoneyLens.isSpend(mobRd), isFalse);
      expect(MoneyLens.isEverydayCashSpend(mobRd), isFalse);
    });

    test('the marker does not fire on the word card', () {
      final purchase = _txn(
        amountPaise: 250000,
        body:
            'Rs.2500 spent on HDFC Bank Card x3333 at RAZ*SWIGGY on '
            '05-08-26:22:03:27.Not U?',
      );

      expect(MoneyLens.isSpend(purchase), isTrue);
      expect(MoneyLens.isEverydayCashSpend(purchase), isTrue);
    });
  });
}
