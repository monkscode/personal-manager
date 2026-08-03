import 'package:flutter_test/flutter_test.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/forecast_explorer.dart';
import 'package:expense_insight/services/reserve_planner.dart';

void main() {
  group('ForecastExplorer', () {
    test('required in bank uses dated prefix flow, not account shortfall', () {
      final outlook = _buildOutlook(
        events: [
          _outflow(DateTime(2026, 8, 5), 1800000),
          _inflow(DateTime(2026, 8, 10), 8500000),
        ],
        openingPaise: 10000000,
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final plan = explorer.plans.first;
      expect(plan.requiredInBankPaise, 1800000);
      expect(plan.shortfallPaise, 0);
    });

    test('current and next plans retain their own values and drivers', () {
      final outlook = _buildOutlookWithMonthlyOutflows([1800000, 4700000]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(explorer.planAt(0).requiredInBankPaise, 1800000);
      expect(explorer.planAt(1).requiredInBankPaise, 4700000);
      expect(explorer.planAt(0).monthStart, DateTime(2026, 7, 1));
      expect(explorer.planAt(1).monthStart, DateTime(2026, 8, 1));
    });

    test('risk buffer and reserve contribution stay separate', () {
      // Build outlook with risk lines for August
      final july = DateTime(2026, 7, 1);
      final august = DateTime(2026, 8, 1);
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 9000000,
        minimumBalancePaise: 9000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 9000000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          _monthResult(july, 10000000, []),
          _monthResult(august, 10000000, [_outflow(august, 240000)]),
          ..._emptyMonths(10, DateTime(2026, 9, 1)),
        ],
        riskLines: [
          ForecastLine(
            label: 'Weak expense',
            amountPaise: 240000,
            source: ForecastEventSource.seasonal,
            date: august,
            ownerKey: 'risk1',
            status: ForecastLineStatus.review,
            confidence: 0.4,
          ),
        ],
      );

      // Build reserve plan with contribution in August
      final reserveSchedule = ReserveSchedule(
        dedupeKey: 'reserve1',
        label: 'Test Reserve',
        dueDate: DateTime(2026, 10, 1),
        targetPaise: 3000000,
        fundedPaise: 0,
        remainingPaise: 3000000,
        contributions: [ReserveContribution(date: august, amountPaise: 750000)],
        isFullyFunded: false,
        isOverdue: false,
      );
      final reservePlan = ReservePlan(
        schedules: [reserveSchedule],
        availableToEnable: const [],
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: reservePlan,
        now: DateTime(2026, 7, 22),
      );
      final augustPlan = explorer.planAt(1);
      expect(augustPlan.riskBufferPaise, 240000);
      expect(augustPlan.reserveContributionPaise, 750000);
      expect(augustPlan.requiredInBankPaise, isNot(240000 + 750000));
    });

    test('produces exactly 12 plans', () {
      final outlook = _buildOutlookWithMonthlyOutflows(List.filled(12, 100000));
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(explorer.plans.length, 12);
    });

    test('planAt throws RangeError for invalid offset', () {
      final outlook = _buildOutlookWithMonthlyOutflows([100000]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(() => explorer.planAt(-1), throwsRangeError);
      expect(() => explorer.planAt(12), throwsRangeError);
    });

    test('equal months are legitimate and allowed', () {
      // Two consecutive months with identical required amounts
      final outlook = _buildOutlookWithMonthlyOutflows([1500000, 1500000]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(explorer.planAt(0).requiredInBankPaise, 1500000);
      expect(explorer.planAt(1).requiredInBankPaise, 1500000);
    });

    test('provisional carry-forward confidence', () {
      final july = DateTime(2026, 7, 1);
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 9000000,
        minimumBalancePaise: 9000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: true, // Provisional state
        anchorConfirmLabel: 'Confirm balance',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 9000000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: List.generate(
          12,
          (i) => _monthResult(DateTime(2026, 7 + i, 1), 10000000, []),
        ),
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(explorer.planAt(0).isProvisional, true);
      expect(explorer.currentAction.isProvisional, true);
    });

    test('no-data state does not become confident zero', () {
      // Month with no events should show appropriate confidence
      final outlook = _buildOutlookWithMonthlyOutflows([0]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final plan = explorer.planAt(0);
      // With no events, required should be 0 but we shouldn't claim high confidence
      expect(plan.requiredInBankPaise, 0);
      expect(plan.confidence, lessThan(1.0));
    });

    test('throws StateError when outlook does not have exactly 12 months', () {
      final july = DateTime(2026, 7, 1);
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [_monthResult(july, 10000000, [])], // Only 1 month!
      );
      expect(
        () => buildForecastExplorer(
          outlook: outlook,
          reservePlan: const ReservePlan.empty(),
          now: DateTime(2026, 7, 22),
        ),
        throwsStateError,
      );
    });

    test('deterministic tie ordering: same date outflows before inflows', () {
      final outlook = _buildOutlook(
        events: [
          _inflow(DateTime(2026, 8, 10), 5000000),
          _outflow(DateTime(2026, 8, 10), 2000000),
        ],
        openingPaise: 1000000,
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final plan = explorer.plans.first;
      // Outflow happens first on same day: zero-based minimum is -2M, so need 2M
      expect(plan.requiredInBankPaise, 2000000);
    });

    test('hard, reserve, and risk remain separate', () {
      final july = DateTime(2026, 7, 1);
      final august = DateTime(2026, 8, 1);
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 8000000,
        minimumBalancePaise: 8000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 1000000,
          expectedSalaryPaise: 0,
          freePaise: 8000000,
        ),
        lines: [
          ForecastLine(
            label: 'Hard expense',
            amountPaise: 1000000,
            source: ForecastEventSource.recurring,
            date: august,
            ownerKey: 'hard1',
            status: ForecastLineStatus.unpaid,
            confidence: 0.9,
          ),
        ],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          _monthResult(july, 10000000, []),
          _monthResult(august, 10000000, [_outflow(august, 1000000)]),
          ..._emptyMonths(10, DateTime(2026, 9, 1)),
        ],
        riskLines: [
          ForecastLine(
            label: 'Weak expense',
            amountPaise: 500000,
            source: ForecastEventSource.seasonal,
            date: august,
            ownerKey: 'risk1',
            status: ForecastLineStatus.review,
            confidence: 0.4,
          ),
        ],
      );

      final reserveSchedule = ReserveSchedule(
        dedupeKey: 'reserve1',
        label: 'Test Reserve',
        dueDate: DateTime(2026, 10, 1),
        targetPaise: 3000000,
        fundedPaise: 0,
        remainingPaise: 3000000,
        contributions: [ReserveContribution(date: august, amountPaise: 300000)],
        isFullyFunded: false,
        isOverdue: false,
      );
      final reservePlan = ReservePlan(
        schedules: [reserveSchedule],
        availableToEnable: const [],
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: reservePlan,
        now: DateTime(2026, 7, 22),
      );
      final augustPlan = explorer.planAt(1);

      // Hard lines
      expect(augustPlan.hardLines.length, 1);
      expect(augustPlan.hardLines.first.amountPaise, 1000000);

      // Risk lines
      expect(augustPlan.riskLines.length, 1);
      expect(augustPlan.riskLines.first.amountPaise, 500000);

      // Reserve
      expect(augustPlan.reserveContributionPaise, 300000);
      expect(augustPlan.reserveSchedules.length, 1);

      // They should remain separate
      expect(augustPlan.riskBufferPaise, 500000);
      expect(augustPlan.committedOutflowPaise, 1000000);
    });

    test('month-specific lines and schedules', () {
      final july = DateTime(2026, 7, 1);
      final august = DateTime(2026, 8, 1);
      final september = DateTime(2026, 9, 1);

      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 8000000,
        minimumBalancePaise: 8000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 8000000,
        ),
        lines: [
          ForecastLine(
            label: 'Aug expense',
            amountPaise: 1000000,
            source: ForecastEventSource.recurring,
            date: august,
            ownerKey: 'aug1',
            status: ForecastLineStatus.unpaid,
            confidence: 0.9,
          ),
          ForecastLine(
            label: 'Sep expense',
            amountPaise: 2000000,
            source: ForecastEventSource.recurring,
            date: september,
            ownerKey: 'sep1',
            status: ForecastLineStatus.unpaid,
            confidence: 0.9,
          ),
        ],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          _monthResult(july, 10000000, []),
          _monthResult(august, 10000000, [
            ForecastEvent(
              date: august,
              amountPaise: 1000000,
              direction: LedgerDirection.outflow,
              source: ForecastEventSource.recurring,
              ownerKey: 'aug1',
              label: 'Aug expense',
              confidence: 0.9,
            ),
          ]),
          _monthResult(september, 9000000, [
            ForecastEvent(
              date: september,
              amountPaise: 2000000,
              direction: LedgerDirection.outflow,
              source: ForecastEventSource.recurring,
              ownerKey: 'sep1',
              label: 'Sep expense',
              confidence: 0.9,
            ),
          ]),
          ..._emptyMonths(9, DateTime(2026, 10, 1)),
        ],
        riskLines: const [],
      );

      final reserveSchedule1 = ReserveSchedule(
        dedupeKey: 'reserve1',
        label: 'Reserve Aug',
        dueDate: DateTime(2026, 10, 1),
        targetPaise: 3000000,
        fundedPaise: 0,
        remainingPaise: 3000000,
        contributions: [ReserveContribution(date: august, amountPaise: 500000)],
        isFullyFunded: false,
        isOverdue: false,
      );
      final reserveSchedule2 = ReserveSchedule(
        dedupeKey: 'reserve2',
        label: 'Reserve Sep',
        dueDate: DateTime(2026, 11, 1),
        targetPaise: 2000000,
        fundedPaise: 0,
        remainingPaise: 2000000,
        contributions: [
          ReserveContribution(date: september, amountPaise: 400000),
        ],
        isFullyFunded: false,
        isOverdue: false,
      );
      final reservePlan = ReservePlan(
        schedules: [reserveSchedule1, reserveSchedule2],
        availableToEnable: const [],
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: reservePlan,
        now: DateTime(2026, 7, 22),
      );

      // August should only have August lines and schedules
      final augustPlan = explorer.planAt(1);
      expect(augustPlan.hardLines.length, 1);
      expect(augustPlan.hardLines.first.label, 'Aug expense');
      expect(augustPlan.reserveSchedules.length, 1);
      expect(augustPlan.reserveSchedules.first.label, 'Reserve Aug');

      // September should only have September lines and schedules
      final septemberPlan = explorer.planAt(2);
      expect(septemberPlan.hardLines.length, 1);
      expect(septemberPlan.hardLines.first.label, 'Sep expense');
      expect(septemberPlan.reserveSchedules.length, 1);
      expect(septemberPlan.reserveSchedules.first.label, 'Reserve Sep');
    });

    test('current action uses first month data', () {
      final outlook = _buildOutlookWithMonthlyOutflows([1800000, 4700000]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      expect(explorer.currentAction.requiredInBankPaise, 1800000);
      // Should use actual minimumBalanceDate, not next month boundary
      expect(
        explorer.currentAction.keepAvailableUntil,
        explorer.planAt(0).minimumBalanceDate,
      );
    });

    test(
      'current action keepAvailableUntil uses actual minimum balance date',
      () {
        // Critical finding: should use firstPlan.minimumBalanceDate, not next month
        final outlook = _buildOutlook(
          events: [
            _outflow(DateTime(2026, 7, 5), 1800000),
            _inflow(DateTime(2026, 7, 10), 8500000),
          ],
          openingPaise: 10000000,
        );
        final explorer = buildForecastExplorer(
          outlook: outlook,
          reservePlan: const ReservePlan.empty(),
          now: DateTime(2026, 7, 22),
        );
        // Should use the actual date of maximum pressure (July 5), not Aug 1
        expect(explorer.currentAction.keepAvailableUntil, DateTime(2026, 7, 5));
      },
    );

    test('month plan preserves coverage lines from forecast month result', () {
      // Important finding: _coverageLinesForMonth returns empty but should use month.coverageLines
      final july = DateTime(2026, 7, 1);
      final coverageLine = ForecastCoverageLine(
        label: 'Seasonal buffer',
        amountPaise: 500000,
        reason: CoverageReason.reviewNeeded,
        action: CoverageAction.review,
        confidence: 0.7,
      );

      final monthResult = ForecastMonthResult(
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        events: const [],
        coverageLines: [coverageLine],
        anchor: _anchor(10000000, july),
        anchorFreshness: AnchorFreshness.current,
        lines: const [],
      );

      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: const [],
        coverageLines: [coverageLine],
        forwardEarmarks: const [],
        assignments: const [],
        months: [monthResult, ..._emptyMonths(11, DateTime(2026, 8, 1))],
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );

      final julyPlan = explorer.planAt(0);
      expect(julyPlan.coverageLines.length, 1);
      expect(julyPlan.coverageLines.first.label, 'Seasonal buffer');
      expect(julyPlan.coverageLines.first.amountPaise, 500000);
    });

    test(
      'confidence uses all evidence: opening line, events, coverage, and risk',
      () {
        // Important finding: confidence should use opening line + all evidence, not just events
        final july = DateTime(2026, 7, 1);

        // Opening line with low confidence (0.2)
        final openingLine = ForecastLine(
          label: 'Opening balance carry-forward',
          amountPaise: 10000000,
          source: ForecastEventSource.currentActual,
          date: july,
          ownerKey: 'opening',
          status: ForecastLineStatus.opening,
          confidence: 0.2, // Low opening confidence
        );

        // High confidence event (0.9)
        final highConfEvent = _outflow(DateTime(2026, 7, 10), 500000);

        // Coverage line with medium confidence (0.5)
        final coverageLine = ForecastCoverageLine(
          label: 'Seasonal buffer',
          amountPaise: 300000,
          reason: CoverageReason.reviewNeeded,
          action: CoverageAction.review,
          confidence: 0.5,
        );

        // Risk line with low confidence (0.3)
        final riskLine = ForecastLine(
          label: 'Uncertain expense',
          amountPaise: 200000,
          source: ForecastEventSource.seasonal,
          date: july,
          ownerKey: 'risk1',
          status: ForecastLineStatus.review,
          confidence: 0.3,
        );

        final monthResult = ForecastMonthResult(
          openingBalancePaise: 10000000,
          closingBalancePaise: 9500000,
          minimumBalancePaise: 9500000,
          minimumBalanceDate: DateTime(2026, 7, 10),
          shortfallPaise: 0,
          events: [highConfEvent],
          coverageLines: [coverageLine],
          anchor: _anchor(10000000, july),
          anchorFreshness: AnchorFreshness.current,
          lines: [openingLine], // Opening line with low confidence
        );

        final outlook = ForecastOutlook(
          targetMonth: july,
          anchor: _anchor(10000000, july),
          openingBalancePaise: 10000000,
          closingBalancePaise: 9500000,
          minimumBalancePaise: 9500000,
          minimumBalanceDate: DateTime(2026, 7, 10),
          shortfallPaise: 0,
          headline: 'OK',
          isProvisional: false,
          anchorConfirmLabel: '',
          salaryMissing: false,
          isSeasonalBufferShortfall: false,
          salary: const ForecastSalaryStrip(
            committedPaise: 500000,
            expectedSalaryPaise: 0,
            freePaise: 9500000,
          ),
          lines: [openingLine],
          coverageLines: [coverageLine],
          forwardEarmarks: const [],
          assignments: const [],
          months: [monthResult, ..._emptyMonths(11, DateTime(2026, 8, 1))],
          riskLines: [riskLine],
        );

        final explorer = buildForecastExplorer(
          outlook: outlook,
          reservePlan: const ReservePlan.empty(),
          now: DateTime(2026, 7, 22),
        );

        final julyPlan = explorer.planAt(0);
        // Confidence should be minimum of all evidence:
        // opening (0.2), event (0.9), coverage (0.5), risk (0.3)
        // Minimum is 0.2 from opening line
        expect(julyPlan.confidence, 0.2);
      },
    );

    test('availableToEnable flows through as immutable list', () {
      // Task 7 prerequisite: ForecastExplorer must expose availableToEnable
      // so Home can render Start reserve actions
      final candidate = ReserveCandidate(
        dedupeKey: 'reserve-candidate-1',
        label: 'Insurance Reserve',
        dueDate: DateTime(2026, 12, 1),
        targetPaise: 5000000,
      );
      final sourceList = [candidate];
      final reservePlan = ReservePlan(
        schedules: const [],
        availableToEnable: sourceList,
      );
      final outlook = _buildOutlookWithMonthlyOutflows([100000]);
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: reservePlan,
        now: DateTime(2026, 7, 22),
      );

      // Explorer must contain the candidate
      expect(explorer.availableToEnable.length, 1);
      expect(explorer.availableToEnable.first.dedupeKey, 'reserve-candidate-1');
      expect(explorer.availableToEnable.first.label, 'Insurance Reserve');
      expect(explorer.availableToEnable.first.targetPaise, 5000000);

      // Mutating source list after build must not affect explorer (immutability)
      sourceList.clear();
      expect(
        explorer.availableToEnable.length,
        1,
        reason:
            'Explorer must be immutable; source mutation should not affect it',
      );
    });

    test('month identity uses targetMonth offset, not minimumBalanceDate', () {
      // Regression: buildForecastExplorer used _normalizeMonth(minimumBalanceDate)
      // which shifts plan[0] identity when minimumBalanceDate falls in a later month.
      final august = DateTime(2026, 8, 1);
      // Construct month result where minimumBalanceDate is in September
      final monthResultAug = ForecastMonthResult(
        openingBalancePaise: 500000,
        closingBalancePaise: 7200000,
        minimumBalancePaise: -1300000,
        minimumBalanceDate: DateTime(2026, 9, 15), // outside August!
        shortfallPaise: 1300000,
        events: [
          _outflow(DateTime(2026, 8, 5), 1800000),
          _inflow(DateTime(2026, 8, 10), 8500000),
        ],
        coverageLines: const [],
        anchor: _anchor(500000, august),
        anchorFreshness: AnchorFreshness.current,
        lines: const [],
      );

      final outlook = ForecastOutlook(
        targetMonth: august,
        anchor: _anchor(500000, august),
        openingBalancePaise: 500000,
        closingBalancePaise: 7200000,
        minimumBalancePaise: -1300000,
        minimumBalanceDate: DateTime(2026, 9, 15),
        shortfallPaise: 1300000,
        headline: 'Short',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 1800000,
          expectedSalaryPaise: 0,
          freePaise: 7200000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [monthResultAug, ..._emptyMonths(11, DateTime(2026, 9, 1))],
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 8, 1),
      );

      // Plan[0] must be August (targetMonth + 0), NOT September
      expect(explorer.planAt(0).monthStart, DateTime(2026, 8, 1));
      // Plan[1] must be September (targetMonth + 1)
      expect(explorer.planAt(1).monthStart, DateTime(2026, 9, 1));
      // minimumBalanceDate preserved separately
      expect(explorer.planAt(0).minimumBalanceDate, DateTime(2026, 9, 15));
    });

    test('all 12 plan monthStarts match targetMonth + offset exactly', () {
      final march = DateTime(2026, 3, 1);
      final outlook = ForecastOutlook(
        targetMonth: march,
        anchor: _anchor(10000000, march),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: march,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: List.generate(
          12,
          (i) => _monthResult(DateTime(2026, 3 + i, 1), 10000000, []),
        ),
      );

      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 3, 1),
      );

      for (var i = 0; i < 12; i++) {
        expect(
          explorer.planAt(i).monthStart,
          DateTime(2026, 3 + i),
          reason: 'plan[$i] monthStart must be targetMonth + $i',
        );
      }
    });
  });

  group('ForecastExplorer hardLines event-ownership', () {
    test(
      'future recurring event absent from outlook.lines appears in future plan hardLines',
      () {
        // outlook.lines only has target-month reconciliation lines.
        // A future month event (Sep recurring) must still show in plan[2].hardLines.
        final july = DateTime(2026, 7, 1);
        final sep = DateTime(2026, 9, 1);
        final sepEvent = ForecastEvent(
          date: DateTime(2026, 9, 5),
          amountPaise: 1500000,
          direction: LedgerDirection.outflow,
          source: ForecastEventSource.recurring,
          ownerKey: 'recurring:rent',
          label: 'Rent',
          confidence: 0.9,
        );
        final outlook = ForecastOutlook(
          targetMonth: july,
          anchor: _anchor(10000000, july),
          openingBalancePaise: 10000000,
          closingBalancePaise: 10000000,
          minimumBalancePaise: 10000000,
          minimumBalanceDate: july,
          shortfallPaise: 0,
          headline: 'OK',
          isProvisional: false,
          anchorConfirmLabel: '',
          salaryMissing: false,
          isSeasonalBufferShortfall: false,
          salary: const ForecastSalaryStrip(
            committedPaise: 0,
            expectedSalaryPaise: 0,
            freePaise: 10000000,
          ),
          lines: const [], // No reconciliation lines for future months
          coverageLines: const [],
          forwardEarmarks: const [],
          assignments: const [],
          months: [
            _monthResult(july, 10000000, []),
            _monthResult(DateTime(2026, 8, 1), 10000000, []),
            _monthResult(sep, 10000000, [sepEvent]),
            ..._emptyMonths(9, DateTime(2026, 10, 1)),
          ],
          riskLines: const [],
        );
        final explorer = buildForecastExplorer(
          outlook: outlook,
          reservePlan: const ReservePlan.empty(),
          now: DateTime(2026, 7, 22),
        );
        final sepPlan = explorer.planAt(2);
        expect(
          sepPlan.hardLines,
          isNotEmpty,
          reason: 'Future event must appear in hardLines via event ownership',
        );
        expect(sepPlan.hardLines.first.ownerKey, 'recurring:rent');
        expect(sepPlan.hardLines.first.amountPaise, 1500000);
      },
    );

    test(
      'weak seasonal in outlook.lines and riskLines but absent from events is risk only',
      () {
        // A target-month seasonal line in outlook.lines with review status is
        // NOT a hard event. It must appear only in riskLines, never hardLines.
        final july = DateTime(2026, 7, 1);
        final weakLine = ForecastLine(
          label: 'Dining out',
          amountPaise: 300000,
          source: ForecastEventSource.seasonal,
          date: DateTime(2026, 7, 15),
          ownerKey: 'seasonal:dining',
          status: ForecastLineStatus.review,
          confidence: 0.4,
        );
        final outlook = ForecastOutlook(
          targetMonth: july,
          anchor: _anchor(10000000, july),
          openingBalancePaise: 10000000,
          closingBalancePaise: 10000000,
          minimumBalancePaise: 10000000,
          minimumBalanceDate: july,
          shortfallPaise: 0,
          headline: 'OK',
          isProvisional: false,
          anchorConfirmLabel: '',
          salaryMissing: false,
          isSeasonalBufferShortfall: false,
          salary: const ForecastSalaryStrip(
            committedPaise: 0,
            expectedSalaryPaise: 0,
            freePaise: 10000000,
          ),
          lines: [weakLine], // Reconciliation produced this review line
          coverageLines: const [],
          forwardEarmarks: const [],
          assignments: const [],
          months: [
            _monthResult(july, 10000000, []), // No hard event for this seasonal
            ..._emptyMonths(11, DateTime(2026, 8, 1)),
          ],
          riskLines: [weakLine],
        );
        final explorer = buildForecastExplorer(
          outlook: outlook,
          reservePlan: const ReservePlan.empty(),
          now: DateTime(2026, 7, 22),
        );
        final julyPlan = explorer.planAt(0);
        expect(julyPlan.riskLines.length, 1);
        expect(julyPlan.riskLines.first.ownerKey, 'seasonal:dining');
        // Must NOT appear in hardLines
        expect(
          julyPlan.hardLines.where((l) => l.ownerKey == 'seasonal:dining'),
          isEmpty,
          reason: 'Weak review line must never leak into hardLines',
        );
      },
    );

    test('target hard reconciliation line preserves unpaid/overdue status', () {
      // When outlook.lines has a richer reconciliation line with unpaid status
      // matching a hard event, hardLines should use that richer line.
      final july = DateTime(2026, 7, 1);
      final richLine = ForecastLine(
        label: 'Electricity',
        amountPaise: 210000,
        source: ForecastEventSource.gmailBill,
        date: DateTime(2026, 7, 10),
        ownerKey: 'gmailBill:elec',
        status: ForecastLineStatus.overdue,
        confidence: 0.95,
        note: 'From BESCOM email',
      );
      final hardEvent = ForecastEvent(
        date: DateTime(2026, 7, 10),
        amountPaise: 210000,
        direction: LedgerDirection.outflow,
        source: ForecastEventSource.gmailBill,
        ownerKey: 'gmailBill:elec',
        label: 'Electricity',
        confidence: 0.95,
      );
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 9790000,
        minimumBalancePaise: 9790000,
        minimumBalanceDate: DateTime(2026, 7, 10),
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 210000,
          expectedSalaryPaise: 0,
          freePaise: 9790000,
        ),
        lines: [richLine],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          ForecastMonthResult(
            openingBalancePaise: 10000000,
            closingBalancePaise: 9790000,
            minimumBalancePaise: 9790000,
            minimumBalanceDate: DateTime(2026, 7, 10),
            shortfallPaise: 0,
            events: [hardEvent],
            coverageLines: const [],
            anchor: _anchor(10000000, july),
            anchorFreshness: AnchorFreshness.current,
            lines: const [],
          ),
          ..._emptyMonths(11, DateTime(2026, 8, 1)),
        ],
        riskLines: const [],
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final julyPlan = explorer.planAt(0);
      expect(julyPlan.hardLines.length, 1);
      expect(
        julyPlan.hardLines.first.status,
        ForecastLineStatus.overdue,
        reason: 'Must preserve richer reconciliation status',
      );
      expect(julyPlan.hardLines.first.note, 'From BESCOM email');
    });

    test('alreadyInAnchor informational lines retained in hardLines', () {
      final july = DateTime(2026, 7, 1);
      final anchorLine = ForecastLine(
        label: 'Old SIP',
        amountPaise: 300000,
        source: ForecastEventSource.recurring,
        date: DateTime(2026, 7, 1),
        ownerKey: 'recurring:oldsip',
        status: ForecastLineStatus.alreadyInAnchor,
        confidence: 1.0,
      );
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: [anchorLine],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          // alreadyInAnchor items are NOT events — they are informational
          _monthResult(july, 10000000, []),
          ..._emptyMonths(11, DateTime(2026, 8, 1)),
        ],
        riskLines: const [],
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final julyPlan = explorer.planAt(0);
      expect(julyPlan.hardLines.length, 1);
      expect(
        julyPlan.hardLines.first.status,
        ForecastLineStatus.alreadyInAnchor,
      );
      expect(julyPlan.hardLines.first.ownerKey, 'recurring:oldsip');
    });

    test('future one-time appears exactly once in due-month hardLines', () {
      // A one-time obligation due in October must appear in plan[3] (Oct)
      // hardLines, and not in any other month's hardLines.
      final july = DateTime(2026, 7, 1);
      final oct = DateTime(2026, 10, 1);
      final oneTimeEvent = ForecastEvent(
        date: DateTime(2026, 10, 15),
        amountPaise: 4700000,
        direction: LedgerDirection.outflow,
        source: ForecastEventSource.gmailBill,
        ownerKey: 'gmailBill:lic',
        label: 'LIC premium',
        confidence: 0.85,
      );
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: const [], // Not in target-month reconciliation
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          _monthResult(july, 10000000, []),
          _monthResult(DateTime(2026, 8, 1), 10000000, []),
          _monthResult(DateTime(2026, 9, 1), 10000000, []),
          _monthResult(oct, 10000000, [oneTimeEvent]),
          ..._emptyMonths(8, DateTime(2026, 11, 1)),
        ],
        riskLines: const [],
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      // October plan (offset 3) must have it
      final octPlan = explorer.planAt(3);
      expect(octPlan.hardLines.length, 1);
      expect(octPlan.hardLines.first.ownerKey, 'gmailBill:lic');
      expect(octPlan.hardLines.first.amountPaise, 4700000);
      // No other month should have it
      for (var i = 0; i < 12; i++) {
        if (i == 3) continue;
        expect(
          explorer
              .planAt(i)
              .hardLines
              .where((l) => l.ownerKey == 'gmailBill:lic'),
          isEmpty,
          reason: 'One-time event must appear only in due-month (plan[$i])',
        );
      }
    });

    test('no duplicate owner/date/amount lines in hardLines', () {
      // When a reconciliation line matches an event, it should not create
      // a duplicate — only the richer reconciliation line should appear.
      final july = DateTime(2026, 7, 1);
      final event = ForecastEvent(
        date: DateTime(2026, 7, 5),
        amountPaise: 1500000,
        direction: LedgerDirection.outflow,
        source: ForecastEventSource.recurring,
        ownerKey: 'recurring:rent',
        label: 'Rent',
        confidence: 0.9,
      );
      final reconLine = ForecastLine(
        label: 'Rent',
        amountPaise: 1500000,
        source: ForecastEventSource.recurring,
        date: DateTime(2026, 7, 5),
        ownerKey: 'recurring:rent',
        status: ForecastLineStatus.unpaid,
        confidence: 0.9,
      );
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 8500000,
        minimumBalancePaise: 8500000,
        minimumBalanceDate: DateTime(2026, 7, 5),
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 1500000,
          expectedSalaryPaise: 0,
          freePaise: 8500000,
        ),
        lines: [reconLine],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          ForecastMonthResult(
            openingBalancePaise: 10000000,
            closingBalancePaise: 8500000,
            minimumBalancePaise: 8500000,
            minimumBalanceDate: DateTime(2026, 7, 5),
            shortfallPaise: 0,
            events: [event],
            coverageLines: const [],
            anchor: _anchor(10000000, july),
            anchorFreshness: AnchorFreshness.current,
            lines: const [],
          ),
          ..._emptyMonths(11, DateTime(2026, 8, 1)),
        ],
        riskLines: const [],
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final julyPlan = explorer.planAt(0);
      // Exactly 1, not duplicated
      expect(julyPlan.hardLines.length, 1);
      expect(julyPlan.hardLines.first.ownerKey, 'recurring:rent');
    });

    test('future salary inflow event appears in future plan hardLines', () {
      final july = DateTime(2026, 7, 1);
      final salaryEvent = ForecastEvent(
        date: DateTime(2026, 9, 1),
        amountPaise: 8500000,
        direction: LedgerDirection.inflow,
        source: ForecastEventSource.salary,
        ownerKey: 'salary:monthly',
        label: 'Salary',
        confidence: 0.9,
      );
      final outlook = ForecastOutlook(
        targetMonth: july,
        anchor: _anchor(10000000, july),
        openingBalancePaise: 10000000,
        closingBalancePaise: 10000000,
        minimumBalancePaise: 10000000,
        minimumBalanceDate: july,
        shortfallPaise: 0,
        headline: 'OK',
        isProvisional: false,
        anchorConfirmLabel: '',
        salaryMissing: false,
        isSeasonalBufferShortfall: false,
        salary: const ForecastSalaryStrip(
          committedPaise: 0,
          expectedSalaryPaise: 0,
          freePaise: 10000000,
        ),
        lines: const [],
        coverageLines: const [],
        forwardEarmarks: const [],
        assignments: const [],
        months: [
          _monthResult(july, 10000000, []),
          _monthResult(DateTime(2026, 8, 1), 10000000, []),
          _monthResult(DateTime(2026, 9, 1), 10000000, [salaryEvent]),
          ..._emptyMonths(9, DateTime(2026, 10, 1)),
        ],
        riskLines: const [],
      );
      final explorer = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 22),
      );
      final sepPlan = explorer.planAt(2);
      expect(
        sepPlan.hardLines,
        isNotEmpty,
        reason: 'Future salary event must appear in hardLines',
      );
      expect(sepPlan.hardLines.first.ownerKey, 'salary:monthly');
    });
  });

  group('TASK-24 M5/M6 — why-log lines and inflow naming', () {
    test('keeps two real events that share owner, date and amount', () {
      // Two genuine ACT Fibernet debits of the same amount on the same day.
      // The ledger subtracts both; the why-log used to key on
      // ownerKey:millis:amount and show one, so the itemisation no longer
      // added up to committedOutflowPaise.
      final july = DateTime(2026, 7, 1);
      final day = DateTime(2026, 7, 12);
      final outlook = _buildOutlook(
        events: [
          ForecastEvent(
            date: day,
            amountPaise: 118000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.recurring,
            ownerKey: 'commitment:actfibernet',
            label: 'Actfibernet',
            confidence: 0.9,
          ),
          ForecastEvent(
            date: day,
            amountPaise: 118000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.recurring,
            ownerKey: 'commitment:actfibernet',
            label: 'Actfibernet',
            confidence: 0.9,
          ),
        ],
        openingPaise: 10000000,
      );
      final plan = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: july,
      ).planAt(0);

      final itemised = plan.hardLines
          .where((l) => l.ownerKey == 'commitment:actfibernet')
          .fold<int>(0, (sum, l) => sum + l.amountPaise);
      expect(plan.committedOutflowPaise, 236000);
      expect(itemised, plan.committedOutflowPaise);
    });

    test('opening + expected inflow - committed outflow == closing', () {
      final outlook = _buildOutlook(
        events: [
          _outflow(DateTime(2026, 7, 5), 1800000),
          _inflow(DateTime(2026, 7, 10), 8500000),
        ],
        openingPaise: 10000000,
      );
      final plan = buildForecastExplorer(
        outlook: outlook,
        reservePlan: const ReservePlan.empty(),
        now: DateTime(2026, 7, 1),
      ).planAt(0);

      expect(
        plan.openingBalancePaise +
            plan.expectedInflowPaise -
            plan.committedOutflowPaise,
        plan.closingBalancePaise,
      );
    });

    test('the salary strip names salary explicitly, not "expected"', () {
      // ForecastMonthPlan.expectedInflowPaise is every inflow;
      // ForecastSalaryStrip counts salary alone. Two meanings for one word,
      // exposed from the same layer, is what the spec forbids.
      const strip = ForecastSalaryStrip(
        committedPaise: 1800000,
        expectedSalaryPaise: 8500000,
        freePaise: 16700000,
      );

      expect(strip.expectedSalaryPaise, 8500000);
    });
  });

}

