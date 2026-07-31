import 'package:flutter/material.dart';

import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/real_insights.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/forecast_explorer.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 8, 1);

final _state = const AppState().copyWith(
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

SmsAnalysisSnapshot _snapshotWithCommitments(
  List<RecurringCommitment> commitments, {
  List<ReconciliationItem> items = const [],
  SalaryProfile salary = _salary,
  BalanceAnchor? anchor,
}) => SmsAnalysisSnapshot(
  targetMonth: DateTime(2026, 8),
  hasData: true,
  commitments: commitments,
  reviewCandidates: const [],
  salary: salary,
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

void main() {
  group('computeRealInsights consumes the SMS snapshot', () {
    test(
      'the snapshot path produces the dated forecast, not the manual math',
      () {
        final snap = _snapshot(anchor: _anchor(500000, DateTime(2026, 8, 1)), [
          _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
          _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
        ]);
        final i = computeRealInsights(
          _state,
          snapshot: snap,
          nowOverride: _now,
        );

        // The itemised why-log is populated from the reconciliation engine.
        expect(i.forecastLines, isNotEmpty);
        expect(i.forecastLines.any((l) => l.label == 'Rent'), isTrue);
        // Dated headline drives the hero subtext.
        expect(i.heroSubText, contains('need'));
        expect(i.heroSubText, contains('₹13,000'));
        // Salary strip is populated.
        expect(i.salaryCommitted, '₹18,000');
        expect(i.salaryExpected, '₹85,000');
        expect(i.anchorProvisional, isFalse);
      },
    );

    test(
      'a stale anchor marks the forecast provisional with a confirm label',
      () {
        final snap = _snapshot(
          anchor: _anchor(9000000, DateTime(2026, 7, 15)),
          [_outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5))],
        );
        final i = computeRealInsights(
          _state,
          snapshot: snap,
          nowOverride: _now,
        );

        expect(i.anchorProvisional, isTrue);
        expect(i.anchorConfirmLabel, 'Confirm balance');
      },
    );

    test('a surplus month surfaces a dated forward earmark', () {
      final snap = _snapshot(anchor: _anchor(10000000, DateTime(2026, 8, 1)), [
        _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
        _outflow(
          'lic',
          'LIC premium',
          4700000,
          DateTime(2027, 2, 14),
          owner: ForecastOwner.gmailBill,
        ),
      ]);
      final i = computeRealInsights(_state, snapshot: snap, nowOverride: _now);

      expect(i.forwardEarmarks.any((l) => l.label == 'LIC premium'), isTrue);
    });

    test(
      'Insights.compute routes to the forecast path when the snapshot has data',
      () {
        final snap = _snapshot(anchor: _anchor(500000, DateTime(2026, 8, 1)), [
          _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
        ]);
        final viaCompute = Insights.compute(_state, snapshot: snap, now: _now);
        final direct = computeRealInsights(
          _state,
          snapshot: snap,
          nowOverride: _now,
        );
        expect(viaCompute.heroSubText, direct.heroSubText);
        expect(viaCompute.forecastLines.length, direct.forecastLines.length);
      },
    );

    test('with no snapshot the manual path is unchanged', () {
      final lic = ExpenseEntry(
        name: 'LIC',
        category: 'Insurance',
        categoryKey: 'insurance',
        amount: 47000,
        initial: 'LI',
        color: const Color(0xFFF59E0B),
        recurrence: 'annual',
        dueDate: DateTime(2026, 8, 14),
      );
      final s = _state.copyWith(manualTx: [lic], monthView: 'current');
      final i = computeRealInsights(s, nowOverride: _now);
      expect(i.forecastLines, isEmpty);
      expect(i.heroAmount, '₹47,000');
    });

    test('live Insights exposes distinct current and next plans', () {
      final snap = _snapshot(anchor: _anchor(10000000, DateTime(2026, 8, 1)), [
        _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
        _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
        _outflow('util', 'Utilities', 300000, DateTime(2026, 9, 3)),
      ]);
      final insights = computeRealInsights(
        _state,
        snapshot: snap,
        nowOverride: _now,
      );
      final explorer = insights.forecastExplorer!;
      expect(explorer.planAt(0).monthStart, DateTime(2026, 8));
      expect(explorer.planAt(1).monthStart, DateTime(2026, 9));
      expect(
        explorer.planAt(0).hardLines,
        isNot(same(explorer.planAt(1).hardLines)),
      );
    });

    test('manual mode does not fabricate a live explorer', () {
      final insights = computeRealInsights(_state, nowOverride: _now);
      expect(insights.forecastExplorer, isNull);
    });
  });

  // ---- insurance integration regression ------------------------------------

  group('insurance integration regression (SmsAnalysisSnapshot.reduce path)', () {
    // July 1 2026 — start of month so obligation due-dates are future events.
    // Reserve opportunities span July–Jan before the Feb LIC due.
    final julyNow = DateTime(2026, 7, 1);

    // Transaction history: salary credits for stable detection + a recent
    // balance-bearing transaction for a fresh anchor. No debits — the hard
    // outflows come entirely from confirmed obligations so the commitment
    // detector cannot shadow them at sub-0.8 confidence.
    final history = <ParsedTxn>[
      // Salary credits (months 4-6) for stable detection on account 5678
      for (var m = 4; m <= 6; m++)
        ParsedTxn(
          smsId: 'sal:$m',
          sender: 'VM-ICICIB',
          direction: TransactionDirection.credit,
          instrument: PaymentInstrument.bank,
          type: TxnType.transfer,
          amountPaise: 8500000,
          txnDate: DateTime(2026, m, 10),
          merchant: 'SALARY',
          accountLast4: '5678',
          payeeType: PayeeType.merchant,
          categoryKey: 'salary',
          confidence: 0.95,
          reviewStatus: ReviewStatus.confirmed,
          source: TxnSource.sms,
          coverageBucket: CoverageBucket.datedEvent,
          rawBodyRedacted: 'redacted',
          bodyHash: 'h:sal:$m',
          scanBatchId: 'b',
        ),
      // June 30 balance-bearing transaction → fresh anchor (1 day before now)
      ParsedTxn(
        smsId: 'bal:jun30',
        sender: 'VM-ICICIB',
        direction: TransactionDirection.debit,
        instrument: PaymentInstrument.bank,
        type: TxnType.upi,
        amountPaise: 100000,
        txnDate: DateTime(2026, 6, 30),
        merchant: 'Grocery',
        accountLast4: '5678',
        balancePaise: 12000000, // Rs 1,20,000
        payeeType: PayeeType.merchant,
        categoryKey: 'groceries',
        confidence: 0.95,
        reviewStatus: ReviewStatus.confirmed,
        source: TxnSource.sms,
        coverageBucket: CoverageBucket.datedEvent,
        rawBodyRedacted: 'redacted',
        bodyHash: 'h:bal:jun30',
        scanBatchId: 'b',
      ),
    ];

    final obligations = <ObligationRecord>[
      // Monthly rent Rs 18,000, day 5 — confirmed gmail obligation.
      // Creates hard event in target month (July) only; no commitment
      // projection since there is no debit history for this merchant.
      ObligationRecord(
        sourceType: ObligationSourceType.gmail,
        dedupeKey: 'obl:rent',
        merchant: 'Rent',
        merchantNorm: 'rent',
        categoryKey: 'rent',
        amountPaise: 1800000,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.monthly,
        dueDate: DateTime(2026, 7, 5),
        dueDay: 5,
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.explicitDueDate,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.95,
        reviewStatus: ObligationReviewStatus.confirmed,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 7, 1),
      ),
      // One-time home repair Rs 27,800 due Aug 5 — confirmed gmail obligation.
      // Future-earmark: enters August as a hard event, making August
      // outflow Rs 27,800 vs July outflow Rs 18,000.
      ObligationRecord(
        sourceType: ObligationSourceType.gmail,
        dedupeKey: 'obl:home-repair',
        merchant: 'Home repair',
        merchantNorm: 'home repair',
        categoryKey: 'home',
        amountPaise: 2780000,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.onetime,
        dueDate: DateTime(2026, 8, 5),
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.explicitDueDate,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.95,
        reviewStatus: ObligationReviewStatus.confirmed,
        createdAt: DateTime(2026, 7, 1),
        updatedAt: DateTime(2026, 7, 1),
      ),
      // Annual LIC Rs 60,000 due Feb 12 2027 — confirmed, reserve enabled
      ObligationRecord(
        sourceType: ObligationSourceType.gmail,
        dedupeKey: 'obl:lic-premium-annual',
        merchant: 'LIC premium',
        merchantNorm: 'lic premium',
        categoryKey: 'insurance',
        amountPaise: 6000000,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.annual,
        dueDate: DateTime(2027, 2, 12),
        dueMonth: 2,
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.explicitDueDate,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.95,
        reviewStatus: ObligationReviewStatus.confirmed,
        reserveEnabled: true,
        reserveFundedPaise: 0,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 7, 1),
      ),
    ];

    late Insights insights;
    late ForecastExplorer explorer;

    setUp(() {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: obligations,
        riskDecisions: const [],
        configuredPlans: const [],
        now: julyNow,
      );
      insights = computeRealInsights(
        _state,
        snapshot: snapshot,
        nowOverride: julyNow,
      );
      explorer = insights.forecastExplorer!;
    });

    test('forecastExplorer is non-null with the reduce-path snapshot', () {
      expect(insights.forecastExplorer, isNotNull);
    });

    test(
      'plan 0 (July) and plan 1 (August) have distinct requiredInBankPaise',
      () {
        final july = explorer.planAt(0);
        final august = explorer.planAt(1);
        expect(july.monthStart, DateTime(2026, 7));
        expect(august.monthStart, DateTime(2026, 8));
        // July: rent Rs 18,000 (day 5 before salary day 10) → required ≥ 18,000.
        // August: home repair Rs 27,800 (day 5 before salary day 10) → required ≥ 27,800.
        expect(
          july.requiredInBankPaise,
          greaterThan(0),
          reason: 'July rent on day 5 precedes salary on day 10',
        );
        expect(
          august.requiredInBankPaise,
          greaterThan(0),
          reason: 'August home repair precedes salary',
        );
        expect(
          july.requiredInBankPaise,
          isNot(august.requiredInBankPaise),
          reason:
              'July has Rs 18,000 hard outflow; '
              'August has Rs 27,800 — distinct prefix minimums',
        );
      },
    );

    test(
      'currentAction.reserveContributionPaise is positive (LIC reserve active)',
      () {
        expect(explorer.currentAction.reserveContributionPaise, greaterThan(0));
      },
    );

    test(
      'LIC reserve schedule is visible before Feb with funded/remaining identity',
      () {
        // The LIC reserve schedule should exist somewhere in the plans
        final allReserveSchedules = explorer.plans
            .expand((plan) => plan.reserveSchedules)
            .toList();
        expect(
          allReserveSchedules,
          isNotEmpty,
          reason: 'At least one plan should carry LIC reserve contributions',
        );

        // Find the LIC schedule
        final licSchedules = allReserveSchedules.where(
          (s) => s.dedupeKey == 'obl:lic-premium-annual',
        );
        expect(
          licSchedules,
          isNotEmpty,
          reason: 'LIC reserve schedule should be identifiable by dedupe key',
        );

        final licSchedule = licSchedules.first;
        expect(licSchedule.targetPaise, 6000000);
        expect(licSchedule.fundedPaise, 0);
        expect(licSchedule.remainingPaise, 6000000);
        expect(licSchedule.label, 'LIC premium');
        expect(licSchedule.dueDate, DateTime(2027, 2, 12));
        expect(licSchedule.isFullyFunded, isFalse);

        // Contributions should all be before the due date
        for (final c in licSchedule.contributions) {
          expect(
            c.date.isBefore(DateTime(2027, 2, 12)),
            isTrue,
            reason: 'All contributions must precede the Feb 12 due date',
          );
        }
      },
    );

    test('LIC appears exactly once across all plan hardLines', () {
      final allLicHardLines = explorer.plans
          .expand((plan) => plan.hardLines)
          .where((line) => line.label == 'LIC premium')
          .toList();
      expect(
        allLicHardLines,
        hasLength(1),
        reason: 'LIC should appear in exactly one month (Feb 2027) hard lines',
      );
    });

    test('LIC appears exactly once in the February plan hardLines', () {
      final febPlan = explorer.plans.singleWhere(
        (plan) => plan.monthStart == DateTime(2027, 2),
      );
      final licInFeb = febPlan.hardLines
          .where((line) => line.label == 'LIC premium')
          .toList();
      expect(
        licInFeb,
        hasLength(1),
        reason:
            'February plan should contain exactly one LIC premium hard line',
      );
    });

    test('LIC does not appear in July or August hardLines', () {
      final julyLic = explorer
          .planAt(0)
          .hardLines
          .where((line) => line.label == 'LIC premium');
      final augLic = explorer
          .planAt(1)
          .hardLines
          .where((line) => line.label == 'LIC premium');
      expect(
        julyLic,
        isEmpty,
        reason: 'LIC is due Feb 2027, must not appear in July',
      );
      expect(
        augLic,
        isEmpty,
        reason: 'LIC is due Feb 2027, must not appear in August',
      );
    });

    test(
      'reserve metadata does not become a second outflow (no LIC double-count)',
      () {
        // Count all outflow events across all months labelled LIC
        final allLicEvents = <ForecastLine>[];
        for (final plan in explorer.plans) {
          allLicEvents.addAll(
            plan.hardLines.where((line) => line.label == 'LIC premium'),
          );
        }
        // There should be exactly 1 hard line (the actual due-month event).
        // Reserve contributions are metadata, not additional outflow lines.
        expect(allLicEvents, hasLength(1));
      },
    );

    test('no LIC risk line when confirmed', () {
      final allRiskLines = explorer.plans.expand((plan) => plan.riskLines);
      final licRisk = allRiskLines.where((line) => line.label == 'LIC premium');
      expect(
        licRisk,
        isEmpty,
        reason: 'Confirmed LIC obligation should not appear in risk lines',
      );
    });

    test('February requiredInBank reflects the LIC premium timing', () {
      final febPlan = explorer.plans.singleWhere(
        (plan) => plan.monthStart == DateTime(2027, 2),
      );
      // February has a Rs 60,000 LIC outflow on day 12. With salary projected
      // on day 10, the prefix minimum before salary is 0, then after salary
      // the LIC outflow occurs. The committed outflow must include LIC.
      expect(
        febPlan.committedOutflowPaise,
        greaterThanOrEqualTo(6000000),
        reason:
            'February committed outflow must include the Rs 60,000 LIC premium',
      );
    });
  });

  // ---- confirmed smsRecurring obligation + matching commitment dedup -------

  group('confirmed smsRecurring obligation projects without commitment duplicate', () {
    // A confirmed smsRecurring monthly obligation exists alongside a matching
    // detected commitment at confidence 0.7. The forecast should project one
    // hard recurring line per cadence month — never a duplicate from the
    // commitment — and the obligation must not appear as risk.
    final julyNow = DateTime(2026, 7, 1);

    final history = <ParsedTxn>[
      // Salary credits (months 4-6) for stable detection
      for (var m = 4; m <= 6; m++)
        ParsedTxn(
          smsId: 'sal:$m',
          sender: 'VM-ICICIB',
          direction: TransactionDirection.credit,
          instrument: PaymentInstrument.bank,
          type: TxnType.transfer,
          amountPaise: 8500000,
          txnDate: DateTime(2026, m, 10),
          merchant: 'SALARY',
          accountLast4: '5678',
          payeeType: PayeeType.merchant,
          categoryKey: 'salary',
          confidence: 0.95,
          reviewStatus: ReviewStatus.confirmed,
          source: TxnSource.sms,
          coverageBucket: CoverageBucket.datedEvent,
          rawBodyRedacted: 'redacted',
          bodyHash: 'h:sal:$m',
          scanBatchId: 'b',
        ),
      // Vodafone debit history (months 4-6) → detector will produce a commitment
      for (var m = 4; m <= 6; m++)
        ParsedTxn(
          smsId: 'voda:$m',
          sender: 'VM-ICICIB',
          direction: TransactionDirection.debit,
          instrument: PaymentInstrument.bank,
          type: TxnType.upi,
          amountPaise: 49900,
          txnDate: DateTime(2026, m, 12),
          merchant: 'VODAFONE',
          accountLast4: '5678',
          payeeType: PayeeType.merchant,
          categoryKey: 'telecom',
          confidence: 0.95,
          reviewStatus: ReviewStatus.confirmed,
          source: TxnSource.sms,
          coverageBucket: CoverageBucket.datedEvent,
          rawBodyRedacted: 'redacted',
          bodyHash: 'h:voda:$m',
          scanBatchId: 'b',
        ),
      // Fresh balance anchor
      ParsedTxn(
        smsId: 'bal:jun30',
        sender: 'VM-ICICIB',
        direction: TransactionDirection.debit,
        instrument: PaymentInstrument.bank,
        type: TxnType.upi,
        amountPaise: 100000,
        txnDate: DateTime(2026, 6, 30),
        merchant: 'Grocery',
        accountLast4: '5678',
        balancePaise: 12000000,
        payeeType: PayeeType.merchant,
        categoryKey: 'groceries',
        confidence: 0.95,
        reviewStatus: ReviewStatus.confirmed,
        source: TxnSource.sms,
        coverageBucket: CoverageBucket.datedEvent,
        rawBodyRedacted: 'redacted',
        bodyHash: 'h:bal:jun30',
        scanBatchId: 'b',
      ),
    ];

    final obligations = <ObligationRecord>[
      // Confirmed smsRecurring monthly vodafone obligation
      ObligationRecord(
        sourceType: ObligationSourceType.smsRecurring,
        dedupeKey: 'sms_recurring:vodafone:monthly',
        merchant: 'Vodafone',
        merchantNorm: 'vodafone',
        categoryKey: 'telecom',
        amountPaise: 49900,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.monthly,
        dueDate: DateTime(2026, 7, 12),
        dueDay: 12,
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.lockedCadence,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.7,
        reviewStatus: ObligationReviewStatus.confirmed,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 7, 1),
      ),
      // Monthly rent (gmail) — keep the existing insurance regression set-up
      ObligationRecord(
        sourceType: ObligationSourceType.gmail,
        dedupeKey: 'obl:rent',
        merchant: 'Rent',
        merchantNorm: 'rent',
        categoryKey: 'rent',
        amountPaise: 1800000,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.monthly,
        dueDate: DateTime(2026, 7, 5),
        dueDay: 5,
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.explicitDueDate,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.95,
        reviewStatus: ObligationReviewStatus.confirmed,
        createdAt: DateTime(2026, 5, 1),
        updatedAt: DateTime(2026, 7, 1),
      ),
    ];

    late Insights insights;
    late ForecastExplorer explorer;

    setUp(() {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: obligations,
        riskDecisions: const [],
        configuredPlans: const [],
        now: julyNow,
      );
      insights = computeRealInsights(
        _state,
        snapshot: snapshot,
        nowOverride: julyNow,
      );
      explorer = insights.forecastExplorer!;
    });

    test(
      'future plans contain exactly one Vodafone hard line per cadence month',
      () {
        // Vodafone is monthly → every month from Aug onward should have exactly 1 event.
        for (var offset = 1; offset < explorer.plans.length; offset++) {
          final plan = explorer.planAt(offset);
          final vodafoneLines = plan.hardLines
              .where((l) => l.label.toLowerCase().contains('vodafone'))
              .toList();
          expect(
            vodafoneLines,
            hasLength(1),
            reason:
                'Month offset $offset (${plan.monthStart}) must have exactly one Vodafone hard line',
          );
        }
      },
    );

    test('Vodafone is hard (not risk) despite commitment confidence 0.7', () {
      // The confirmed obligation must force hardness even though the commitment
      // detector's confidence is below kReserveHardConfidence (0.8).
      for (final plan in explorer.plans) {
        final vodafoneRisk = plan.riskLines.where(
          (l) => l.label.toLowerCase().contains('vodafone'),
        );
        expect(
          vodafoneRisk,
          isEmpty,
          reason:
              '${plan.monthStart}: Confirmed obligation must not be in risk lines',
        );
      }
    });

    test('no duplicate Vodafone events per month', () {
      for (final plan in explorer.plans) {
        final vodafoneHard = plan.hardLines
            .where((l) => l.label.toLowerCase().contains('vodafone'))
            .toList();
        expect(
          vodafoneHard.length,
          lessThanOrEqualTo(1),
          reason: '${plan.monthStart}: Must not have duplicate Vodafone events',
        );
      }
    });
  });

  group('upcoming bills only show genuine dated obligations', () {
    test(
      'excludes the seasonal discretionary estimate and includes card bills',
      () {
        final snap = _snapshot(
          anchor: _anchor(20000000, DateTime(2026, 8, 1)),
          [
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
            _outflow(
              'card',
              'Card 1234 statement',
              2500000,
              DateTime(2026, 8, 18),
              owner: ForecastOwner.cardStatement,
            ),
            // Seasonal/discretionary spend estimate — the ledger dates this on a
            // day-28 placeholder; it must NOT read as a real bill.
            _outflow(
              'disc',
              'Discretionary',
              9000000,
              DateTime(2026, 8, 28),
              owner: ForecastOwner.discretionarySpend,
            ),
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
          ],
        );
        final i = computeRealInsights(_state, snapshot: snap, nowOverride: _now);

        final names = i.upcomingBills.map((b) => b.name).toList();
        expect(names, contains('Rent'));
        expect(names, contains('Card 1234 statement'));
        expect(names, isNot(contains('Discretionary')));
        // The credit-card bill is tagged as such in the due caption.
        final card = i.upcomingBills.firstWhere(
          (b) => b.name == 'Card 1234 statement',
        );
        expect(card.due, contains('Cards'));
      },
    );
  });

  group('need plan explains next month required vs receive', () {
    RecurringCommitment commitment(int paise) => RecurringCommitment(
      merchantNorm: 'netflix',
      amountPaise: paise,
      cadence: RecurringCadence.monthly,
      categoryKey: 'subscriptions',
      nextExpected: DateTime(2026, 8, 12),
      confidence: 0.95,
      occurrences: 6,
      matchedConfiguredPlan: false,
    );

    test(
      'required lists recurring payments, receive lists salary, and the gap '
      'is signed',
      () {
        final snap = _snapshotWithCommitments(
          [commitment(65000)],
          items: [_salaryInflow('sal', 8500000, DateTime(2026, 8, 10))],
          anchor: _anchor(20000000, DateTime(2026, 8, 1)),
        );
        final i = computeRealInsights(_state, snapshot: snap, nowOverride: _now);

        final plan = i.needPlan;
        expect(plan, isNotNull);
        // Next month after the Aug target month.
        expect(plan!.monthLabel, 'September');
        expect(
          plan.requiredRows.any((r) => r.label == 'Recurring payments'),
          isTrue,
        );
        expect(plan.receiveRows.any((r) => r.label == 'Salary'), isTrue);
        // The headline "Need for <month>" equals the plan's required total.
        expect(i.nextMonthNeedLabel, plan.requiredTotalLabel);
        // Salary (₹85,000) covers the ₹650 recurring → the user is ahead.
        expect(plan.isShort, isFalse);
      },
    );

    test('a large committed month leaves the user short and must gather more', () {
      final snap = _snapshotWithCommitments(
        // A recurring outflow larger than the salary base.
        [commitment(9000000)],
        items: [_salaryInflow('sal', 8500000, DateTime(2026, 8, 10))],
        anchor: _anchor(20000000, DateTime(2026, 8, 1)),
      );
      final i = computeRealInsights(_state, snapshot: snap, nowOverride: _now);

      final plan = i.needPlan!;
      expect(plan.isShort, isTrue);
      expect(plan.gapLabel, contains('Gather'));
    });
  });
}
