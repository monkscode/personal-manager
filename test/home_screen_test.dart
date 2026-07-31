import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/features/app/home_forecast_explorer.dart';
import 'package:expense_insight/features/app/home_screen.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 8, 1);

final _state = const AppState().copyWith(
  stage: 'app',
  tab: 'home',
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

SmsAnalysisSnapshot _snapshot(
  List<ReconciliationItem> items, {
  BalanceAnchor? anchor,
}) => SmsAnalysisSnapshot(
  targetMonth: DateTime(2026, 8),
  hasData: true,
  commitments: const [],
  reviewCandidates: const [],
  salary: _salary,
  otherIncome: const [],
  seasonal: const SeasonalEstimate(targetMonth: 8, byCategory: {}),
  reconciliationItems: items,
  cards: const [],
  currentMonthTxns: const [],
  yearOverYear: const {},
  cashLevel: CashCoverageLevel.none,
  cashDrainRatio: 0,
  currentMonthAtmPaise: 0,
  obligations: const [],
  reservePlan: const ReservePlan.empty(),
  riskDecisions: const [],
  anchor: anchor,
  anchorFreshness: anchor?.freshnessAsOf(_now),
);

BalanceAnchor _anchor(int paise, DateTime asOf) => BalanceAnchor(
  amountPaise: paise,
  asOf: asOf,
  accountLast4: '1234',
  source: BalanceAnchorSource.smsBankBalance,
);

ReconciliationItem _outflow(
  String id,
  String label,
  int paise,
  DateTime due, {
  ForecastOwner owner = ForecastOwner.recurringCommitment,
}) => ReconciliationItem(
  id: id,
  label: label,
  amountPaise: paise,
  direction: LedgerDirection.outflow,
  owner: owner,
  source: ForecastItemSource.sms,
  dueDate: due,
  matchKey: 'match:$id',
);

ReconciliationItem _salaryInflow(String id, int paise, DateTime due) =>
    ReconciliationItem(
      id: id,
      label: 'Salary',
      amountPaise: paise,
      direction: LedgerDirection.inflow,
      owner: ForecastOwner.salary,
      source: ForecastItemSource.sms,
      dueDate: due,
      matchKey: 'match:$id',
    );

Insights _shortfall() => Insights.compute(
  _state,
  snapshot: _snapshot(anchor: _anchor(500000, DateTime(2026, 8, 1)), [
    _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
    _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
  ]),
  now: _now,
);

Insights _surplus() => Insights.compute(
  _state,
  snapshot: _snapshot(anchor: _anchor(10000000, DateTime(2026, 8, 1)), [
    _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
  ]),
  now: _now,
);

Insights _stale() => Insights.compute(
  _state,
  snapshot: _snapshot(anchor: _anchor(9000000, DateTime(2026, 7, 15)), [
    _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
  ]),
  now: _now,
);

Future<void> _pumpHome(WidgetTester tester, Insights i) async {
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
        home: const Scaffold(body: HomeScreen()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('HomeScreen (live)', () {
    testWidgets('renders the spend summary and no forecast explorer', (
      tester,
    ) async {
      await _pumpHome(tester, _shortfall());
      expect(find.text('Spent this month'), findsOneWidget);
      // The forecast explorer and its sections were removed from Home.
      expect(find.byType(HomeForecastExplorer), findsNothing);
      expect(find.text('Your plan now'), findsNothing);
      expect(find.textContaining('See why'), findsNothing);
      expect(find.text('Unconfirmed risk'), findsNothing);
    });

    testWidgets('does not render the month breakdown section', (tester) async {
      await _pumpHome(tester, _shortfall());
      expect(find.textContaining('breakdown'), findsNothing);
    });

    testWidgets('exposes pull-to-refresh and hides the SMS scan icon', (
      tester,
    ) async {
      await _pumpHome(tester, _shortfall());
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(find.byKey(const ValueKey('scan-messages')), findsNothing);
    });

    testWidgets('Need-for-next-month value uses the projected teal color', (
      tester,
    ) async {
      final i = _shortfall();
      await _pumpHome(tester, i);
      final needValues = tester.widgetList<Text>(
        find.text(i.nextMonthNeedLabel),
      );
      expect(needValues.any((t) => t.style?.color == AppColors.teal), isTrue);
    });

    testWidgets('preserves the header and the live sync chip', (tester) async {
      await _pumpHome(tester, _shortfall());
      expect(find.text('Welcome back'), findsOneWidget);
      expect(find.textContaining('Live'), findsWidgets);
    });

    testWidgets('sample mode shows no forecast explorer', (tester) async {
      await _pumpHome(tester, Insights.compute(const AppState()));
      expect(find.byType(HomeForecastExplorer), findsNothing);
      expect(find.text('Your plan now'), findsNothing);
      expect(find.textContaining('See why'), findsNothing);
    });

    testWidgets('renders surplus and stale insights without errors', (
      tester,
    ) async {
      await _pumpHome(tester, _surplus());
      expect(tester.takeException(), isNull);
      await _pumpHome(tester, _stale());
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders without overflow or dual scroll errors', (
      tester,
    ) async {
      await _pumpHome(tester, _shortfall());
      expect(find.byType(ListView), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
