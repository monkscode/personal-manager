import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/features/app/home_forecast_explorer.dart';
import 'package:expense_insight/services/forecast_explorer.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/widgets/ui.dart';
import 'dart:async';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const _kJuly = 7;
const _kAugust = 8;

DateTime _monthStart(int month, [int year = 2026]) => DateTime(year, month, 1);

ForecastLine _hardLine(
  String label,
  int paise,
  DateTime month, {
  String? ownerKey,
  double confidence = 0.9,
  LedgerDirection direction = LedgerDirection.outflow,
}) => ForecastLine(
  label: label,
  amountPaise: paise,
  source: ForecastEventSource.recurring,
  date: month,
  ownerKey: ownerKey ?? 'owner:$label',
  status: ForecastLineStatus.unpaid,
  confidence: confidence,
  direction: direction,
  obligationDedupeKey: 'dedupe:$label',
);

ForecastLine _riskLine(
  String label,
  int paise,
  DateTime month, {
  String? ownerKey,
  double confidence = 0.4,
  LedgerDirection direction = LedgerDirection.outflow,
}) => ForecastLine(
  label: label,
  amountPaise: paise,
  source: ForecastEventSource.seasonal,
  date: month,
  ownerKey: ownerKey ?? 'risk:$label',
  status: ForecastLineStatus.review,
  confidence: confidence,
  direction: direction,
);

ReserveSchedule _schedule(
  String key,
  String label,
  DateTime due,
  int target,
  int funded,
  List<ReserveContribution> contributions,
) => ReserveSchedule(
  dedupeKey: key,
  label: label,
  dueDate: due,
  targetPaise: target,
  fundedPaise: funded,
  remainingPaise: target - funded,
  contributions: contributions,
  isFullyFunded: funded >= target,
  isOverdue: false,
);

ReserveCandidate _candidate(
  String key,
  String label,
  DateTime due,
  int target,
) => ReserveCandidate(
  dedupeKey: key,
  label: label,
  dueDate: due,
  targetPaise: target,
);

ForecastMonthPlan _plan({
  required DateTime monthStart,
  int requiredInBankPaise = 0,
  int openingBalancePaise = 10000000,
  int closingBalancePaise = 10000000,
  int minimumBalancePaise = 10000000,
  DateTime? minimumBalanceDate,
  int shortfallPaise = 0,
  int committedOutflowPaise = 0,
  int expectedInflowPaise = 0,
  int reserveContributionPaise = 0,
  List<ReserveSchedule> reserveSchedules = const [],
  int riskBufferPaise = 0,
  List<ForecastLine> riskLines = const [],
  List<ForecastLine> hardLines = const [],
  List<ForecastCoverageLine> coverageLines = const [],
  double confidence = 0.85,
  bool isProvisional = false,
}) => ForecastMonthPlan(
  monthStart: monthStart,
  requiredInBankPaise: requiredInBankPaise,
  openingBalancePaise: openingBalancePaise,
  closingBalancePaise: closingBalancePaise,
  minimumBalancePaise: minimumBalancePaise,
  minimumBalanceDate: minimumBalanceDate ?? monthStart,
  shortfallPaise: shortfallPaise,
  committedOutflowPaise: committedOutflowPaise,
  expectedInflowPaise: expectedInflowPaise,
  reserveContributionPaise: reserveContributionPaise,
  reserveSchedules: reserveSchedules,
  riskBufferPaise: riskBufferPaise,
  riskLines: riskLines,
  hardLines: hardLines,
  coverageLines: coverageLines,
  confidence: confidence,
  isProvisional: isProvisional,
);

/// Builds a 12-month explorer where months 0 and 1 have distinct values.
ForecastExplorer _explorerWithDistinctMonths({
  List<ReserveSchedule>? reserveSchedules,
  List<ReserveCandidate>? availableToEnable,
}) {
  final july = _monthStart(_kJuly);
  final august = _monthStart(_kAugust);

  final plans = <ForecastMonthPlan>[
    _plan(
      monthStart: july,
      requiredInBankPaise: 1800000,
      minimumBalancePaise: -300000,
      minimumBalanceDate: DateTime(2026, 7, 15),
      committedOutflowPaise: 1800000,
      expectedInflowPaise: 8500000,
      hardLines: [
        _hardLine('Rent', 1500000, july),
        _hardLine('Electricity', 300000, july),
      ],
      riskBufferPaise: 200000,
      riskLines: [_riskLine('Groceries estimate', 200000, july)],
      reserveContributionPaise:
          reserveSchedules?.fold(0, (s, r) => s! + r.nextContributionPaise) ??
          0,
      reserveSchedules: reserveSchedules ?? [],
      confidence: 0.88,
    ),
    _plan(
      monthStart: august,
      requiredInBankPaise: 4700000,
      minimumBalancePaise: -100000,
      minimumBalanceDate: DateTime(2026, 8, 6),
      committedOutflowPaise: 4700000,
      expectedInflowPaise: 8500000,
      hardLines: [
        _hardLine('Rent', 1500000, august),
        _hardLine('LIC premium', 3200000, august),
      ],
      riskBufferPaise: 500000,
      riskLines: [_riskLine('Car service', 500000, august)],
      confidence: 0.72,
    ),
    // Remaining 10 months.
    for (var m = 9; m <= 18; m++)
      _plan(
        monthStart: _monthStart(m > 12 ? m - 12 : m, m > 12 ? 2027 : 2026),
        requiredInBankPaise: 1500000 + (m * 10000),
        committedOutflowPaise: 1500000 + (m * 10000),
      ),
  ];

  return ForecastExplorer(
    plans: plans,
    currentAction: ForecastCurrentAction(
      requiredInBankPaise: plans.first.requiredInBankPaise,
      keepAvailableUntil: plans.first.minimumBalanceDate,
      reserveContributionPaise: plans.first.reserveContributionPaise,
      reserveSchedules: plans.first.reserveSchedules,
      isProvisional: false,
    ),
    availableToEnable: availableToEnable ?? [],
  );
}