// Helper builders
ForecastOutlook _buildOutlook({
  required List<ForecastEvent> events,
  required int openingPaise,
}) {
  final july = DateTime(2026, 7, 1);
  final result = _monthResult(july, openingPaise, events);
  return ForecastOutlook(
    targetMonth: july,
    anchor: _anchor(openingPaise, july),
    openingBalancePaise: result.openingBalancePaise,
    closingBalancePaise: result.closingBalancePaise,
    minimumBalancePaise: result.minimumBalancePaise,
    minimumBalanceDate: result.minimumBalanceDate,
    shortfallPaise: result.shortfallPaise,
    headline: 'OK',
    isProvisional: false,
    anchorConfirmLabel: '',
    salaryMissing: false,
    isSeasonalBufferShortfall: false,
    salary: ForecastSalaryStrip(
      committedPaise: 0,
      expectedSalaryPaise: 0,
      freePaise: result.closingBalancePaise,
    ),
    lines: const [],
    coverageLines: const [],
    forwardEarmarks: const [],
    assignments: const [],
    months: [result, ..._emptyMonths(11, DateTime(2026, 8, 1))],
  );
}

ForecastOutlook _buildOutlookWithMonthlyOutflows(List<int> outflowsPerMonth) {
  final july = DateTime(2026, 7, 1);
  final months = <ForecastMonthResult>[];
  var balance = 10000000;

  for (var i = 0; i < 12; i++) {
    final monthStart = DateTime(2026, 7 + i, 1);
    final outflow = i < outflowsPerMonth.length ? outflowsPerMonth[i] : 0;
    final events = outflow > 0
        ? [_outflow(monthStart, outflow)]
        : <ForecastEvent>[];
    final result = _monthResult(monthStart, balance, events);
    months.add(result);
    balance = result.closingBalancePaise;
  }

  return ForecastOutlook(
    targetMonth: july,
    anchor: _anchor(10000000, july),
    openingBalancePaise: months.first.openingBalancePaise,
    closingBalancePaise: months.first.closingBalancePaise,
    minimumBalancePaise: months.first.minimumBalancePaise,
    minimumBalanceDate: months.first.minimumBalanceDate,
    shortfallPaise: months.first.shortfallPaise,
    headline: 'OK',
    isProvisional: false,
    anchorConfirmLabel: '',
    salaryMissing: false,
    isSeasonalBufferShortfall: false,
    salary: ForecastSalaryStrip(
      committedPaise: 0,
      expectedSalaryPaise: 0,
      freePaise: months.first.closingBalancePaise,
    ),
    lines: const [],
    coverageLines: const [],
    forwardEarmarks: const [],
    assignments: const [],
    months: months,
  );
}

