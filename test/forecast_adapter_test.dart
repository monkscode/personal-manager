import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

// A deterministic clock: 1 Aug 2026.
final _now = DateTime(2026, 8, 1);

// An AppState with all configured contributions disabled and no manual balance
// so the forecast is driven purely by the SMS snapshot.
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

const _detectedSalary = SalaryProfile(
  confidence: SalaryConfidence.detectedStable,
  basePaise: 8500000,
  expectedDay: 1,
  effectiveMonthSatisfied: true,
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
  DateTime dueDate, {
  ForecastOwner owner = ForecastOwner.recurringCommitment,
  DateTime? actualDate,
  ReconciliationPaymentStatus status = ReconciliationPaymentStatus.unpaid,
  double confidence = 0.9,
  AccountScope scope = AccountScope.primary,
}) => ReconciliationItem(
  id: id,
  label: label,
  amountPaise: paise,
  direction: LedgerDirection.outflow,
  owner: owner,
  source: ForecastItemSource.sms,
  dueDate: dueDate,
  actualDate: actualDate,
  paymentStatus: status,
  confidence: confidence,
  accountScope: scope,
  matchKey: 'match:$id',
);

ReconciliationItem _salaryInflow(String id, int paise, DateTime dueDate) =>
    ReconciliationItem(
      id: id,
      label: 'Salary',
      amountPaise: paise,
      direction: LedgerDirection.inflow,
      owner: ForecastOwner.salary,
      source: ForecastItemSource.sms,
      dueDate: dueDate,
      matchKey: 'match:$id',
    );

SmsAnalysisSnapshot _snap({
  required List<ReconciliationItem> items,
  BalanceAnchor? anchor,
  SalaryProfile salary = _detectedSalary,
  List<RecurringCommitment> commitments = const [],
  SeasonalEstimate? seasonal,
  List<SeasonalEstimate> horizonSeasonal = const [],
  List<ObligationRecord> obligations = const [],
  List<ForecastRiskDecision> riskDecisions = const [],
}) => SmsAnalysisSnapshot(
  horizonSeasonal: horizonSeasonal,
  targetMonth: DateTime(2026, 8),
  hasData: true,
  commitments: commitments,
  reviewCandidates: const [],
  salary: salary,
  otherIncome: const [],
  seasonal: seasonal ?? const SeasonalEstimate(targetMonth: 8, byCategory: {}),
  reconciliationItems: items,
  cards: const [],
  currentMonthTxns: const [],
  yearOverYear: const {},
  cashLevel: CashCoverageLevel.none,
  cashDrainRatio: 0,
  currentMonthAtmPaise: 0,
  obligations: obligations,
  reservePlan: const ReservePlan.empty(),
  riskDecisions: riskDecisions,
  anchor: anchor,
  anchorFreshness: anchor?.freshnessAsOf(_now),
);

ForecastOutlook _build(SmsAnalysisSnapshot snap, {AppState? state, DateTime? now}) =>
    const ForecastAdapter().build(state ?? _state, snap, now: now ?? _now);

ObligationRecord _confirmedObligation({
  required String dedupeKey,
  required String merchant,
  required int amountPaise,
  required DateTime dueDate,
  int? dueDay,
  double confidence = 0.95,
  ObligationReviewStatus reviewStatus = ObligationReviewStatus.confirmed,
  ReconciliationPaymentStatus paymentStatus =
      ReconciliationPaymentStatus.unpaid,
  ReconciliationRecurrence recurrence = ReconciliationRecurrence.monthly,
  AccountScope scope = AccountScope.primary,
  int? dueMonth,
}) => ObligationRecord(
  sourceType: ObligationSourceType.gmail,
  dedupeKey: dedupeKey,
  merchant: merchant,
  merchantNorm: merchant.toLowerCase(),
  categoryKey: 'bills',
  amountPaise: amountPaise,
  amountStatus: AmountStatus.known,
  recurrence: recurrence,
  dueDate: dueDate,
  dueDay: dueDay ?? dueDate.day,
  dueMonth: dueMonth,
  paymentAccountScope: scope,
  paymentStatus: paymentStatus,
  nextExpectedSource: NextExpectedSource.explicitDueDate,
  payeeType: PayeeType.merchant,
  userCadenceStatus: UserCadenceStatus.userConfirmed,
  confidence: confidence,
  reviewStatus: reviewStatus,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 7, 1),
);