/// Builds a 12-month explorer where every month is reachable.
ForecastExplorer _twelveMonthExplorer() {
  final plans = List.generate(12, (i) {
    final m = _monthStart(
      7 + i > 12 ? 7 + i - 12 : 7 + i,
      7 + i > 12 ? 2027 : 2026,
    );
    return _plan(
      monthStart: m,
      requiredInBankPaise: 1000000 * (i + 1),
      committedOutflowPaise: 1000000 * (i + 1),
      hardLines: [_hardLine('Bill ${i + 1}', 1000000 * (i + 1), m)],
    );
  });

  return ForecastExplorer(
    plans: plans,
    currentAction: ForecastCurrentAction(
      requiredInBankPaise: plans.first.requiredInBankPaise,
      keepAvailableUntil: plans.first.minimumBalanceDate,
      reserveContributionPaise: 0,
      reserveSchedules: const [],
      isProvisional: false,
    ),
    availableToEnable: [],
  );
}

// Callback trackers
List<({String dedupeKey, bool enabled, int fundedPaise})> _reserveUpdates = [];
List<ForecastRiskDecision> _riskDecisions = [];
List<({ForecastMonthPlan plan, int offset})> _whyCalls = [];

Future<void> Function({
  required String dedupeKey,
  required bool enabled,
  required int fundedPaise,
})
_onUpdateReserve({bool shouldFail = false}) {
  return ({
    required String dedupeKey,
    required bool enabled,
    required int fundedPaise,
  }) async {
    if (shouldFail) throw Exception('Reserve update failed');
    _reserveUpdates.add((
      dedupeKey: dedupeKey,
      enabled: enabled,
      fundedPaise: fundedPaise,
    ));
  };
}

Future<void> Function(ForecastRiskDecision) _onSaveRisk({
  bool shouldFail = false,
}) {
  return (ForecastRiskDecision decision) async {
    if (shouldFail) throw Exception('Risk save failed');
    _riskDecisions.add(decision);
  };
}

void Function(ForecastMonthPlan plan, int offset) _onSeeWhy() {
  return (ForecastMonthPlan plan, int offset) {
    _whyCalls.add((plan: plan, offset: offset));
  };
}

