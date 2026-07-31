import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/features/app/transactions_screen.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 8, 20);

final _state = const AppState().copyWith(
  stage: 'app',
  tab: 'transactions',
  nps: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'monthly',
    month: 'Feb',
  ),
  ppf: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'lumpsum',
    month: 'Feb',
  ),
  mf: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'monthly',
    month: 'Feb',
  ),
  currentBalance: '',
  salary: '',
);

const _salary = SalaryProfile(
  confidence: SalaryConfidence.detectedStable,
  basePaise: 8500000,
  expectedDay: 10,
);

ParsedTxn _txn(String id, String merchant, int paise, DateTime date) =>
    ParsedTxn(
      smsId: id,
      sender: 'VM-HDFCBK',
      direction: TransactionDirection.debit,
      instrument: PaymentInstrument.bank,
      type: TxnType.upi,
      amountPaise: paise,
      txnDate: date,
      merchant: merchant,
      payeeType: PayeeType.merchant,
      categoryKey: 'food',
      confidence: 0.95,
      reviewStatus: ReviewStatus.confirmed,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted: 'redacted',
      bodyHash: 'h-$id',
      scanBatchId: 'b',
    );

SmsAnalysisSnapshot _snapshot(List<ParsedTxn> txns) => SmsAnalysisSnapshot(
  targetMonth: DateTime(2026, 8),
  hasData: true,
  commitments: const [],
  reviewCandidates: const [],
  salary: _salary,
  otherIncome: const [],
  seasonal: const SeasonalEstimate(targetMonth: 8, byCategory: {}),
  reconciliationItems: [
    ReconciliationItem(
      id: 'rent',
      label: 'Rent',
      amountPaise: 1800000,
      direction: LedgerDirection.outflow,
      owner: ForecastOwner.recurringCommitment,
      source: ForecastItemSource.sms,
      dueDate: DateTime(2026, 8, 5),
      matchKey: 'match:rent',
    ),
  ],
  cards: const [],
  currentMonthTxns: txns,
  yearOverYear: const {},
  cashLevel: CashCoverageLevel.none,
  cashDrainRatio: 0,
  currentMonthAtmPaise: 0,
  obligations: const [],
  reservePlan: const ReservePlan.empty(),
  riskDecisions: const [],
  anchor: BalanceAnchor(
    amountPaise: 10000000,
    asOf: DateTime(2026, 8, 1),
    accountLast4: '1234',
    source: BalanceAnchorSource.smsBankBalance,
  ),
  anchorFreshness: AnchorFreshness.current,
);

Future<void> _pump(WidgetTester tester, Insights i) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        insightsProvider.overrideWithValue(i),
      ],
      child: MaterialApp(
        theme: buildTheme(AppPalette.dark),
        home: const Scaffold(body: TransactionsScreen()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('live mode groups real SMS transactions by day', (tester) async {
    final i = Insights.compute(
      _state,
      snapshot: _snapshot([
        _txn('a', 'Swiggy', 45000, DateTime(2026, 8, 6)),
        _txn('b', 'BigBasket', 120000, DateTime(2026, 8, 5)),
        _txn('c', 'Zomato', 38000, DateTime(2026, 8, 6)),
      ]),
      now: _now,
    );
    await _pump(tester, i);

    // Two distinct day headers (uppercased by the screen), most-recent first.
    expect(find.text('6 AUG'), findsOneWidget);
    expect(find.text('5 AUG'), findsOneWidget);
    expect(find.text('Swiggy'), findsOneWidget);
    expect(find.text('Zomato'), findsOneWidget);
    expect(find.text('BigBasket'), findsOneWidget);
  });

  testWidgets('sample mode demo activity is unchanged', (tester) async {
    await _pump(tester, Insights.compute(const AppState()));
    // Sample scenario has no per-day AUG headers from the SMS path.
    expect(find.text('6 AUG'), findsNothing);
    expect(find.text('Transactions'), findsOneWidget);
  });
}
