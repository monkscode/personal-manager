import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/features/app/insights_screen.dart';
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
  tab: 'insights',
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

SmsAnalysisSnapshot _snapshot() => SmsAnalysisSnapshot(
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
  currentMonthTxns: const [],
  yearOverYear: const {
    'groceries': YearOverYearCategory(
      categoryKey: 'groceries',
      lastYearPaise: 800000,
      currentPaise: 1100000,
    ),
  },
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
        home: const Scaffold(body: InsightsScreen()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('live insights show expected-vs-actual and year-over-year', (
    tester,
  ) async {
    final i = Insights.compute(_state, snapshot: _snapshot(), now: _now);
    await _pump(tester, i);

    final scrollable = find.byType(Scrollable).first;

    // Expected-vs-actual section for the current month.
    await tester.scrollUntilVisible(
      find.text('Expected vs actual · this month'),
      250,
      scrollable: scrollable,
    );
    expect(find.text('Expected vs actual · this month'), findsOneWidget);
    expect(find.text('Recurring'), findsWidgets);
    // Rent (₹18,000) is the expected recurring outflow.
    expect(find.textContaining('₹18,000'), findsWidgets);

    // Same-month-last-year-vs-now section.
    await tester.scrollUntilVisible(
      find.text('vs last year · same month'),
      250,
      scrollable: scrollable,
    );
    expect(find.text('vs last year · same month'), findsOneWidget);
    expect(find.text('Groceries'), findsOneWidget);
    // Current spend and the delta both surface.
    expect(find.textContaining('₹11,000'), findsWidgets);
    expect(find.textContaining('+₹3,000'), findsOneWidget);
  });

  testWidgets('sample mode omits the SMS-only comparison sections', (
    tester,
  ) async {
    await _pump(tester, Insights.compute(const AppState()));
    expect(find.text('Expected vs actual · this month'), findsNothing);
    expect(find.text('vs last year · same month'), findsNothing);
  });
}