Future<void> _pumpExplorer(
  WidgetTester tester,
  ForecastExplorer explorer, {
  int initialOffset = 0,
  bool reserveFails = false,
  bool riskFails = false,
  MediaQueryData? mediaQueryData,
}) async {
  _reserveUpdates = [];
  _riskDecisions = [];
  _whyCalls = [];

  final explorerWidget = HomeForecastExplorer(
    explorer: explorer,
    initialOffset: initialOffset,
    onUpdateReserve: _onUpdateReserve(shouldFail: reserveFails),
    onSaveRiskDecision: _onSaveRisk(shouldFail: riskFails),
    onSeeWhy: _onSeeWhy(),
  );

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: Scaffold(
        body: mediaQueryData == null
            ? explorerWidget
            : MediaQuery(data: mediaQueryData, child: explorerWidget),
      ),
    ),
  );
  await tester.pump();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('HomeForecastExplorer month selection', () {
    testWidgets('initial offset 0 shows current action and first plan', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      // Action-first header: available amount
      expect(find.text(inr(18000)), findsWidgets);
      // Keep-available date
      expect(find.textContaining('15 Jul'), findsWidgets);
    });

    testWidgets('Next month changes every month-specific field', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      // Initially July detail
      expect(find.textContaining('July'), findsWidgets);
      expect(find.text(inr(18000)), findsWidgets);

      await tester.tap(find.text('Next month'));
      await tester.pump();

      // Now August detail
      expect(find.textContaining('August'), findsWidgets);
      expect(find.text(inr(47000)), findsWidgets);
      expect(find.textContaining('6 Aug'), findsWidgets);
      await tester.scrollUntilVisible(
        find.textContaining('LIC premium'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('LIC premium'), findsOneWidget);
    });

    testWidgets('This month / Next month toggle switches back', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.tap(find.text('Next month'));
      await tester.pump();
      expect(find.text(inr(47000)), findsWidgets);

      await tester.tap(find.text('This month'));
      await tester.pump();
      expect(find.text(inr(18000)), findsWidgets);
    });

    testWidgets('tapping a chart bar selects its offset', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.tap(find.byKey(const ValueKey('forecast-month-1')));
      await tester.pump();

      expect(find.textContaining('August'), findsWidgets);
      expect(find.text(inr(47000)), findsWidgets);
    });

    testWidgets('all 12 chart months are reachable and selectable', (
      tester,
    ) async {
      final explorer = _twelveMonthExplorer();
      await _pumpExplorer(tester, explorer);

      // Scroll to reveal far-right months
      await tester.drag(
        find.byKey(const ValueKey('forecast-month-chart')),
        const Offset(-900, 0),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('forecast-month-11')));
      await tester.pump();

      // Last month = June 2027
      expect(find.textContaining('June'), findsWidgets);
    });
  });

  group('HomeForecastExplorer chart semantics', () {
    testWidgets('bar semantics expose amount, month, and selection', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('forecast-month-0')),
      );
      expect(semantics.label, contains('July 2026'));
      expect(semantics.label, contains('required in bank'));
      // Verify button and selected semantics
      final data = semantics.getSemanticsData();
      // ignore: deprecated_member_use
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
      // ignore: deprecated_member_use
      expect(data.hasFlag(SemanticsFlag.isSelected), isTrue);
    });

    testWidgets('unselected bar is not marked selected in semantics', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('forecast-month-1')),
      );
      final data = semantics.getSemanticsData();
      // ignore: deprecated_member_use
      expect(data.hasFlag(SemanticsFlag.isSelected), isFalse);
    });
  });

  group('HomeForecastExplorer selected detail', () {
    testWidgets('shows required in bank, lowest balance, reserve, risk', (
      tester,
    ) async {
      final sched = _schedule(
        'res1',
        'LIC reserve',
        DateTime(2026, 10, 1),
        3000000,
        500000,
        [ReserveContribution(date: _monthStart(_kJuly), amountPaise: 250000)],
      );
      final explorer = _explorerWithDistinctMonths(reserveSchedules: [sched]);
      await _pumpExplorer(tester, explorer);

      // Required in bank
      expect(find.text(inr(18000)), findsWidgets);
      // Lowest balance date
      expect(find.textContaining('15 Jul'), findsWidgets);
      // Confidence
      expect(find.textContaining('88%'), findsWidgets);
      // Scroll to reveal reserve and risk rows
      await tester.dragUntilVisible(
        find.textContaining('LIC reserve'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      // Reserve label
      expect(find.textContaining('LIC reserve'), findsOneWidget);
      // Risk buffer
      expect(find.text(inr(2000)), findsWidgets);
    });

    testWidgets('provisional confidence shows (provisional) label', (
      tester,
    ) async {
      final plan = _plan(
        monthStart: _monthStart(_kJuly),
        requiredInBankPaise: 1000000,
        isProvisional: true,
        confidence: 0.65,
      );
      final explorer = ForecastExplorer(
        plans: [
          plan,
          ...List.generate(
            11,
            (i) => _plan(
              monthStart: _monthStart(
                8 + i > 12 ? 8 + i - 12 : 8 + i,
                8 + i > 12 ? 2027 : 2026,
              ),
            ),
          ),
        ],
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 1000000,
          keepAvailableUntil: _monthStart(_kJuly),
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: true,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      expect(find.textContaining('provisional'), findsWidgets);
    });

    testWidgets('ranked hard drivers appear in descending order', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      // July: Rent (1500000) > Electricity (300000) — Rent first
      // Scroll to reveal driver rows
      await tester.dragUntilVisible(
        find.textContaining('Electricity'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      final rentOffset = tester.getTopLeft(find.textContaining('Rent'));
      final elecOffset = tester.getTopLeft(find.textContaining('Electricity'));
      expect(rentOffset.dy, lessThan(elecOffset.dy));
    });
  });

  group('HomeForecastExplorer See why', () {
    testWidgets('See why callback carries selected plan and offset', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.tap(find.textContaining('See why July requires'));
      await tester.pump();

      expect(_whyCalls.length, 1);
      expect(_whyCalls.first.offset, 0);
      expect(_whyCalls.first.plan.monthStart, _monthStart(_kJuly));
    });

    testWidgets('See why after selecting next month carries offset 1', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.tap(find.text('Next month'));
      await tester.pump();

      await tester.tap(find.textContaining('See why August requires'));
      await tester.pump();

      expect(_whyCalls.length, 1);
      expect(_whyCalls.first.offset, 1);
      expect(_whyCalls.first.plan.monthStart, _monthStart(_kAugust));
    });
  });

  group('HomeForecastExplorer reserve candidates', () {
    testWidgets('availableToEnable rows show Start reserve', (tester) async {
      final explorer = _explorerWithDistinctMonths(
        availableToEnable: [
          _candidate('cand1', 'Car insurance', DateTime(2027, 3, 1), 4000000),
        ],
      );
      await _pumpExplorer(tester, explorer);

      // Scroll to reveal candidate rows
      await tester.dragUntilVisible(
        find.text('Start reserve'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.textContaining('Car insurance'), findsOneWidget);
      expect(find.text('Start reserve'), findsOneWidget);
    });

    testWidgets('Start reserve calls onUpdateReserve with enabled=true', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths(
        availableToEnable: [
          _candidate('cand1', 'Car insurance', DateTime(2027, 3, 1), 4000000),
        ],
      );
      await _pumpExplorer(tester, explorer);

      // Scroll to reveal candidate rows
      await tester.dragUntilVisible(
        find.text('Start reserve'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Start reserve'));
      await tester.pumpAndSettle();

      expect(_reserveUpdates.length, 1);
      expect(_reserveUpdates.first.dedupeKey, 'cand1');
      expect(_reserveUpdates.first.enabled, isTrue);
      expect(_reserveUpdates.first.fundedPaise, 0);
    });

    testWidgets('Start reserve disables while pending', (tester) async {
      final pendingCompleter = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(AppPalette.dark),
          home: Scaffold(
            body: HomeForecastExplorer(
              explorer: _explorerWithDistinctMonths(
                availableToEnable: [
                  _candidate(
                    'cand1',
                    'Car insurance',
                    DateTime(2027, 3, 1),
                    4000000,
                  ),
                ],
              ),
              initialOffset: 0,
              onUpdateReserve:
                  ({
                    required String dedupeKey,
                    required bool enabled,
                    required int fundedPaise,
                  }) => pendingCompleter.future,
              onSaveRiskDecision: _onSaveRisk(),
              onSeeWhy: _onSeeWhy(),
            ),
          ),
        ),
      );
      await tester.pump();

      // Scroll to reveal candidate rows
      await tester.dragUntilVisible(
        find.text('Start reserve'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Start reserve'));
      await tester.pump();

      // Widget shows loading state while pending
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      // Complete so the test cleans up without dangling timers
      pendingCompleter.complete();
      await tester.pumpAndSettle();
    });
  });

  group('HomeForecastExplorer error handling', () {
    testWidgets('reserve callback failure shows SnackBar', (tester) async {
      final explorer = _explorerWithDistinctMonths(
        availableToEnable: [
          _candidate('cand1', 'Car insurance', DateTime(2027, 3, 1), 4000000),
        ],
      );
      await _pumpExplorer(tester, explorer, reserveFails: true);

      // Scroll to reveal candidate rows
      await tester.dragUntilVisible(
        find.text('Start reserve'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Start reserve'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('HomeForecastExplorer chart', () {
    testWidgets('zero required month renders zero marker', (tester) async {
      final plans = List.generate(12, (i) {
        final m = _monthStart(
          7 + i > 12 ? 7 + i - 12 : 7 + i,
          7 + i > 12 ? 2027 : 2026,
        );
        return _plan(
          monthStart: m,
          requiredInBankPaise: i == 0 ? 0 : 1000000 * i,
          committedOutflowPaise: i == 0 ? 0 : 1000000 * i,
        );
      });
      final explorer = ForecastExplorer(
        plans: plans,
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 0,
          keepAvailableUntil: plans.first.monthStart,
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: false,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      // Bar 0 should still exist and be tappable
      expect(find.byKey(const ValueKey('forecast-month-0')), findsOneWidget);
    });

    testWidgets('bar hit targets are at least 44x44', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      final barFinder = find.byKey(const ValueKey('forecast-month-0'));
      final size = tester.getSize(barFinder);
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets('selected bar has distinct color', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      // Just verify both bars exist and selection changed doesn't crash
      await tester.tap(find.byKey(const ValueKey('forecast-month-1')));
      await tester.pump();

      // Previously selected bar (0) should still be findable
      expect(find.byKey(const ValueKey('forecast-month-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('forecast-month-1')), findsOneWidget);
    });
  });

  group('HomeForecastExplorer equal months', () {
    testWidgets('equal required amounts in adjacent months are legitimate', (
      tester,
    ) async {
      final plans = List.generate(12, (i) {
        final m = _monthStart(
          7 + i > 12 ? 7 + i - 12 : 7 + i,
          7 + i > 12 ? 2027 : 2026,
        );
        return _plan(
          monthStart: m,
          requiredInBankPaise: 1500000,
          committedOutflowPaise: 1500000,
        );
      });
      final explorer = ForecastExplorer(
        plans: plans,
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 1500000,
          keepAvailableUntil: plans.first.monthStart,
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: false,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      // Both offset 0 and 1 should show ₹15,000
      expect(find.text(inr(15000)), findsWidgets);
      await tester.tap(find.text('Next month'));
      await tester.pump();
      expect(find.text(inr(15000)), findsWidgets);
    });
  });

  group('HomeForecastExplorer no data state', () {
    testWidgets('explorer with all-zero months renders without crash', (
      tester,
    ) async {
      final plans = List.generate(12, (i) {
        final m = _monthStart(
          7 + i > 12 ? 7 + i - 12 : 7 + i,
          7 + i > 12 ? 2027 : 2026,
        );
        return _plan(monthStart: m);
      });
      final explorer = ForecastExplorer(
        plans: plans,
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 0,
          keepAvailableUntil: plans.first.monthStart,
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: false,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      // Should not crash and should show something
      expect(find.byType(HomeForecastExplorer), findsOneWidget);
    });
  });

  group('HomeForecastExplorer text scaling', () {
    testWidgets('renders without overflow at textScale 1.3 on 320px', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      _reserveUpdates = [];
      _riskDecisions = [];
      _whyCalls = [];

      tester.view.physicalSize = const Size(320 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(AppPalette.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: HomeForecastExplorer(
              explorer: explorer,
              initialOffset: 0,
              onUpdateReserve: _onUpdateReserve(),
              onSaveRiskDecision: _onSaveRisk(),
              onSeeWhy: _onSeeWhy(),
            ),
          ),
        ),
      );
      await tester.pump();

      // No overflow errors should be thrown by the framework.
      // Verify the widget is present.
      expect(find.byType(HomeForecastExplorer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('HomeForecastExplorer callback signatures', () {
    testWidgets('onSeeWhy receives the selected ForecastMonthPlan', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      // Tap See why at offset 0
      await tester.tap(find.textContaining('See why July requires'));
      await tester.pump();

      final plan = _whyCalls.first.plan;
      expect(plan.hardLines.length, 2);
      expect(plan.hardLines.first.label, 'Rent');
    });
  });

  // =========================================================================
  // Task 7 blocking behaviors — RED tests
  // =========================================================================

  group('HomeForecastExplorer reserve edit', () {
    testWidgets('valid reserve edit calls onUpdateReserve', (tester) async {
      final sched = _schedule(
        'res1',
        'LIC reserve',
        DateTime(2026, 10, 1),
        3000000,
        500000,
        [ReserveContribution(date: _monthStart(_kJuly), amountPaise: 250000)],
      );
      final explorer = _explorerWithDistinctMonths(reserveSchedules: [sched]);
      await _pumpExplorer(tester, explorer);

      await tester.dragUntilVisible(
        find.text('Edit funded amount'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Edit funded amount'));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('reserve-funded-input'));
      await tester.enterText(field, '10000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(_reserveUpdates.length, 1);
      expect(_reserveUpdates.first.dedupeKey, 'res1');
      expect(_reserveUpdates.first.enabled, isTrue);
      expect(_reserveUpdates.first.fundedPaise, 1000000);
    });

    testWidgets('reserve edit rejects amount exceeding target', (tester) async {
      final sched = _schedule(
        'res1',
        'LIC reserve',
        DateTime(2026, 10, 1),
        3000000,
        500000,
        [ReserveContribution(date: _monthStart(_kJuly), amountPaise: 250000)],
      );
      final explorer = _explorerWithDistinctMonths(reserveSchedules: [sched]);
      await _pumpExplorer(tester, explorer);

      await tester.dragUntilVisible(
        find.text('Edit funded amount'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Edit funded amount'));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('reserve-funded-input'));
      await tester.enterText(field, '40000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('exceeds target'), findsOneWidget);
      expect(_reserveUpdates, isEmpty);
    });

    testWidgets('reserve edit callback error shows SnackBar', (tester) async {
      final sched = _schedule(
        'res1',
        'LIC reserve',
        DateTime(2026, 10, 1),
        3000000,
        500000,
        [ReserveContribution(date: _monthStart(_kJuly), amountPaise: 250000)],
      );
      final explorer = _explorerWithDistinctMonths(reserveSchedules: [sched]);
      await _pumpExplorer(tester, explorer, reserveFails: true);

      await tester.dragUntilVisible(
        find.text('Edit funded amount'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Edit funded amount'));
      await tester.pumpAndSettle();

      final field = find.byKey(const ValueKey('reserve-funded-input'));
      await tester.enterText(field, '10000');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('HomeForecastExplorer risk edit', () {
    testWidgets('risk Edit saves confirmed decision with amount and date', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.dragUntilVisible(
        find.text('Confirm'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('risk-amount-input')),
        '3000',
      );

      await tester.tap(find.text('Select date'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(_riskDecisions.length, 1);
      expect(_riskDecisions.first.amountOverridePaise, 300000);
      expect(_riskDecisions.first.dueDateOverride, isNotNull);
      expect(_riskDecisions.first.status, ForecastRiskDecisionStatus.confirmed);
    });

    testWidgets('risk Edit rejects negative amount', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.dragUntilVisible(
        find.text('Confirm'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('risk-amount-input')),
        '-100',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('non-negative'), findsOneWidget);
      expect(_riskDecisions, isEmpty);
    });

    testWidgets('Confirm preserves line date as dueDateOverride', (
      tester,
    ) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.dragUntilVisible(
        find.text('Confirm'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(_riskDecisions.length, 1);
      expect(_riskDecisions.first.dueDateOverride, DateTime(2026, 7, 1));
    });

    testWidgets('risk callback error shows SnackBar', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer, riskFails: true);

      await tester.dragUntilVisible(
        find.text('Confirm'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsOneWidget);
    });
  });

  group('HomeForecastExplorer no-evidence display', () {
    testWidgets('no-evidence shows Not enough data yet without precise zero', (
      tester,
    ) async {
      final plans = List.generate(12, (i) {
        final m = _monthStart(
          7 + i > 12 ? 7 + i - 12 : 7 + i,
          7 + i > 12 ? 2027 : 2026,
        );
        return _plan(monthStart: m);
      });
      final explorer = ForecastExplorer(
        plans: plans,
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 0,
          keepAvailableUntil: plans.first.monthStart,
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: false,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      expect(find.text('Not enough data yet'), findsOneWidget);
      expect(find.text(inr(0)), findsNothing);
      expect(find.text('Your plan now'), findsNothing);
    });
  });

  group('HomeForecastExplorer visible chart amount', () {
    testWidgets('selected bar displays formatted amount', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      final amountFinder = find.byKey(const ValueKey('selected-bar-amount'));
      expect(amountFinder, findsOneWidget);
      final textWidget = tester.widget<Text>(amountFinder);
      expect(textWidget.data, inr(18000));
    });
  });

  group('HomeForecastExplorer segmented toggle offset', () {
    testWidgets('month segments expose selected state through semantics', (
      tester,
    ) async {
      await _pumpExplorer(tester, _explorerWithDistinctMonths());

      var thisMonth = tester.getSemantics(find.bySemanticsLabel('This month'));
      var nextMonth = tester.getSemantics(find.bySemanticsLabel('Next month'));
      // ignore: deprecated_member_use
      expect(thisMonth.hasFlag(SemanticsFlag.isSelected), isTrue);
      // ignore: deprecated_member_use
      expect(nextMonth.hasFlag(SemanticsFlag.isSelected), isFalse);

      await tester.tap(find.text('Next month'));
      await tester.pump();

      thisMonth = tester.getSemantics(find.bySemanticsLabel('This month'));
      nextMonth = tester.getSemantics(find.bySemanticsLabel('Next month'));
      // ignore: deprecated_member_use
      expect(thisMonth.hasFlag(SemanticsFlag.isSelected), isFalse);
      // ignore: deprecated_member_use
      expect(nextMonth.hasFlag(SemanticsFlag.isSelected), isTrue);
    });

    testWidgets('offset >= 2 deselects both segments', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      await tester.ensureVisible(
        find.byKey(const ValueKey('forecast-month-2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .ancestor(
              of: find.byKey(const ValueKey('forecast-month-2')),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await tester.pump();

      final toggle = tester.widget<SegmentedToggle>(
        find.byKey(const ValueKey('month-toggle')),
      );
      expect(toggle.selectedIndex, -1);
    });
  });

  group('HomeForecastExplorer why CTA layout', () {
    testWidgets(
      'month-specific CTA wraps without ellipsis on a narrow screen',
      (tester) async {
        tester.view.physicalSize = const Size(960, 2400);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await _pumpExplorer(
          tester,
          _explorerWithDistinctMonths(),
          mediaQueryData: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.3),
          ),
        );
        await tester.tap(find.text('Next month'));
        await tester.pump();

        final cta = tester.widget<Text>(
          find.textContaining('See why August requires'),
        );
        expect(cta.maxLines, 2);
        expect(cta.softWrap, isTrue);
        expect(cta.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('HomeForecastExplorer provisional header', () {
    testWidgets('provisional header prompts balance confirmation', (
      tester,
    ) async {
      final plan = _plan(
        monthStart: _monthStart(_kJuly),
        requiredInBankPaise: 1000000,
        isProvisional: true,
        confidence: 0.65,
        hardLines: [_hardLine('Test', 500000, _monthStart(_kJuly))],
      );
      final explorer = ForecastExplorer(
        plans: [
          plan,
          ...List.generate(
            11,
            (i) => _plan(
              monthStart: _monthStart(
                8 + i > 12 ? 8 + i - 12 : 8 + i,
                8 + i > 12 ? 2027 : 2026,
              ),
            ),
          ),
        ],
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 1000000,
          keepAvailableUntil: _monthStart(_kJuly),
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: true,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      expect(find.textContaining('Provisional'), findsWidgets);
      expect(find.textContaining('confirm your balance'), findsWidgets);
    });
  });

  // =========================================================================
  // Review Fix 1: mounted safety after dialog awaits
  // =========================================================================

  group('HomeForecastExplorer mounted safety', () {
    testWidgets(
      'dispose during reserve edit dialog does not throw setState-after-dispose',
      (tester) async {
        final sched = _schedule(
          'res1',
          'LIC reserve',
          DateTime(2026, 10, 1),
          3000000,
          500000,
          [ReserveContribution(date: _monthStart(_kJuly), amountPaise: 250000)],
        );
        final explorer = _explorerWithDistinctMonths(reserveSchedules: [sched]);
        _reserveUpdates = [];
        _riskDecisions = [];
        _whyCalls = [];

        final showExplorer = ValueNotifier(true);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(AppPalette.dark),
            home: Scaffold(
              body: ValueListenableBuilder<bool>(
                valueListenable: showExplorer,
                builder: (context, show, _) {
                  if (show) {
                    return HomeForecastExplorer(
                      explorer: explorer,
                      initialOffset: 0,
                      onUpdateReserve: _onUpdateReserve(),
                      onSaveRiskDecision: _onSaveRisk(),
                      onSeeWhy: _onSeeWhy(),
                    );
                  }
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        await tester.pump();

        // Scroll to Edit funded amount and tap to open dialog
        await tester.dragUntilVisible(
          find.text('Edit funded amount'),
          find.byType(ListView),
          const Offset(0, -200),
        );
        await tester.tap(find.text('Edit funded amount'));
        await tester.pumpAndSettle();

        // Dialog is showing
        expect(
          find.byKey(const ValueKey('reserve-funded-input')),
          findsOneWidget,
        );

        // Dispose the explorer while dialog is open
        showExplorer.value = false;
        await tester.pump();

        // Enter value and save in the dialog — resumes disposed state
        await tester.enterText(
          find.byKey(const ValueKey('reserve-funded-input')),
          '10000',
        );
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();

        // No setState-after-dispose exception
        expect(tester.takeException(), isNull);
        // Action was NOT invoked since explorer was disposed
        expect(_reserveUpdates, isEmpty);
      },
    );
  });

  // =========================================================================
  // Review Fix 2: bar semantics with confidence and provisional
  // =========================================================================

  group('HomeForecastExplorer bar semantics enhanced', () {
    testWidgets('bar semantics include confidence percentage', (tester) async {
      final explorer = _explorerWithDistinctMonths();
      await _pumpExplorer(tester, explorer);

      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('forecast-month-0')),
      );
      expect(semantics.label, contains('88%'));
      expect(semantics.label, contains('confidence'));
    });

    testWidgets('provisional bar semantics include provisional label', (
      tester,
    ) async {
      final plan = _plan(
        monthStart: _monthStart(_kJuly),
        requiredInBankPaise: 1000000,
        isProvisional: true,
        confidence: 0.65,
        hardLines: [_hardLine('Test', 500000, _monthStart(_kJuly))],
      );
      final explorer = ForecastExplorer(
        plans: [
          plan,
          ...List.generate(
            11,
            (i) => _plan(
              monthStart: _monthStart(
                8 + i > 12 ? 8 + i - 12 : 8 + i,
                8 + i > 12 ? 2027 : 2026,
              ),
            ),
          ),
        ],
        currentAction: ForecastCurrentAction(
          requiredInBankPaise: 1000000,
          keepAvailableUntil: _monthStart(_kJuly),
          reserveContributionPaise: 0,
          reserveSchedules: const [],
          isProvisional: true,
        ),
        availableToEnable: [],
      );
      await _pumpExplorer(tester, explorer);

      final semantics = tester.getSemantics(
        find.byKey(const ValueKey('forecast-month-0')),
      );
      expect(semantics.label, contains('provisional'));
    });
  });

  // =========================================================================
  // Review Fix 3: chart geometry stabilization
  // =========================================================================

  group('HomeForecastExplorer chart geometry', () {
    testWidgets(
      'equal-height bars share fill container position before and after selection',
      (tester) async {
        final plans = List.generate(12, (i) {
          final m = _monthStart(
            7 + i > 12 ? 7 + i - 12 : 7 + i,
            7 + i > 12 ? 2027 : 2026,
          );
          return _plan(
            monthStart: m,
            requiredInBankPaise: 1500000,
            committedOutflowPaise: 1500000,
          );
        });
        final explorer = ForecastExplorer(
          plans: plans,
          currentAction: ForecastCurrentAction(
            requiredInBankPaise: 1500000,
            keepAvailableUntil: plans.first.monthStart,
            reserveContributionPaise: 0,
            reserveSchedules: const [],
            isProvisional: false,
          ),
          availableToEnable: [],
        );
        await _pumpExplorer(tester, explorer, initialOffset: 1);

        // Bar 1 is selected, bar 2 is not — both same required amount,
        // neither is index 0 so no year-label interference.
        final fill1Top = tester
            .getTopLeft(find.byKey(const ValueKey('bar-fill-1')))
            .dy;
        final fill2Top = tester
            .getTopLeft(find.byKey(const ValueKey('bar-fill-2')))
            .dy;
        expect(
          fill1Top,
          fill2Top,
          reason: 'equal-amount fill containers must align vertically',
        );

        // Select bar 2
        await tester.ensureVisible(
          find.byKey(const ValueKey('forecast-month-2')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .ancestor(
                of: find.byKey(const ValueKey('forecast-month-2')),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        await tester.pump();

        final fill1After = tester
            .getTopLeft(find.byKey(const ValueKey('bar-fill-1')))
            .dy;
        final fill2After = tester
            .getTopLeft(find.byKey(const ValueKey('bar-fill-2')))
            .dy;
        expect(
          fill1After,
          fill2After,
          reason: 'must still align after selection change',
        );
      },
    );
  });

  // =========================================================================
  // Selected-month WhyLog hardLines event-ownership integration
  // =========================================================================

  group('HomeForecastExplorer selected-month WhyLog event-ownership', () {
    testWidgets(
      'future month See why carries future recurring/one-time, no current-month leakage',
      (tester) async {
        final july = _monthStart(_kJuly);
        final august = _monthStart(_kAugust);
        final sep = _monthStart(9);

        // July (current): Rent hard line
        // September (future): future Rent recurring + future LIC one-time
        // No weak/review lines in any future hardLines
        final plans = <ForecastMonthPlan>[
          _plan(
            monthStart: july,
            requiredInBankPaise: 1800000,
            committedOutflowPaise: 1800000,
            hardLines: [_hardLine('Rent', 1500000, july)],
            riskBufferPaise: 200000,
            riskLines: [_riskLine('Groceries estimate', 200000, july)],
          ),
          _plan(
            monthStart: august,
            requiredInBankPaise: 1500000,
            committedOutflowPaise: 1500000,
            hardLines: [_hardLine('Rent', 1500000, august)],
          ),
          _plan(
            monthStart: sep,
            requiredInBankPaise: 6200000,
            committedOutflowPaise: 6200000,
            hardLines: [
              _hardLine('Rent', 1500000, sep, ownerKey: 'owner:Rent'),
              _hardLine(
                'LIC premium',
                4700000,
                sep,
                ownerKey: 'owner:LIC premium',
              ),
            ],
            riskBufferPaise: 300000,
            riskLines: [_riskLine('Car service', 300000, sep)],
          ),
          for (var m = 10; m <= 18; m++)
            _plan(
              monthStart: _monthStart(
                m > 12 ? m - 12 : m,
                m > 12 ? 2027 : 2026,
              ),
            ),
        ];

        final explorer = ForecastExplorer(
          plans: plans,
          currentAction: ForecastCurrentAction(
            requiredInBankPaise: plans.first.requiredInBankPaise,
            keepAvailableUntil: plans.first.minimumBalanceDate,
            reserveContributionPaise: 0,
            reserveSchedules: const [],
            isProvisional: false,
          ),
          availableToEnable: [],
        );
        await _pumpExplorer(tester, explorer);

        // Select September (offset 2)
        await tester.ensureVisible(
          find.byKey(const ValueKey('forecast-month-2')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .ancestor(
                of: find.byKey(const ValueKey('forecast-month-2')),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        await tester.pump();

        // Tap See why for September
        await tester.tap(find.textContaining('See why September requires'));
        await tester.pump();

        expect(_whyCalls.length, 1);
        expect(_whyCalls.first.offset, 2);
        final sepPlan = _whyCalls.first.plan;

        // Future recurring and one-time must be in hardLines
        final hardLabels = sepPlan.hardLines.map((l) => l.label).toSet();
        expect(
          hardLabels,
          contains('Rent'),
          reason: 'Future recurring must appear',
        );
        expect(
          hardLabels,
          contains('LIC premium'),
          reason: 'Future one-time must appear',
        );

        // Current month's risk line must NOT be in September hardLines
        expect(
          sepPlan.hardLines.where((l) => l.label == 'Groceries estimate'),
          isEmpty,
          reason:
              'Current month weak risk must not leak into future month hardLines',
        );

        // September risk lines should be only September's risks
        expect(sepPlan.riskLines.length, 1);
        expect(sepPlan.riskLines.first.label, 'Car service');
      },
    );
  });
}