void main() {
  _task21();
  group('ForecastAdapter — in-month minimum drives the headline', () {
    test('rent before salary makes a temporary shortfall', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(500000, DateTime(2026, 8, 1)),
          items: [
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
          ],
        ),
      );

      expect(outlook.shortfallPaise, 1300000);
      expect(outlook.minimumBalancePaise, -1300000);
      expect(outlook.minimumBalanceDate, DateTime(2026, 8, 5));
      expect(outlook.closingBalancePaise, 7200000);
      expect(outlook.headline, contains('need'));
      expect(outlook.headline, contains('₹13,000'));
      expect(outlook.isProvisional, isFalse);
      expect(outlook.salaryMissing, isFalse);
    });

    test('salary before rent leaves no shortfall', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(500000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 3)),
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
          ],
        ),
      );

      // The opening balance is itself the in-month low point once salary lands
      // before rent — never negative, so no shortfall.
      expect(outlook.shortfallPaise, 0);
      expect(outlook.minimumBalancePaise, 500000);
      expect(outlook.closingBalancePaise, 7200000);
      expect(outlook.headline, contains('extra'));
      expect(outlook.headline, contains('₹5,000'));
    });

    test('month-end surplus still reports the honest early-month dip', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(3000000, DateTime(2026, 8, 1)),
          items: [
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 3)),
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 28)),
          ],
        ),
      );

      expect(outlook.shortfallPaise, 0);
      expect(outlook.minimumBalancePaise, 1200000); // the dip, not the close
      expect(outlook.closingBalancePaise, 9700000);
      expect(outlook.headline, contains('₹12,000'));
    });
  });

  group('ForecastAdapter — seasonal + salary rules', () {
    test(
      'a low-confidence seasonal dip is a risk line, not a hard cash flow',
      () {
        final outlook = _build(
          _snap(
            anchor: _anchor(500000, DateTime(2026, 8, 1)),
            items: [
              _outflow(
                'disc',
                'Festival shopping',
                800000,
                DateTime(2026, 8, 15),
                owner: ForecastOwner.discretionarySpend,
                confidence: 0.3,
              ),
            ],
          ),
        );

        // Weak seasonal is partitioned out of hard events → no shortfall.
        expect(outlook.shortfallPaise, 0);
        expect(outlook.minimumBalancePaise, 500000);
        expect(outlook.isSeasonalBufferShortfall, isFalse);
        // Appears as a risk line instead.
        expect(outlook.riskLines, hasLength(1));
        expect(outlook.riskLines.single.label, 'Festival shopping');
      },
    );

    test('a missing salary suppresses the forward headline', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(500000, DateTime(2026, 8, 1)),
          salary: const SalaryProfile(
            confidence: SalaryConfidence.insufficientData,
          ),
          items: [_outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5))],
        ),
      );

      expect(outlook.salaryMissing, isTrue);
      expect(outlook.headline.toLowerCase(), contains('income'));
    });
  });

  group('ForecastAdapter — anchor behaviour', () {
    test('a stale anchor downgrades to a provisional headline', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(9000000, DateTime(2026, 7, 20)), // >6d before now
          items: [
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
          ],
        ),
      );

      expect(outlook.isProvisional, isTrue);
      expect(outlook.anchorConfirmLabel, isNotEmpty);
      expect(outlook.headline.toLowerCase(), contains('confirm'));
    });

    test('a user-entered balance today wins over an older SMS balance', () {
      final state = _state.copyWith(currentBalance: '20000'); // ₹20,000 today
      final outlook = _build(
        _snap(
          anchor: _anchor(9000000, DateTime(2026, 7, 15)), // stale SMS ₹90,000
          items: const [],
        ),
        state: state,
      );

      expect(outlook.openingBalancePaise, 2000000);
      expect(outlook.anchor.source, BalanceAnchorSource.manualUserEntry);
      expect(outlook.isProvisional, isFalse); // dated today → current
    });
  });

  group('ForecastAdapter — coverage and forward earmarks', () {
    test('an already-paid obligation is not subtracted again', () {
      // Read mid-month: an anchor dated after `now` is impossible and is now
      // rejected by AnchorSelector, so the fixture's own clock has to be
      // consistent with the balance reading it claims.
      final outlook = _build(
        _snap(
          anchor: _anchor(5000000, DateTime(2026, 8, 10)),
          items: [
            _outflow(
              'rent',
              'Rent',
              1800000,
              DateTime(2026, 8, 5),
              actualDate: DateTime(2026, 8, 5),
              status: ReconciliationPaymentStatus.paid,
            ),
          ],
        ),
        now: DateTime(2026, 8, 15),
      );

      expect(outlook.closingBalancePaise, 5000000); // unchanged
      expect(
        outlook.lines.any(
          (l) =>
              l.label == 'Rent' &&
              l.status == ForecastLineStatus.alreadyInAnchor,
        ),
        isTrue,
      );
    });

    test('every reconciliation item lands in exactly one coverage bucket', () {
      final items = [
        _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
        _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
        _outflow(
          'lic',
          'LIC premium',
          4700000,
          DateTime(2027, 2, 14),
          owner: ForecastOwner.gmailBill,
        ),
      ];
      final outlook = _build(
        _snap(anchor: _anchor(10000000, DateTime(2026, 8, 1)), items: items),
      );

      expect(outlook.assignments, hasLength(items.length));
      expect(outlook.assignments.map((a) => a.itemId).toSet(), {
        for (final i in items) i.id,
      });
    });

    test(
      'a surplus month still surfaces a dated forward earmark, tagged with its due month',
      () {
        final outlook = _build(
          _snap(
            anchor: _anchor(10000000, DateTime(2026, 8, 1)),
            items: [
              _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'lic',
                'LIC premium',
                4700000,
                DateTime(2027, 2, 14),
                owner: ForecastOwner.gmailBill,
              ),
            ],
          ),
        );

        expect(outlook.shortfallPaise, 0);
        final earmark = outlook.forwardEarmarks.singleWhere(
          (l) => l.label == 'LIC premium',
        );
        expect(earmark.amountPaise, 4700000);
        expect(earmark.date!.year, 2027);
        expect(earmark.date!.month, 2);
      },
    );

    test(
      'a small future obligation is below the forward-earmark materiality floor',
      () {
        final outlook = _build(
          _snap(
            anchor: _anchor(10000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'sub',
                'Streaming',
                50000,
                DateTime(2027, 2, 14),
                owner: ForecastOwner.gmailBill,
              ),
            ],
          ),
        );

        expect(outlook.forwardEarmarks, isEmpty);
      },
    );
  });

  group('ForecastAdapter — salary strip', () {
    test('committed / expected / free reflect the month', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(500000, DateTime(2026, 8, 1)),
          items: [
            _outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5)),
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
          ],
        ),
      );

      expect(outlook.salary.committedPaise, 1800000); // dated outflows
      expect(outlook.salary.expectedSalaryPaise, 8500000); // salary inflow this month
      expect(outlook.salary.freePaise, 7200000); // closing balance
    });
  });

  group('ForecastAdapter — rolling horizon', () {
    test('projects recurring commitments and salary across the horizon', () {
      final commitment = RecurringCommitment(
        merchantNorm: 'netflix',
        amountPaise: 50000,
        cadence: RecurringCadence.monthly,
        categoryKey: 'subscriptions',
        nextExpected: DateTime(2026, 9, 5),
        confidence: 0.9,
        occurrences: 6,
        matchedConfiguredPlan: false,
      );
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          commitments: [commitment],
          items: [_salaryInflow('sal', 8500000, DateTime(2026, 8, 10))],
        ),
      );

      expect(outlook.months, hasLength(kForecastHorizonMonths));
      // A future month sees the projected recurring debit.
      final sept = outlook.months[1];
      expect(
        sept.events.any((e) => e.label.toLowerCase().contains('netflix')),
        isTrue,
      );
    });
  });

  // ---- Task 4: 12-month horizon complete and conservative -------------------

  group('ForecastAdapter — future one-time obligations in horizon', () {
    test('future one-time premium is a single February hard event', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            ReconciliationItem(
              id: 'obl:gmail:lic-premium',
              label: 'LIC premium',
              amountPaise: 6000000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2027, 2, 12),
              confidence: 0.95,
              isUserConfirmed: true,
              obligationDedupeKey: 'gmail:lic-premium',
            ),
          ],
          obligations: [
            ObligationRecord(
              id: 1,
              sourceType: ObligationSourceType.gmail,
              dedupeKey: 'gmail:lic-premium',
              merchant: 'LIC premium',
              merchantNorm: 'lic premium',
              categoryKey: 'insurance',
              amountPaise: 6000000,
              amountStatus: AmountStatus.known,
              recurrence: ReconciliationRecurrence.annual,
              paymentAccountScope: AccountScope.primary,
              paymentStatus: ReconciliationPaymentStatus.unpaid,
              nextExpectedSource: NextExpectedSource.explicitDueDate,
              payeeType: PayeeType.merchant,
              userCadenceStatus: UserCadenceStatus.userConfirmed,
              confidence: 0.95,
              reviewStatus: ObligationReviewStatus.confirmed,
              dueDate: DateTime(2027, 2, 12),
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 7, 1),
            ),
          ],
        ),
      );
      // The February month is index 6 from Aug (Aug=0, Sep=1, Oct=2, Nov=3,
      // Dec=4, Jan=5, Feb=6).
      final february = outlook.months[6];
      final premiums = february.events.where((e) => e.label == 'LIC premium');
      expect(premiums, hasLength(1));
      expect(premiums.single.amountPaise, 6000000);
    });

    test(
      'future one-time obligation does not duplicate with projected commitment',
      () {
        final commitment = RecurringCommitment(
          merchantNorm: 'lic premium',
          amountPaise: 6000000,
          cadence: RecurringCadence.annual,
          categoryKey: 'insurance',
          nextExpected: DateTime(2027, 2, 12),
          confidence: 0.9,
          occurrences: 2,
          matchedConfiguredPlan: false,
        );
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            commitments: [commitment],
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:lic',
                'LIC premium',
                6000000,
                DateTime(2027, 2, 12),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
          ),
        );
        final february = outlook.months[6];
        final premiums = february.events.where(
          (e) => e.label.toLowerCase().contains('lic'),
        );
        // Must not double-count; only one event per obligation per month.
        expect(premiums, hasLength(1));
      },
    );
  });

  group('ForecastAdapter — hard/risk partitioning', () {
    test('weak pending obligation is risk and not hard cash flow', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            ReconciliationItem(
              id: 'obl:ins',
              label: 'Possible insurance',
              amountPaise: 6000000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2027, 2, 15),
              confidence: 0.62,
              isUserConfirmed: false,
              obligationDedupeKey: 'gmail:insurance',
            ),
          ],
        ),
      );
      expect(outlook.riskLines, hasLength(1));
      expect(outlook.riskLines.single.amountPaise, 6000000);
      // Must not appear in hard horizon events.
      expect(
        outlook.months
            .expand((m) => m.events)
            .where((e) => e.label == 'Possible insurance'),
        isEmpty,
      );
    });

    test('confirmed risk decision promotes weak event into hard forecast', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            ReconciliationItem(
              id: 'obl:ins',
              label: 'Possible insurance',
              amountPaise: 6000000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2027, 2, 15),
              confidence: 0.62,
              isUserConfirmed: false,
              obligationDedupeKey: 'gmail:insurance',
            ),
          ],
          riskDecisions: [
            const ForecastRiskDecision(
              ownerKey: 'gmailBill:obl:ins',
              targetMonth: '2027-02',
              status: ForecastRiskDecisionStatus.confirmed,
            ),
          ],
        ),
      );
      expect(outlook.riskLines, isEmpty);
      final feb = outlook.months[6];
      expect(
        feb.events.where((e) => e.label == 'Possible insurance'),
        hasLength(1),
      );
    });

    test('dismissed risk decision removes weak event entirely', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            ReconciliationItem(
              id: 'obl:ins',
              label: 'Possible insurance',
              amountPaise: 6000000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2027, 2, 15),
              confidence: 0.62,
              isUserConfirmed: false,
              obligationDedupeKey: 'gmail:insurance',
            ),
          ],
          riskDecisions: [
            const ForecastRiskDecision(
              ownerKey: 'gmailBill:obl:ins',
              targetMonth: '2027-02',
              status: ForecastRiskDecisionStatus.dismissed,
            ),
          ],
        ),
      );
      expect(outlook.riskLines, isEmpty);
      expect(
        outlook.months
            .expand((m) => m.events)
            .where((e) => e.label == 'Possible insurance'),
        isEmpty,
      );
    });

    test(
      'amount/date override on confirmed decision applied to hard event',
      () {
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              ReconciliationItem(
                id: 'obl:ins',
                label: 'Possible insurance',
                amountPaise: 6000000,
                direction: LedgerDirection.outflow,
                owner: ForecastOwner.gmailBill,
                source: ForecastItemSource.sms,
                dueDate: DateTime(2027, 2, 15),
                confidence: 0.62,
                isUserConfirmed: false,
                obligationDedupeKey: 'gmail:insurance',
              ),
            ],
            riskDecisions: [
              ForecastRiskDecision(
                ownerKey: 'gmailBill:obl:ins',
                targetMonth: '2027-02',
                status: ForecastRiskDecisionStatus.confirmed,
                amountOverridePaise: 7500000,
                dueDateOverride: DateTime(2027, 2, 20),
              ),
            ],
          ),
        );
        final feb = outlook.months[6];
        final event = feb.events.singleWhere(
          (e) => e.label == 'Possible insurance',
        );
        expect(event.amountPaise, 7500000);
        expect(event.date, DateTime(2027, 2, 20));
      },
    );

    test('low-confidence projected salary does not enter hard horizon', () {
      // Salary with insufficientData confidence projected → risk, not hard.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          salary: const SalaryProfile(
            confidence: SalaryConfidence.configuredFallback,
            basePaise: 8500000,
            expectedDay: 1,
            effectiveMonthSatisfied: true,
          ),
          items: [_outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 5))],
        ),
      );
      // Projected salary in month+1 should have confidence 0.6, below 0.8 → risk
      final sept = outlook.months[1];
      final salaryEvents = sept.events.where(
        (e) => e.source == ForecastEventSource.salary,
      );
      expect(salaryEvents, isEmpty);
      expect(
        outlook.riskLines.any((r) => r.source == ForecastEventSource.salary),
        isTrue,
      );
    });

    test('high-confidence user-confirmed event is always hard', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            ReconciliationItem(
              id: 'obl:rent-future',
              label: 'Rent',
              amountPaise: 1800000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2026, 9, 5),
              confidence: 0.95,
              isUserConfirmed: true,
              obligationDedupeKey: 'gmail:rent',
            ),
          ],
        ),
      );
      final sept = outlook.months[1];
      expect(sept.events.where((e) => e.label == 'Rent'), hasLength(1));
      expect(outlook.riskLines.where((r) => r.label == 'Rent'), isEmpty);
    });
  });

  group(
    'ForecastAdapter — target-month weak events partitioned (contract gap fix)',
    () {
      test(
        'target-month seasonal below 0.8 is absent from events, in riskLines, shortfall unchanged',
        () {
          final outlook = _build(
            _snap(
              anchor: _anchor(500000, DateTime(2026, 8, 1)),
              items: [
                _outflow(
                  'disc',
                  'Festival shopping',
                  800000,
                  DateTime(2026, 8, 15),
                  owner: ForecastOwner.discretionarySpend,
                  confidence: 0.3,
                ),
              ],
            ),
          );

          // Weak seasonal must NOT enter hard events → no impact on shortfall.
          expect(outlook.shortfallPaise, 0);
          expect(
            outlook.months.first.events.where(
              (e) => e.label == 'Festival shopping',
            ),
            isEmpty,
          );
          // Must appear exactly once in riskLines.
          expect(outlook.riskLines, hasLength(1));
          expect(outlook.riskLines.single.label, 'Festival shopping');
          expect(outlook.riskLines.single.amountPaise, 800000);
          expect(outlook.riskLines.single.status, ForecastLineStatus.review);
        },
      );

      test(
        'target-month confirmed decision promotes weak seasonal into hard events',
        () {
          final outlook = _build(
            _snap(
              anchor: _anchor(500000, DateTime(2026, 8, 1)),
              items: [
                _outflow(
                  'disc',
                  'Festival shopping',
                  800000,
                  DateTime(2026, 8, 15),
                  owner: ForecastOwner.discretionarySpend,
                  confidence: 0.3,
                ),
              ],
              riskDecisions: [
                const ForecastRiskDecision(
                  ownerKey: 'discretionarySpend:disc',
                  targetMonth: '2026-08',
                  status: ForecastRiskDecisionStatus.confirmed,
                ),
              ],
            ),
          );

          // Promoted to hard → affects cash flow.
          expect(outlook.riskLines, isEmpty);
          expect(
            outlook.months.first.events.where(
              (e) => e.label == 'Festival shopping',
            ),
            hasLength(1),
          );
          expect(outlook.shortfallPaise, 300000);
        },
      );

      test(
        'already-in-anchor line remains in reconciliation lines, not duplicated as risk',
        () {
          final outlook = _build(
            _snap(
              anchor: _anchor(500000, DateTime(2026, 8, 10)),
              items: [
                // Paid before anchor date → already-in-anchor.
                _outflow(
                  'rent',
                  'Rent',
                  1800000,
                  DateTime(2026, 8, 5),
                  actualDate: DateTime(2026, 8, 5),
                  status: ReconciliationPaymentStatus.paid,
                  confidence: 0.4, // weak, but already-in-anchor
                ),
              ],
            ),
            now: DateTime(2026, 8, 15),
          );

          // Must have the informational line in outlook.lines.
          expect(
            outlook.lines.any(
              (l) =>
                  l.label == 'Rent' &&
                  l.status == ForecastLineStatus.alreadyInAnchor,
            ),
            isTrue,
          );
          // Must NOT appear as a risk line (already reflected in balance).
          expect(outlook.riskLines.where((r) => r.label == 'Rent'), isEmpty);
          // Must NOT appear in events (already in anchor).
          expect(
            outlook.months.first.events.where((e) => e.label == 'Rent'),
            isEmpty,
          );
        },
      );
    },
  );

  // ---- Canonical obligation horizon projection (horizon gap fix) ----------

  group('ForecastAdapter — canonical obligation horizon projection', () {
    test(
      'confirmed monthly obligation projects exactly once into Aug and Sep hard events',
      () {
        // The obligation due in Aug (target month) must project into Sep (offset 1)
        // and Oct (offset 2) as hard events, even with no detected commitment.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:broadband',
                'Broadband',
                150000,
                DateTime(2026, 8, 15),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:broadband',
                merchant: 'Broadband',
                amountPaise: 150000,
                dueDate: DateTime(2026, 8, 15),
                dueDay: 15,
              ),
            ],
          ),
        );

        // Sep = months[1], Oct = months[2].
        final sep = outlook.months[1];
        final oct = outlook.months[2];
        final sepBroadband = sep.events
            .where((e) => e.label == 'Broadband')
            .toList();
        final octBroadband = oct.events
            .where((e) => e.label == 'Broadband')
            .toList();
        expect(
          sepBroadband,
          hasLength(1),
          reason: 'Sep must have exactly one Broadband event',
        );
        expect(
          octBroadband,
          hasLength(1),
          reason: 'Oct must have exactly one Broadband event',
        );
        expect(sepBroadband.single.amountPaise, 150000);
        expect(sepBroadband.single.isUserConfirmed, isTrue);
        // Must be hard (in events), not in riskLines.
        expect(
          outlook.riskLines.where((r) => r.label == 'Broadband'),
          isEmpty,
          reason: 'Confirmed obligation must be hard, not risk',
        );
      },
    );

    test(
      'canonical obligation suppresses same-merchant detected commitment per month',
      () {
        // A detected commitment for the same merchant exists — the canonical
        // obligation projection must win; only one event per month.
        final commitment = RecurringCommitment(
          merchantNorm: 'broadband',
          amountPaise: 150000,
          cadence: RecurringCadence.monthly,
          categoryKey: 'bills',
          nextExpected: DateTime(2026, 9, 15),
          confidence: 0.7,
          occurrences: 4,
          matchedConfiguredPlan: false,
        );
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            commitments: [commitment],
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:broadband',
                'Broadband',
                150000,
                DateTime(2026, 8, 15),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:broadband',
                merchant: 'Broadband',
                amountPaise: 150000,
                dueDate: DateTime(2026, 8, 15),
                dueDay: 15,
              ),
            ],
          ),
        );

        // Sep must have exactly one Broadband event (canonical, not commitment).
        final sep = outlook.months[1];
        final sepBroadband = sep.events
            .where((e) => e.label == 'Broadband')
            .toList();
        expect(
          sepBroadband,
          hasLength(1),
          reason: 'Only one event per month — canonical wins over commitment',
        );
        expect(
          sepBroadband.single.isUserConfirmed,
          isTrue,
          reason: 'Must be the canonical user-confirmed projection',
        );
      },
    );

    test('confirmed quarterly obligation hits correct offsets only', () {
      // Due Aug (target), quarterly → should hit Nov (offset 3), Feb (offset 6),
      // May (offset 9) within 12-month horizon.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [
            _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
            _outflow(
              'obl:insurance',
              'Insurance quarterly',
              500000,
              DateTime(2026, 8, 20),
              owner: ForecastOwner.gmailBill,
              confidence: 0.95,
            ),
          ],
          obligations: [
            _confirmedObligation(
              dedupeKey: 'gmail:insurance-q',
              merchant: 'Insurance quarterly',
              amountPaise: 500000,
              dueDate: DateTime(2026, 8, 20),
              dueDay: 20,
              dueMonth: 8,
              recurrence: ReconciliationRecurrence.quarterly,
            ),
          ],
        ),
      );

      // Quarterly from Aug: Nov (offset 3), Feb (offset 6), May (offset 9).
      final expectedOffsets = {3, 6, 9};
      for (var offset = 1; offset < kForecastHorizonMonths; offset++) {
        final month = outlook.months[offset];
        final hits = month.events
            .where((e) => e.label == 'Insurance quarterly')
            .toList();
        if (expectedOffsets.contains(offset)) {
          expect(
            hits,
            hasLength(1),
            reason: 'Quarterly must appear at offset $offset',
          );
          expect(hits.single.amountPaise, 500000);
        } else {
          expect(
            hits,
            isEmpty,
            reason: 'Quarterly must NOT appear at offset $offset',
          );
        }
      }
    });

    test(
      'confirmed recurring obligation with low confidence remains hard via user confirmation',
      () {
        // Confidence 0.5 is below kReserveHardConfidence (0.8), but user-confirmed
        // obligation must stay hard, never demoted to risk.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              ReconciliationItem(
                id: 'obl:water',
                label: 'Water bill',
                amountPaise: 80000,
                direction: LedgerDirection.outflow,
                owner: ForecastOwner.gmailBill,
                source: ForecastItemSource.sms,
                dueDate: DateTime(2026, 8, 10),
                confidence: 0.5,
                isUserConfirmed: true, // obligation confirmed
                obligationDedupeKey: 'gmail:water',
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:water',
                merchant: 'Water bill',
                amountPaise: 80000,
                dueDate: DateTime(2026, 8, 10),
                dueDay: 10,
                confidence: 0.5,
              ),
            ],
          ),
        );

        // Sep projection must be hard even though confidence is only 0.5.
        final sep = outlook.months[1];
        final sepWater = sep.events
            .where((e) => e.label == 'Water bill')
            .toList();
        expect(
          sepWater,
          hasLength(1),
          reason: 'Low-confidence confirmed obligation must be hard',
        );
        expect(sepWater.single.isUserConfirmed, isTrue);
        expect(
          outlook.riskLines.where((r) => r.label == 'Water bill'),
          isEmpty,
          reason: 'Confirmed obligation must not be in risk lines',
        );
      },
    );

    test('missing due anchor prevents projection', () {
      // Obligation with no dueDate, dueDay, or dueMonth must not project.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: [_salaryInflow('sal', 8500000, DateTime(2026, 8, 10))],
          obligations: [
            ObligationRecord(
              sourceType: ObligationSourceType.gmail,
              dedupeKey: 'gmail:mystery',
              merchant: 'Mystery bill',
              merchantNorm: 'mystery bill',
              categoryKey: 'bills',
              amountPaise: 200000,
              amountStatus: AmountStatus.known,
              recurrence: ReconciliationRecurrence.monthly,
              paymentAccountScope: AccountScope.primary,
              paymentStatus: ReconciliationPaymentStatus.unpaid,
              nextExpectedSource: NextExpectedSource.unknown,
              payeeType: PayeeType.merchant,
              userCadenceStatus: UserCadenceStatus.userConfirmed,
              confidence: 0.9,
              reviewStatus: ObligationReviewStatus.confirmed,
              createdAt: DateTime(2026, 1, 1),
              updatedAt: DateTime(2026, 7, 1),
              // No dueDate, dueDay, or dueMonth — can't project.
            ),
          ],
        ),
      );

      // No Mystery bill events in any future month.
      for (var offset = 1; offset < kForecastHorizonMonths; offset++) {
        expect(
          outlook.months[offset].events.where((e) => e.label == 'Mystery bill'),
          isEmpty,
          reason:
              'Obligation without due anchor must not project at offset $offset',
        );
      }
    });

    test(
      'distinct same-label obligations with materially different amounts are not collapsed',
      () {
        // Two obligations with the same normalized label but different amounts
        // must both project, not collapse to one.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:insurance-a',
                'Insurance',
                300000,
                DateTime(2026, 8, 10),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
              _outflow(
                'obl:insurance-b',
                'Insurance',
                600000,
                DateTime(2026, 8, 20),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:insurance-a',
                merchant: 'Insurance',
                amountPaise: 300000,
                dueDate: DateTime(2026, 8, 10),
                dueDay: 10,
              ),
              _confirmedObligation(
                dedupeKey: 'gmail:insurance-b',
                merchant: 'Insurance',
                amountPaise: 600000,
                dueDate: DateTime(2026, 8, 20),
                dueDay: 20,
              ),
            ],
          ),
        );

        // Sep must have both Insurance events at different amounts.
        final sep = outlook.months[1];
        final sepInsurance = sep.events
            .where((e) => e.label == 'Insurance')
            .toList();
        expect(
          sepInsurance,
          hasLength(2),
          reason: 'Distinct amounts must not be collapsed',
        );
        final amounts = sepInsurance.map((e) => e.amountPaise).toSet();
        expect(amounts, containsAll([300000, 600000]));
      },
    );

    test(
      'one-time future Insurance does not suppress distinct monthly Insurance',
      () {
        // Finding 1: A one-time Insurance (₹50,000) in Sep as a future-earmark
        // should NOT suppress a monthly recurring Insurance (₹3,000) in Sep
        // because they have different dedupeKeys and materially different amounts.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              // One-time future insurance (annual premium) due Sep 15
              ReconciliationItem(
                id: 'obl:insurance-annual-premium',
                label: 'Insurance',
                amountPaise: 5000000,
                direction: LedgerDirection.outflow,
                owner: ForecastOwner.gmailBill,
                source: ForecastItemSource.gmail,
                dueDate: DateTime(2026, 9, 15),
                confidence: 0.95,
                isUserConfirmed: true,
                obligationDedupeKey: 'gmail:insurance-annual-premium',
              ),
            ],
            obligations: [
              // Monthly recurring insurance (health insurance EMI) ₹3,000
              _confirmedObligation(
                dedupeKey: 'gmail:insurance-monthly-emi',
                merchant: 'Insurance',
                amountPaise: 300000,
                dueDate: DateTime(2026, 8, 10),
                dueDay: 10,
              ),
            ],
          ),
        );

        // Sep must have BOTH: the one-time ₹50,000 AND the monthly ₹3,000
        final sep = outlook.months[1];
        final sepInsurance = sep.events
            .where((e) => e.label == 'Insurance')
            .toList();
        expect(
          sepInsurance,
          hasLength(2),
          reason:
              'One-time future earmark must not suppress distinct monthly obligation',
        );
        final amounts = sepInsurance.map((e) => e.amountPaise).toSet();
        expect(amounts, containsAll([5000000, 300000]));
      },
    );

    test(
      'equivalent detected commitment is suppressed but materially different survives',
      () {
        // A detected commitment with the same merchant/amount (within jitter)
        // should be suppressed by the canonical obligation, but a materially
        // different amount commitment with the same normalized label survives.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:broadband-home',
                'Broadband',
                150000,
                DateTime(2026, 8, 15),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
            commitments: [
              // Same-label commitment with equivalent amount (within jitter) — should be suppressed
              RecurringCommitment(
                merchantNorm: 'broadband',
                amountPaise: 148000, // within 10% of 150000
                cadence: RecurringCadence.monthly,
                categoryKey: 'bills',
                nextExpected: DateTime(2026, 9, 15),
                confidence: 0.8,
                occurrences: 4,
                matchedConfiguredPlan: false,
              ),
              // Same normalized label but materially different amount — must survive
              RecurringCommitment(
                merchantNorm: 'broadband',
                amountPaise:
                    500000, // ₹5,000 — materially different from ₹1,500
                cadence: RecurringCadence.monthly,
                categoryKey: 'bills',
                nextExpected: DateTime(2026, 9, 20),
                confidence: 0.8,
                occurrences: 3,
                matchedConfiguredPlan: false,
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:broadband-home',
                merchant: 'Broadband',
                amountPaise: 150000,
                dueDate: DateTime(2026, 8, 15),
                dueDay: 15,
              ),
            ],
          ),
        );

        final sep = outlook.months[1];
        final sepBroadband = sep.events
            .where((e) => e.label.toLowerCase().contains('broadband'))
            .toList();
        // Should have canonical (150000) + materially different commitment (500000)
        // The equivalent commitment (148000) should be suppressed.
        expect(
          sepBroadband,
          hasLength(2),
          reason: 'Canonical + materially different commitment both survive',
        );
        final amounts = sepBroadband.map((e) => e.amountPaise).toSet();
        expect(
          amounts,
          contains(150000),
          reason: 'Canonical obligation projects',
        );
        expect(
          amounts,
          contains(500000),
          reason: 'Materially different commitment survives',
        );
      },
    );

    test(
      'manual obligation uses gmailBill ownerKey prefix for stable identity',
      () {
        // Finding 2: Manual obligations must use 'gmailBill' ownerKey prefix
        // (matching reconciliation_matcher) so risk decision keys are stable.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              _outflow(
                'obl:manual-rent',
                'Rent',
                2000000,
                DateTime(2026, 8, 5),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
            ],
            obligations: [
              ObligationRecord(
                sourceType: ObligationSourceType.manual,
                dedupeKey: 'manual-rent',
                merchant: 'Rent',
                merchantNorm: 'rent',
                categoryKey: 'rent',
                amountPaise: 2000000,
                amountStatus: AmountStatus.known,
                recurrence: ReconciliationRecurrence.monthly,
                dueDate: DateTime(2026, 8, 5),
                dueDay: 5,
                dueMonth: null,
                paymentAccountScope: AccountScope.primary,
                paymentStatus: ReconciliationPaymentStatus.unpaid,
                nextExpectedSource: NextExpectedSource.explicitDueDate,
                payeeType: PayeeType.merchant,
                userCadenceStatus: UserCadenceStatus.userConfirmed,
                confidence: 0.95,
                reviewStatus: ObligationReviewStatus.confirmed,
                createdAt: DateTime(2026, 1, 1),
                updatedAt: DateTime(2026, 7, 1),
              ),
            ],
          ),
        );

        // Projected events must use 'gmailBill:obl:manual-rent' not 'manual:obl:manual-rent'
        final sep = outlook.months[1];
        final sepRent = sep.events.where((e) => e.label == 'Rent').toList();
        expect(sepRent, hasLength(1));
        expect(
          sepRent.single.ownerKey,
          'gmailBill:obl:manual-rent',
          reason:
              'Manual obligation must use gmailBill prefix for identity stability',
        );
      },
    );

    test(
      'same owner/date/amount opposite directions both survive hard-line dedup',
      () {
        // Minor fix: two hard events with same ownerKey prefix, date, and amount
        // but opposite directions (inflow vs outflow) must both survive.
        final outlook = _build(
          _snap(
            anchor: _anchor(50000000, DateTime(2026, 8, 1)),
            items: [
              _salaryInflow('sal', 8500000, DateTime(2026, 8, 10)),
              // Outflow obligation
              _outflow(
                'obl:transfer-out',
                'Transfer',
                100000,
                DateTime(2026, 8, 15),
                owner: ForecastOwner.gmailBill,
                confidence: 0.95,
              ),
              // Inflow item (refund/credit) with same label and date
              ReconciliationItem(
                id: 'obl:transfer-in',
                label: 'Transfer',
                amountPaise: 100000,
                direction: LedgerDirection.inflow,
                owner: ForecastOwner.gmailBill,
                source: ForecastItemSource.gmail,
                dueDate: DateTime(2026, 9, 15),
                confidence: 0.95,
                isUserConfirmed: true,
                obligationDedupeKey: 'gmail:transfer-in',
              ),
            ],
            obligations: [
              _confirmedObligation(
                dedupeKey: 'gmail:transfer-out',
                merchant: 'Transfer',
                amountPaise: 100000,
                dueDate: DateTime(2026, 8, 15),
                dueDay: 15,
              ),
            ],
          ),
        );

        // Sep must have both: the projected outflow AND the future inflow
        final sep = outlook.months[1];
        final sepTransfer = sep.events
            .where((e) => e.label == 'Transfer')
            .toList();
        expect(
          sepTransfer.length,
          greaterThanOrEqualTo(2),
          reason: 'Opposite directions must both survive',
        );
        final hasInflow = sepTransfer.any(
          (e) => e.direction == LedgerDirection.inflow,
        );
        final hasOutflow = sepTransfer.any(
          (e) => e.direction == LedgerDirection.outflow,
        );
        expect(hasInflow, isTrue, reason: 'Inflow must survive');
        expect(hasOutflow, isTrue, reason: 'Outflow must survive');
      },
    );
  });

  _task22();
  _task23();
}