ForecastMonthResult _monthResult(
  DateTime month,
  int openingPaise,
  List<ForecastEvent> events,
) {
  // Sort events by date, then outflows before inflows on same date
  final ordered = [...events]
    ..sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;
      // Same date: outflows before inflows
      if (a.direction == LedgerDirection.outflow &&
          b.direction == LedgerDirection.inflow) {
        return -1;
      }
      if (a.direction == LedgerDirection.inflow &&
          b.direction == LedgerDirection.outflow) {
        return 1;
      }
      return 0;
    });

  var balance = openingPaise;
  var minimum = openingPaise;
  var minimumDate = month;

  for (final event in ordered) {
    balance += event.direction == LedgerDirection.inflow
        ? event.amountPaise
        : -event.amountPaise;
    if (balance < minimum) {
      minimum = balance;
      minimumDate = event.date;
    }
  }

  final shortfall = minimum < 0 ? -minimum : 0;

  return ForecastMonthResult(
    openingBalancePaise: openingPaise,
    closingBalancePaise: balance,
    minimumBalancePaise: minimum,
    minimumBalanceDate: minimumDate,
    shortfallPaise: shortfall,
    events: ordered,
    coverageLines: const [],
    anchor: _anchor(openingPaise, month),
    anchorFreshness: AnchorFreshness.current,
    lines: const [],
  );
}

List<ForecastMonthResult> _emptyMonths(int count, DateTime startMonth) {
  return List.generate(count, (i) {
    final month = DateTime(startMonth.year, startMonth.month + i, 1);
    return _monthResult(month, 10000000, []);
  });
}

BalanceAnchor _anchor(int paise, DateTime date) {
  return BalanceAnchor(
    amountPaise: paise,
    asOf: date,
    source: BalanceAnchorSource.smsBankBalance,
  );
}

ForecastEvent _outflow(DateTime date, int paise) {
  return ForecastEvent(
    date: date,
    amountPaise: paise,
    direction: LedgerDirection.outflow,
    source: ForecastEventSource.recurring,
    ownerKey: 'test-${date.millisecondsSinceEpoch}-$paise',
    label: 'Test outflow',
    confidence: 0.9,
  );
}

ForecastEvent _inflow(DateTime date, int paise) {
  return ForecastEvent(
    date: date,
    amountPaise: paise,
    direction: LedgerDirection.inflow,
    source: ForecastEventSource.salary,
    ownerKey: 'test-${date.millisecondsSinceEpoch}-$paise',
    label: 'Test inflow',
    confidence: 0.9,
  );
}
