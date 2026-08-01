import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/real_insights.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
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
}) => ParsedTxn(
  smsId: 'sms:${body.hashCode}:$amountPaise',
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 8, 5),
  payeeType: payeeType,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: body,
  bodyHash: 'h',
  scanBatchId: 'b',
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
    test('excludes cash, investments, credit-card, mandates, transfers', () {
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

      // Only the Swiggy debit is genuine consumption.
      expect(i.spentThisMonthCount, 1);
      expect(i.spentThisMonthLabel, inr(2500));
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
        final i = computeRealInsights(
          _state,
          snapshot: _snapshot([_cashOut, _sip, _creditCard, _mandate]),
          nowOverride: _now,
        );

        expect(i.spentThisMonthCount, 0);
        expect(i.spentThisMonthLabel, inr(0));
      },
    );
  });
}