// ---------------------------------------------------------------------------
// TASK-21 — discretionary spend across the whole horizon.
// ---------------------------------------------------------------------------

/// A whole-horizon seasonal estimate of [monthlyPaise] per month at
/// [confidence], as the snapshot reducer now produces.
List<SeasonalEstimate> _flatHorizon(
  int monthlyPaise, {
  double confidence = kSeasonalConfidenceSeasonal,
  String category = 'everyday',
}) => [
  for (var offset = 0; offset < kForecastHorizonMonths; offset++)
    SeasonalEstimate(
      targetMonth: DateTime(2026, 8 + offset).month,
      byCategory: {
        category: CategorySeasonalEstimate(
          categoryKey: category,
          amountPaise: monthlyPaise,
          confidence: confidence,
        ),
      },
    ),
];

void _task21() {
  // The task file's scenario: 85k salary, 40k of fixed commitments, a stable
  // 28k/month of tracked discretionary spend.
  const salaryPaise = 8500000;
  const commitmentPaise = 4000000;
  const discretionaryPaise = 2800000;

  SmsAnalysisSnapshot snapshot({
    List<SeasonalEstimate> horizonSeasonal = const [],
  }) => _snap(
    items: const [],
    anchor: BalanceAnchor(
      amountPaise: 10000000,
      asOf: DateTime(2026, 8, 1),
      source: BalanceAnchorSource.smsBankBalance,
    ),
    commitments: [
      RecurringCommitment(
        merchantNorm: 'rent',
        amountPaise: commitmentPaise,
        cadence: RecurringCadence.monthly,
        categoryKey: 'housing',
        nextExpected: DateTime(2026, 8, 5),
        confidence: 0.9,
        occurrences: 6,
        matchedConfiguredPlan: false,
      ),
    ],
    horizonSeasonal: horizonSeasonal,
  );

  group('discretionary spend across the horizon (TASK-21)', () {
    test('month 6 is not six months of discretionary spend too high', () {
      final without = _build(snapshot()).months[6].closingBalancePaise;
      final with_ = _build(
        snapshot(horizonSeasonal: _flatHorizon(discretionaryPaise)),
      ).months[6].closingBalancePaise;

      // Six future months of spend (offsets 1..6) must be missing from the
      // un-estimated projection, and the gap must not have been rounded away.
      expect(without - with_, discretionaryPaise * 6);
    });

    test('the gap does not compound across the carry-forward chain', () {
      final months = _build(
        snapshot(horizonSeasonal: _flatHorizon(discretionaryPaise)),
      ).months;

      // Each future month moves by exactly salary − commitment − discretionary.
      const perMonth = salaryPaise - commitmentPaise - discretionaryPaise;
      for (var offset = 2; offset < kForecastHorizonMonths; offset++) {
        expect(
          months[offset].closingBalancePaise -
              months[offset - 1].closingBalancePaise,
          perMonth,
          reason: 'month $offset drifted from the steady-state step',
        );
      }
    });

    test('every horizon month has an estimate or names the omission', () {
      for (final horizon in [
        <SeasonalEstimate>[],
        _flatHorizon(discretionaryPaise),
        // Too weak to be a hard ledger event: it must still be named.
        _flatHorizon(discretionaryPaise, confidence: kSeasonalConfidenceThin),
      ]) {
        final outlook = _build(snapshot(horizonSeasonal: horizon));
        for (var offset = 0; offset < kForecastHorizonMonths; offset++) {
          final month = outlook.months[offset];
          final hasEstimate = month.events.any(
            (e) => e.source == ForecastEventSource.seasonal,
          );
          final namesOmission = month.coverageLines.any(
            (l) => l.reason == CoverageReason.discretionaryNotModelled,
          );
          expect(
            hasEstimate || namesOmission,
            isTrue,
            reason:
                'month $offset silently omits discretionary spend '
                '(horizon length ${horizon.length})',
          );
        }
      }
    });

    test('a weak estimate is named with the amount it left out', () {
      final outlook = _build(
        snapshot(
          horizonSeasonal: _flatHorizon(
            discretionaryPaise,
            confidence: kSeasonalConfidenceThin,
          ),
        ),
      );

      final line = outlook.months[3].coverageLines.singleWhere(
        (l) => l.reason == CoverageReason.discretionaryNotModelled,
      );
      expect(line.amountPaise, discretionaryPaise);
    });
  });
}

