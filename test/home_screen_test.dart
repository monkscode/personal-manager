import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_scan_orchestrator.dart';
import 'package:expense_insight/features/app/home_forecast_explorer.dart';
import 'package:expense_insight/features/app/home_screen.dart';
import 'package:expense_insight/features/app/why_log_screen.dart';
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
  ReservePlan reservePlan = const ReservePlan.empty(),
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
  reservePlan: reservePlan,
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

/// No bank-balance SMS has ever been seen, so the forecast opens on the
/// fabricated evidence-free anchor and every month is provisional (TASK-22).
Insights _noAnchor() => Insights.compute(
  _state,
  snapshot: _snapshot([
    _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
    _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
  ]),
  now: _now,
);

/// An obligation large enough to reserve for that the user has not enabled —
/// the explorer's "Start reserve" affordance.
Insights _reserveCandidate() => Insights.compute(
  _state,
  snapshot: _snapshot(
    anchor: _anchor(500000, DateTime(2026, 8, 1)),
    [_salaryInflow('sal', 8500000, DateTime(2026, 8, 10))],
    reservePlan: ReservePlan(
      schedules: const [],
      availableToEnable: [
        ReserveCandidate(
          dedupeKey: 'oblig:lic',
          label: 'LIC premium',
          dueDate: DateTime(2026, 11, 20),
          targetPaise: 4700000,
        ),
      ],
    ),
  ),
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

ScanRunResult _scanResult({
  int skippedMessages = 0,
  SmsScanStatus status = SmsScanStatus.success,
}) => ScanRunResult(
  status: status,
  scanBatchId: 'scan:test',
  parsed: 3,
  autoAdded: 3,
  queuedReview: 0,
  skippedDuplicate: 0,
  collisionSets: 0,
  obligationCandidates: 0,
  skippedMessages: skippedMessages,
);

void main() {
  group('a partial scan is named to the user (TASK-33)', () {
    test('a complete scan says nothing about coverage', () {
      expect(scanShortfallMessage(_scanResult()), isNull);
    });

    test('a truncated scan names how many messages went unread', () {
      final message = scanShortfallMessage(_scanResult(skippedMessages: 1500));

      expect(message, isNotNull);
      expect(message, contains('1,500'));
    });

    test('a scan that could not read at all makes no coverage claim', () {
      expect(
        scanShortfallMessage(
          _scanResult(status: SmsScanStatus.permissionDenied),
        ),
        isNull,
      );
    });
  });

  group('HomeScreen (live)', () {
    testWidgets('renders the spend summary alongside the forecast explorer', (
      tester,
    ) async {
      await _pumpHome(tester, _shortfall());
      expect(find.text('Spent this month'), findsOneWidget);
      // The explorer is the forecast surface on the live path (TASK-34); the
      // spend summary reports actuals beside it.
      expect(find.byType(HomeForecastExplorer), findsOneWidget);
      expect(find.text('Your plan now'), findsOneWidget);
      expect(find.textContaining('See why'), findsOneWidget);
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

  // ==========================================================================
  // TASK-34 — the forecast surface must be reachable, not merely correct.
  //
  // Every one of these asserts that something the forecast layer *computes*
  // reaches a pixel on the live SMS path. Rendering a screen directly proves it
  // draws; only Home proves anything can open it.
  // ==========================================================================

  group('the forecast surface is reachable on the live path (TASK-34)', () {
    testWidgets('live Home builds the forecast explorer', (tester) async {
      await _pumpHome(tester, _shortfall());

      expect(find.byType(HomeForecastExplorer), findsOneWidget);
    });

    // GUARD, not regression coverage: this already passed before the explorer
    // was wired up. The headline reaches a pixel through `alerts.first.text`
    // (real_insights.dart:809), rendered at home_screen.dart:246 outside the
    // branch — which TASK-34's "only site" table missed. Kept so the one
    // surviving route to the headline cannot be removed unnoticed.
    testWidgets('live Home renders the forecast headline exactly once', (
      tester,
    ) async {
      final i = _shortfall();
      expect(i.forecastHeadline, isNotEmpty);

      await _pumpHome(tester, i);
      await tester.dragUntilVisible(
        find.text(i.forecastHeadline),
        find.byType(ListView).first,
        const Offset(0, -300),
      );

      expect(find.text(i.forecastHeadline), findsOneWidget);
    });

    testWidgets('live Home names the balance the forecast opens on', (
      tester,
    ) async {
      final i = _shortfall();
      expect(i.anchorAsOfLabel, isNotEmpty);

      await _pumpHome(tester, i);

      expect(find.textContaining(i.anchorAsOfLabel), findsOneWidget);
    });

    testWidgets('live Home renders the committed, expected and free strip', (
      tester,
    ) async {
      final i = _shortfall();

      await _pumpHome(tester, i);

      expect(find.text(i.salaryCommitted), findsWidgets);
      expect(find.text(i.salaryExpected), findsWidgets);
      expect(find.text(i.salaryFree), findsWidgets);
    });

    // The headline alert already carries the word (TASK-22 prefixes it), so
    // this asserts the marker sits on the forecast surface itself — beside the
    // number it qualifies — rather than only in a notification strip.
    testWidgets('an evidence-free anchor marks the forecast surface itself', (
      tester,
    ) async {
      final i = _noAnchor();
      expect(i.anchorProvisional, isTrue);

      await _pumpHome(tester, i);

      expect(
        find.descendant(
          of: find.byType(HomeForecastExplorer),
          matching: find.textContaining('Provisional'),
        ),
        findsOneWidget,
      );
    });

    testWidgets("See why opens this month's coverage lines from Home", (
      tester,
    ) async {
      final i = _shortfall();
      expect(i.coverageLines, isNotEmpty);

      await _pumpHome(tester, i);
      final seeWhy = find.textContaining('See why');
      await tester.ensureVisible(seeWhy);
      await tester.pumpAndSettle();
      await tester.tap(seeWhy);
      await tester.pumpAndSettle();

      expect(find.byType(WhyLogScreen), findsOneWidget);
      expect(find.text(i.coverageLines.first.label), findsOneWidget);
    });

    testWidgets(
      "a future month's coverage line is reachable from Home (TASK-21)",
      (tester) async {
        final i = _shortfall();
        // Next month carries its own omission line, and `Insights.coverageLines`
        // holds the target month's alone — so only a per-month surface can show
        // it. Both months label the omission identically, so the why-log's own
        // month title is what proves the future month opened.
        final nextPlan = i.forecastExplorer!.planAt(1);
        expect(nextPlan.coverageLines, isNotEmpty);

        await _pumpHome(tester, i);
        final nextMonth = find.text('Next month');
        await tester.ensureVisible(nextMonth);
        await tester.pumpAndSettle();
        await tester.tap(nextMonth);
        await tester.pumpAndSettle();
        final seeWhy = find.textContaining('See why');
        await tester.ensureVisible(seeWhy);
        await tester.pumpAndSettle();
        await tester.tap(seeWhy);
        await tester.pumpAndSettle();

        expect(find.byType(WhyLogScreen), findsOneWidget);
        expect(
          find.text('Why ${i.nextMonthLabel} looks like this'),
          findsOneWidget,
        );
        expect(find.text(nextPlan.coverageLines.first.label), findsWidgets);
      },
    );

    testWidgets('a reserve action from Home reaches the persistence layer', (
      tester,
    ) async {
      await _pumpHome(tester, _reserveCandidate());
      final start = find.text('Start reserve');
      await tester.ensureVisible(start);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();

      // No database is provided in a widget test, so a wired callback surfaces
      // the store's own failure. An unwired one would say nothing at all.
      expect(find.textContaining('Could not update reserve'), findsOneWidget);
    });
  });
}