// ---------------------------------------------------------------------------
// TASK-22 — the manual balance is parsed as integer paise, and an anchor the
// app has never observed is never presented as evidence.
// ---------------------------------------------------------------------------

void _task22() {
  ForecastOutlook buildWithBalance(String balance) => _build(
    _snap(items: const []),
    state: _state.copyWith(currentBalance: balance),
  );

  group('TASK-22 — the manual balance anchor is parsed as integer paise', () {
    test('accepts Indian digit grouping instead of dropping the anchor', () {
      final outlook = buildWithBalance('1,20,000');

      expect(outlook.anchor.source, BalanceAnchorSource.manualUserEntry);
      expect(outlook.openingBalancePaise, 12000000);
    });

    test('rounds the third decimal up rather than down through a double', () {
      // ₹40,000.005: `40000.005 * 100` is 4000000.4999999995 as a double and
      // rounds *down*, losing a paise. (The task file's original example,
      // 47000.005, happens to land exactly on 4700000.5 and rounds the same
      // way both ways — it does not demonstrate the defect.)
      final outlook = buildWithBalance('40000.005');

      expect(outlook.anchor.source, BalanceAnchorSource.manualUserEntry);
      expect(outlook.openingBalancePaise, 4000001);
    });

    test('rejects scientific notation instead of reading it as a billion '
        'rupees', () {
      final outlook = buildWithBalance('1e9');

      expect(outlook.anchor.source, isNot(BalanceAnchorSource.manualUserEntry));
      expect(outlook.openingBalancePaise, 0);
    });

    test('still tolerates surrounding whitespace (guard)', () {
      final outlook = buildWithBalance('  50000  ');

      expect(outlook.anchor.source, BalanceAnchorSource.manualUserEntry);
      expect(outlook.openingBalancePaise, 5000000);
    });
  });

  group('TASK-22 — an anchor with no evidence behind it', () {
    test('is provisional, is not 0.9-confident, and says so', () {
      // No SMS balance and no manual balance: the adapter fabricates a ₹0
      // anchor dated at the start of the target month, which on 1 Aug is one
      // day old and therefore reads as `current`.
      final outlook = _build(_snap(items: const []));

      expect(outlook.anchor.hasEvidence, isFalse);
      expect(outlook.isProvisional, isTrue);
      expect(outlook.anchorConfirmLabel, isNotEmpty);

      final opening = outlook.months.first.lines.singleWhere(
        (line) => line.status == ForecastLineStatus.opening,
      );
      expect(opening.confidence, isNot(0.9));

      expect(
        outlook.months.first.coverageLines.where(
          (line) => line.action == CoverageAction.confirmBalance,
        ),
        isNotEmpty,
      );
    });

    test('a real fresh SMS anchor stays non-provisional (guard)', () {
      final outlook = _build(
        _snap(anchor: _anchor(500000, DateTime(2026, 8, 1)), items: const []),
      );

      expect(outlook.anchor.hasEvidence, isTrue);
      expect(outlook.isProvisional, isFalse);
      expect(
        outlook.months.first.coverageLines.where(
          (line) => line.action == CoverageAction.confirmBalance,
        ),
        isEmpty,
      );
    });

    test('cannot swallow a first-of-month obligation as already paid', () {
      // Rent due on the 1st, unpaid, no matching debit. The fabricated anchor
      // is dated 1 Aug 00:00, so `!dueDate.isAfter(anchor.asOf)` holds and the
      // item is classified `possiblyAlreadyPaid` against a balance that was
      // never observed — the forecast then omits money the user still owes.
      final outlook = _build(
        _snap(
          items: [_outflow('rent', 'Rent', 1800000, DateTime(2026, 8, 1))],
        ),
      );

      expect(
        outlook.coverageLines.where(
          (line) => line.reason == CoverageReason.possiblyAlreadyPaid,
        ),
        isEmpty,
      );
      expect(outlook.closingBalancePaise, lessThanOrEqualTo(-1800000));
    });
  });
}

// ---------------------------------------------------------------------------
// TASK-23 — horizon dedupe by identity, and a reachable seasonal-buffer
// headline.
// ---------------------------------------------------------------------------

void _task23() {
  RecurringCommitment commitment({
    required String merchantNorm,
    required int amountPaise,
    required String categoryKey,
  }) => RecurringCommitment(
    merchantNorm: merchantNorm,
    amountPaise: amountPaise,
    cadence: RecurringCadence.monthly,
    categoryKey: categoryKey,
    nextExpected: DateTime(2026, 9, 12),
    confidence: 0.9,
    occurrences: 6,
    matchedConfiguredPlan: false,
  );

  List<ForecastEvent> septemberOutflows(ForecastOutlook outlook, int paise) =>
      outlook.months[1].events
          .where(
            (e) =>
                e.direction == LedgerDirection.outflow &&
                e.amountPaise == paise,
          )
          .toList();

  group('TASK-23 — horizon commitments dedupe by identity, not label text', () {
    test('joins "ACT Fibernet" to "actfibernet" at the same amount', () {
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: const [],
          commitments: [
            commitment(
              merchantNorm: 'actfibernet',
              amountPaise: 118000,
              categoryKey: 'bills',
            ),
          ],
          obligations: [
            _confirmedObligation(
              dedupeKey: 'gmail:act-fibernet',
              merchant: 'ACT Fibernet',
              amountPaise: 118000,
              dueDate: DateTime(2026, 8, 12),
              dueDay: 12,
            ),
          ],
        ),
      );

      expect(septemberOutflows(outlook, 118000), hasLength(1));
    });

    test('still projects both when the merchants are genuinely different '
        '(guard)', () {
      // Same amount and cadence, different categories: no reason to believe
      // these are one commitment.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: const [],
          commitments: [
            commitment(
              merchantNorm: 'gym membership',
              amountPaise: 118000,
              categoryKey: 'health',
            ),
          ],
          obligations: [
            _confirmedObligation(
              dedupeKey: 'gmail:act-fibernet',
              merchant: 'ACT Fibernet',
              amountPaise: 118000,
              dueDate: DateTime(2026, 8, 12),
              dueDay: 12,
            ),
          ],
        ),
      );

      expect(septemberOutflows(outlook, 118000), hasLength(2));
    });

    test('never joins two payees whose labels normalise to nothing', () {
      // Stripping punctuation is what lets "ACT Fibernet" meet "actfibernet",
      // but a label that is *only* punctuation normalises to the empty string.
      // Two of those must not collapse into one owner -- that is the same
      // ownerless-key grouping failure TASK-31 and TASK-33 found in the parser.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: const [],
          commitments: [
            commitment(
              merchantNorm: '---',
              amountPaise: 118000,
              categoryKey: 'health',
            ),
          ],
          obligations: [
            _confirmedObligation(
              dedupeKey: 'gmail:mystery',
              merchant: '***',
              amountPaise: 118000,
              dueDate: DateTime(2026, 8, 12),
              dueDay: 12,
            ),
          ],
        ),
      );

      expect(septemberOutflows(outlook, 118000), hasLength(2));
    });

    test('routes an ambiguous same-category match to review instead of '
        'silently doubling it', () {
      // Different merchant strings that do not normalise to each other, but the
      // same category, amount and month. The spec routes ambiguity to review;
      // it may not be counted twice, and it may not vanish unnamed.
      final outlook = _build(
        _snap(
          anchor: _anchor(50000000, DateTime(2026, 8, 1)),
          items: const [],
          commitments: [
            commitment(
              merchantNorm: 'act broadband',
              amountPaise: 118000,
              categoryKey: 'bills',
            ),
          ],
          obligations: [
            _confirmedObligation(
              dedupeKey: 'gmail:act-fibernet',
              merchant: 'ACT Fibernet',
              amountPaise: 118000,
              dueDate: DateTime(2026, 8, 12),
              dueDay: 12,
            ),
          ],
        ),
      );

      expect(septemberOutflows(outlook, 118000), hasLength(1));
      final review = outlook.months[1].coverageLines.where(
        (line) => line.reason == CoverageReason.duplicateSuppressed,
      );
      expect(review, hasLength(1));
      expect(review.single.action, CoverageAction.review);
      expect(review.single.amountPaise, 118000);
    });
  });

  group('TASK-23 — the seasonal buffer headline is reachable', () {
    ForecastOutlook shortfallDrivenBy(ForecastOwner owner, double confidence) =>
        _build(
          _snap(
            anchor: _anchor(500000, DateTime(2026, 8, 1)),
            items: [
              _outflow(
                'discretionary',
                'Everyday spending',
                2000000,
                DateTime(2026, 8, 20),
                owner: owner,
                confidence: confidence,
              ),
            ],
          ),
        );

    test('fires when the in-month low is driven by estimated spend', () {
      // Confidence 0.85 clears `_isHard` (0.8) and so is the only kind of
      // seasonal event that can reach the ledger at all.
      final outlook = shortfallDrivenBy(ForecastOwner.discretionarySpend, 0.85);

      expect(outlook.shortfallPaise, 1500000);
      expect(outlook.isSeasonalBufferShortfall, isTrue);
      expect(outlook.headline, contains('Estimated buffer shortfall'));
    });

    test('does not fire when a fixed bill drives the low (guard)', () {
      final outlook = shortfallDrivenBy(
        ForecastOwner.recurringCommitment,
        0.85,
      );

      expect(outlook.shortfallPaise, 1500000);
      expect(outlook.isSeasonalBufferShortfall, isFalse);
      expect(outlook.headline, contains('You need'));
    });
  });
}
