import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/card_models.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_cycle_estimator.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/forecast_reconciliation_engine.dart';
import 'package:expense_insight/services/reconciliation_matcher.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- fixtures -------------------------------------------------------------

final _target = DateTime(2026, 8);
final _anchor = BalanceAnchor(
  amountPaise: 20000000,
  asOf: DateTime(2026, 8, 1),
  source: BalanceAnchorSource.smsBankBalance,
);

const _noSeasonal = SeasonalEstimate(targetMonth: 8, byCategory: {});
const _noSalary = SalaryProfile(confidence: SalaryConfidence.insufficientData);

ParsedTxn actual({
  required int amountPaise,
  required DateTime date,
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.upi,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String? merchant = 'ICICI Pru MF',
  String categoryKey = 'investment',
  String? accountLast4,
  String? refNumber,
  String smsId = 'sms',
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-ICICIB',
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: amountPaise,
  txnDate: date,
  merchant: merchant,
  accountLast4: accountLast4,
  refNumber: refNumber,
  payeeType: PayeeType.merchant,
  categoryKey: categoryKey,
  confidence: 0.95,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h',
  scanBatchId: 'b',
);

ObligationRecord obligation({
  required ObligationSourceType sourceType,
  required int? amountPaise,
  String merchant = 'ICICI Pru MF',
  String merchantNorm = 'icici pru mf',
  String categoryKey = 'investment',
  ReconciliationRecurrence recurrence = ReconciliationRecurrence.monthly,
  DateTime? dueDate,
  int? dueDay,
  AccountScope scope = AccountScope.primary,
  ReconciliationPaymentStatus paymentStatus =
      ReconciliationPaymentStatus.unpaid,
  AmountStatus amountStatus = AmountStatus.known,
  String? dedupeKey,
  String? sourceId,
  int? id = 1,
  DateTime? updatedAt,
}) => ObligationRecord(
  id: id,
  sourceType: sourceType,
  sourceId: sourceId,
  dedupeKey: dedupeKey ?? '$merchantNorm:$amountPaise',
  merchant: merchant,
  merchantNorm: merchantNorm,
  categoryKey: categoryKey,
  amountPaise: amountPaise,
  amountStatus: amountStatus,
  recurrence: recurrence,
  dueDate: dueDate,
  dueDay: dueDay,
  paymentAccountScope: scope,
  paymentStatus: paymentStatus,
  nextExpectedSource: dueDate == null
      ? NextExpectedSource.unknown
      : NextExpectedSource.explicitDueDate,
  payeeType: PayeeType.merchant,
  userCadenceStatus: UserCadenceStatus.userConfirmed,
  confidence: 0.9,
  reviewStatus: ObligationReviewStatus.confirmed,
  createdAt: DateTime(2026, 1),
  updatedAt: updatedAt ?? DateTime(2026, 7),
);

RecurringCommitment commitment({
  required int amountPaise,
  String merchantNorm = 'icici pru mf',
  String categoryKey = 'investment',
  RecurringCadence cadence = RecurringCadence.monthly,
  DateTime? nextExpected,
  String? configuredPlanKey,
}) => RecurringCommitment(
  merchantNorm: merchantNorm,
  amountPaise: amountPaise,
  cadence: cadence,
  categoryKey: categoryKey,
  nextExpected: nextExpected ?? DateTime(2026, 8, 10),
  confidence: 0.7,
  occurrences: 4,
  matchedConfiguredPlan: configuredPlanKey != null,
  configuredPlanKey: configuredPlanKey,
);

const _matcher = ReconciliationMatcher();
const _engine = ForecastReconciliationEngine();

List<ReconciliationItem> build({
  List<ParsedTxn> actuals = const [],
  List<ObligationRecord> obligations = const [],
  List<RecurringCommitment> commitments = const [],
  SeasonalEstimate seasonal = _noSeasonal,
  SalaryProfile salary = _noSalary,
  List<CardCycleEstimate> cards = const [],
  DateTime? targetMonth,
  BalanceAnchor? anchor,
}) => _matcher.buildItems(
  actuals: actuals,
  obligations: obligations,
  commitments: commitments,
  seasonal: seasonal,
  salary: salary,
  cards: cards,
  anchor: anchor ?? _anchor,
  targetMonth: targetMonth ?? _target,
);

BalanceAnchor anchorFor(DateTime month) => BalanceAnchor(
  amountPaise: 20000000,
  asOf: DateTime(month.year, month.month, 1),
  source: BalanceAnchorSource.smsBankBalance,
);

ReconciliationItem byOwner(
  List<ReconciliationItem> items,
  ForecastOwner owner,
) => items.firstWhere((i) => i.owner == owner);

void main() {
  test('D8 annual heads-up expiry constant is the confirmed 15 months', () {
    expect(kAnnualHeadsUpExpiryMonths, 15);
  });

  group('owner mapping (§7 producers become owned items)', () {
    test('SIP recurring commitment becomes a required recurring event', () {
      final items = build(commitments: [commitment(amountPaise: 1000000)]);
      final item = byOwner(items, ForecastOwner.recurringCommitment);
      expect(item.amountPaise, 1000000);
      expect(item.dueDate, DateTime(2026, 8, 10));
      expect(item.recurrence, ReconciliationRecurrence.monthly);
      expect(item.paymentStatus, ReconciliationPaymentStatus.unpaid);
    });

    test(
      'halfYearly cadence maps to annual recurrence (no halfYearly enum)',
      () {
        final items = build(
          commitments: [
            commitment(
              amountPaise: 1000000,
              cadence: RecurringCadence.halfYearly,
            ),
          ],
        );
        expect(
          byOwner(items, ForecastOwner.recurringCommitment).recurrence,
          ReconciliationRecurrence.annual,
        );
      },
    );

    test('Gmail obligation becomes a gmailBill owner', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            merchant: 'LIC',
            merchantNorm: 'lic',
            recurrence: ReconciliationRecurrence.annual,
            dueDate: DateTime(2026, 8, 14),
          ),
        ],
      );
      expect(byOwner(items, ForecastOwner.gmailBill).amountPaise, 4700000);
    });

    test(
      'configured plan obligation becomes a configuredContribution owner',
      () {
        final items = build(
          obligations: [
            obligation(
              sourceType: ObligationSourceType.configuredPlan,
              amountPaise: 500000,
              dueDate: DateTime(2026, 8, 5),
            ),
          ],
        );
        expect(
          byOwner(items, ForecastOwner.configuredContribution).amountPaise,
          500000,
        );
      },
    );

    test('undated annual obligation becomes an annualUnscheduled owner', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            recurrence: ReconciliationRecurrence.annual,
            dueDate: null,
          ),
        ],
      );
      expect(items.single.owner, ForecastOwner.annualUnscheduled);
    });

    test(
      'secondary-scope obligation becomes a nonPrimaryAccountObligation',
      () {
        final items = build(
          obligations: [
            obligation(
              sourceType: ObligationSourceType.gmail,
              amountPaise: 4700000,
              dueDate: DateTime(2026, 8, 14),
              scope: AccountScope.secondary,
            ),
          ],
        );
        expect(items.single.owner, ForecastOwner.nonPrimaryAccountObligation);
        expect(items.single.accountScope, AccountScope.secondary);
      },
    );

    test(
      'salary profile becomes a projected salary inflow when not yet landed',
      () {
        final items = build(
          salary: const SalaryProfile(
            confidence: SalaryConfidence.detectedStable,
            basePaise: 8000000,
            expectedDay: 28,
          ),
        );
        final item = byOwner(items, ForecastOwner.salary);
        expect(item.direction, LedgerDirection.inflow);
        expect(item.amountPaise, 8000000);
        expect(item.dueDate, DateTime(2026, 8, 28));
      },
    );

    test('already-landed salary is not re-added as an event', () {
      final items = build(
        salary: const SalaryProfile(
          confidence: SalaryConfidence.detectedStable,
          basePaise: 8000000,
          expectedDay: 28,
          effectiveMonthSatisfied: true,
        ),
      );
      expect(items.where((i) => i.owner == ForecastOwner.salary), isEmpty);
    });

    test('seasonal categories become discretionarySpend owners', () {
      final items = build(
        seasonal: const SeasonalEstimate(
          targetMonth: 8,
          byCategory: {
            'groceries': CategorySeasonalEstimate(
              categoryKey: 'groceries',
              amountPaise: 950000,
              confidence: 0.8,
            ),
          },
        ),
      );
      final item = byOwner(items, ForecastOwner.discretionarySpend);
      expect(item.amountPaise, 950000);
      expect(item.direction, LedgerDirection.outflow);
    });
  });

  group('the join: actual ↔ obligation', () {
    test('already-paid SIP is folded to paid and not subtracted twice', () {
      final items = build(
        commitments: [commitment(amountPaise: 1000000)],
        actuals: [
          actual(
            amountPaise: 1000000,
            date: DateTime(2026, 8, 10),
            merchant: 'ICICI Pru MF',
            smsId: 'paid',
          ),
        ],
      );
      final item = byOwner(items, ForecastOwner.recurringCommitment);
      expect(item.paymentStatus, ReconciliationPaymentStatus.paid);
      expect(item.actualDate, DateTime(2026, 8, 10));

      final result = _engine.reconcileMonth(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 15),
      );
      // Exactly one owned event for the SIP rupee.
      expect(
        result.events.where((e) => e.source == ForecastEventSource.recurring),
        hasLength(1),
      );
    });

    test('near-miss amount stays unmatched (obligation not marked paid)', () {
      final items = build(
        commitments: [commitment(amountPaise: 1000000)],
        actuals: [
          actual(
            amountPaise: 2000000,
            date: DateTime(2026, 8, 10),
            smsId: 'nm',
          ),
        ],
      );
      final item = byOwner(items, ForecastOwner.recurringCommitment);
      expect(item.paymentStatus, ReconciliationPaymentStatus.unpaid);
      expect(item.actualDate, isNull);
    });

    test('merchant-null commitment matches by amount/category/account', () {
      final items = build(
        commitments: [commitment(amountPaise: 1000000, merchantNorm: '')],
        actuals: [
          actual(
            amountPaise: 1000000,
            date: DateTime(2026, 8, 10),
            merchant: null,
            categoryKey: 'investment',
            smsId: 'null-merchant',
          ),
        ],
      );
      expect(
        byOwner(items, ForecastOwner.recurringCommitment).paymentStatus,
        ReconciliationPaymentStatus.paid,
      );
    });

    test('reference/id match folds even when merchant text differs', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 1000000,
            merchant: 'LIC OF INDIA',
            merchantNorm: 'lic of india',
            sourceId: 'REF123',
            dueDate: DateTime(2026, 8, 14),
          ),
        ],
        actuals: [
          actual(
            amountPaise: 1000000,
            date: DateTime(2026, 8, 13),
            merchant: 'BILLDESK',
            refNumber: 'REF123',
            smsId: 'ref',
          ),
        ],
      );
      expect(
        byOwner(items, ForecastOwner.gmailBill).paymentStatus,
        ReconciliationPaymentStatus.paid,
      );
    });

    test('ambiguous actual matching two obligations routes both to review', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 1000000,
            merchant: '',
            merchantNorm: '',
            categoryKey: 'investment',
            dueDate: DateTime(2026, 8, 10),
            id: 1,
            dedupeKey: 'a',
          ),
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 1000000,
            merchant: '',
            merchantNorm: '',
            categoryKey: 'investment',
            dueDate: DateTime(2026, 8, 12),
            id: 2,
            dedupeKey: 'b',
          ),
        ],
        actuals: [
          actual(
            amountPaise: 1000000,
            date: DateTime(2026, 8, 11),
            merchant: null,
            categoryKey: 'investment',
            smsId: 'ambig',
          ),
        ],
      );
      expect(
        items.where(
          (i) => i.paymentStatus == ReconciliationPaymentStatus.possiblyPaid,
        ),
        hasLength(2),
      );
    });
  });

  group('configured/detected dedup and precedence', () {
    test('commitment matching a configured plan shares its matchKey', () {
      const planKey = 'configured:monthly:500000:Aug';
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.configuredPlan,
            amountPaise: 500000,
            dueDate: DateTime(2026, 8, 5),
            dedupeKey: planKey,
          ),
        ],
        commitments: [
          commitment(amountPaise: 500000, configuredPlanKey: planKey),
        ],
      );
      final configured = byOwner(items, ForecastOwner.configuredContribution);
      final detected = byOwner(items, ForecastOwner.recurringCommitment);
      expect(configured.matchKey, detected.matchKey);
      expect(configured.matchKey, isNotNull);

      final result = _engine.reconcileMonth(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 3),
      );
      // Deduped: exactly one dated event, owned by the configured contribution.
      expect(result.events, hasLength(1));
      expect(
        result.events.single.source,
        ForecastEventSource.configuredContribution,
      );
    });
  });

  group('annual heads-up expiry (D8)', () {
    test('annual obligation with no evidence for >15 months expires', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            recurrence: ReconciliationRecurrence.annual,
            dueDate: DateTime(2026, 8, 14),
            updatedAt: DateTime(2025, 4), // 16 months before target
          ),
        ],
      );
      expect(items, isEmpty);
    });

    test('annual obligation with recent evidence is kept', () {
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            recurrence: ReconciliationRecurrence.annual,
            dueDate: DateTime(2026, 8, 14),
            updatedAt: DateTime(2025, 7), // 13 months before target
          ),
        ],
      );
      expect(items, hasLength(1));
    });
  });

  group('cards', () {
    test(
      'card statement becomes a cardStatement event; CRED payment reconciles it',
      () {
        final estimate = const CardCycleEstimator().estimate(
          const [],
          cycle: const CardCycle(
            cardLast4: '4321',
            statementDay: 3,
            dueDay: 20,
            confidence: 0.9,
          ),
          statementMonth: DateTime(2026, 8),
          statementTotalPaise: 1500000,
        );
        final items = build(
          cards: [estimate],
          actuals: [
            actual(
              amountPaise: 1500000,
              date: DateTime(2026, 8, 20),
              merchant: 'CRED',
              categoryKey: 'card_payment',
              smsId: 'cred',
            ),
          ],
        );

        final payment = byOwner(items, ForecastOwner.cardPayment);
        expect(payment.cardCycleKey, estimate.cardCycleKey);
        expect(payment.actualDate, DateTime(2026, 8, 20));

        final result = _engine.reconcileMonth(
          targetMonth: _target,
          anchor: _anchor,
          items: items,
          now: DateTime(2026, 8, 25),
        );
        // Exactly one bank cash event for the card bill (the actual payment).
        final cardEvents = result.events.where(
          (e) =>
              e.source == ForecastEventSource.cardPayment ||
              e.source == ForecastEventSource.cardStatement,
        );
        expect(cardEvents, hasLength(1));
        expect(cardEvents.single.source, ForecastEventSource.cardPayment);
      },
    );
  });

  group('refunds', () {
    test(
      'cross-month refund is a single dated bank inflow in the target month',
      () {
        final items = build(
          actuals: [
            actual(
              amountPaise: 300000,
              date: DateTime(2026, 8, 6),
              direction: TransactionDirection.credit,
              categoryKey: 'refund',
              merchant: 'AMAZON REFUND',
              refNumber: 'ORD9',
              smsId: 'refund',
            ),
          ],
        );
        final refund = byOwner(items, ForecastOwner.refund);
        expect(refund.direction, LedgerDirection.inflow);
        expect(refund.amountPaise, 300000);
        expect(refund.dueDate ?? refund.actualDate, DateTime(2026, 8, 6));
      },
    );

    test(
      'cumulative refunds are capped at the original debit; excess is income',
      () {
        final items = build(
          actuals: [
            actual(
              amountPaise: 1000000,
              date: DateTime(2026, 8, 1),
              direction: TransactionDirection.debit,
              merchant: 'AMAZON',
              refNumber: 'ORD1',
              smsId: 'orig',
            ),
            actual(
              amountPaise: 600000,
              date: DateTime(2026, 8, 5),
              direction: TransactionDirection.credit,
              categoryKey: 'refund',
              merchant: 'AMAZON',
              refNumber: 'ORD1',
              smsId: 'r1',
            ),
            actual(
              amountPaise: 600000,
              date: DateTime(2026, 8, 9),
              direction: TransactionDirection.credit,
              categoryKey: 'refund',
              merchant: 'AMAZON',
              refNumber: 'ORD1',
              smsId: 'r2',
            ),
          ],
        );
        final refunds = items.where((i) => i.owner == ForecastOwner.refund);
        final refundTotal = refunds.fold<int>(
          0,
          (sum, i) => sum + (i.amountPaise ?? 0),
        );
        expect(refundTotal, 1000000); // capped at the original debit
        // The over-refund becomes reviewable income, not a negative expense.
        expect(items.any((i) => i.owner == ForecastOwner.otherIncome), isTrue);
      },
    );
  });

  group('cash and transfers', () {
    test(
      'unmatched ATM withdrawal after the anchor becomes an atmCash event',
      () {
        final items = build(
          actuals: [
            actual(
              amountPaise: 800000,
              date: DateTime(2026, 8, 10),
              type: TxnType.atm,
              merchant: null,
              categoryKey: 'cash',
              smsId: 'atm',
            ),
          ],
        );
        final item = byOwner(items, ForecastOwner.atmCash);
        expect(item.amountPaise, 800000);
        expect(item.actualDate, DateTime(2026, 8, 10));
      },
    );

    test('unmatched transfer debit becomes a transfer cash event', () {
      final items = build(
        actuals: [
          actual(
            amountPaise: 500000,
            date: DateTime(2026, 8, 10),
            type: TxnType.transfer,
            merchant: 'SELF',
            categoryKey: 'transfer',
            smsId: 'xfer',
          ),
        ],
      );
      expect(byOwner(items, ForecastOwner.transfer).amountPaise, 500000);
    });
  });

  group('completeness (every owner produces exactly one assignment)', () {
    test('a mixed input set assigns each rupee exactly one owner', () {
      final items = build(
        commitments: [commitment(amountPaise: 1000000)],
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            merchant: 'LIC',
            merchantNorm: 'lic',
            recurrence: ReconciliationRecurrence.annual,
            dueDate: DateTime(2026, 8, 14),
          ),
        ],
        salary: const SalaryProfile(
          confidence: SalaryConfidence.detectedStable,
          basePaise: 8000000,
          expectedDay: 28,
        ),
        seasonal: const SeasonalEstimate(
          targetMonth: 8,
          byCategory: {
            'groceries': CategorySeasonalEstimate(
              categoryKey: 'groceries',
              amountPaise: 950000,
              confidence: 0.8,
            ),
          },
        ),
        actuals: [
          actual(
            amountPaise: 800000,
            date: DateTime(2026, 8, 10),
            type: TxnType.atm,
            merchant: null,
            categoryKey: 'cash',
            smsId: 'atm',
          ),
        ],
      );

      final result = _engine.reconcileMonth(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 15),
      );
      expect(result.assignments, hasLength(items.length));
      expect(result.assignments.map((a) => a.itemId).toSet(), {
        for (final i in items) i.id,
      });
    });

    test('every §7 owner produces exactly one assignment', () {
      for (final owner in ForecastOwner.values) {
        final inflow =
            owner == ForecastOwner.salary ||
            owner == ForecastOwner.otherIncome ||
            owner == ForecastOwner.refund ||
            owner == ForecastOwner.p2pIncomeCandidate;
        final item = ReconciliationItem(
          id: 'x',
          label: owner.name,
          amountPaise: 100000,
          direction: inflow ? LedgerDirection.inflow : LedgerDirection.outflow,
          owner: owner,
          source: ForecastItemSource.sms,
          dueDate: DateTime(2026, 8, 15),
          userCadenceStatus: UserCadenceStatus.userConfirmed,
        );
        final result = _engine.reconcileMonth(
          targetMonth: _target,
          anchor: _anchor,
          items: [item],
          now: DateTime(2026, 8, 10),
        );
        expect(
          result.assignments,
          hasLength(1),
          reason: 'owner $owner must produce exactly one assignment',
        );
      }
    });
  });

  group('obligation owner-key uses canonical dedupeKey (not SQLite row id)', () {
    test(
      'persisted obligation with id and dedupeKey produces dedupeKey-based ownerKey',
      () {
        final items = build(
          obligations: [
            obligation(
              id: 42,
              sourceType: ObligationSourceType.gmail,
              amountPaise: 6000000,
              merchant: 'LIC',
              merchantNorm: 'lic',
              categoryKey: 'insurance',
              recurrence: ReconciliationRecurrence.annual,
              dueDate: DateTime(2026, 8, 14),
              dedupeKey: 'gmail:lic:annual',
            ),
          ],
        );
        final item = byOwner(items, ForecastOwner.gmailBill);
        // The id must be based on dedupeKey, never the mutable SQLite row id.
        expect(item.id, 'obl:gmail:lic:annual');
        expect(item.ownerKey, 'gmailBill:obl:gmail:lic:annual');
        // Must NOT contain the numeric row id.
        expect(item.id, isNot(contains('42')));
      },
    );

    test('risk decision keyed to dedupeKey-based ownerKey promotes correctly', () {
      // Use low confidence (0.62) so the event is weak without a decision.
      final items = build(
        obligations: [
          ObligationRecord(
            id: 42,
            sourceType: ObligationSourceType.gmail,
            dedupeKey: 'gmail:lic:annual',
            merchant: 'LIC',
            merchantNorm: 'lic',
            categoryKey: 'insurance',
            amountPaise: 6000000,
            amountStatus: AmountStatus.known,
            recurrence: ReconciliationRecurrence.annual,
            dueDate: DateTime(2027, 2, 14),
            paymentAccountScope: AccountScope.primary,
            paymentStatus: ReconciliationPaymentStatus.unpaid,
            nextExpectedSource: NextExpectedSource.explicitDueDate,
            payeeType: PayeeType.merchant,
            userCadenceStatus: UserCadenceStatus.userConfirmed,
            confidence: 0.62,
            reviewStatus: ObligationReviewStatus.needsReview,
            createdAt: DateTime(2026, 1),
            updatedAt: DateTime(2026, 7),
          ),
        ],
      );
      final item = byOwner(items, ForecastOwner.gmailBill);

      // Decision keyed to the CANONICAL dedupeKey-based ownerKey (stable identity).
      // This is what persistence produces: decisions reference stable keys.
      const canonicalOwnerKey = 'gmailBill:obl:gmail:lic:annual';

      // Build a snapshot with this item and a decision keyed to the canonical ownerKey.
      final snap = SmsAnalysisSnapshot(
        targetMonth: _target,
        hasData: true,
        commitments: const [],
        reviewCandidates: const [],
        salary: _noSalary,
        otherIncome: const [],
        seasonal: _noSeasonal,
        reconciliationItems: [
          ReconciliationItem(
            id: 'sal',
            label: 'Salary',
            amountPaise: 8500000,
            direction: LedgerDirection.inflow,
            owner: ForecastOwner.salary,
            source: ForecastItemSource.sms,
            dueDate: DateTime(2026, 8, 10),
          ),
          item,
        ],
        cards: const [],
        currentMonthTxns: const [],
        yearOverYear: const {},
        cashLevel: CashCoverageLevel.none,
        cashDrainRatio: 0,
        currentMonthAtmPaise: 0,
        obligations: const [],
        reservePlan: const ReservePlan.empty(),
        riskDecisions: [
          const ForecastRiskDecision(
            ownerKey: canonicalOwnerKey,
            targetMonth: '2027-02',
            status: ForecastRiskDecisionStatus.confirmed,
          ),
        ],
        anchor: _anchor,
        anchorFreshness: _anchor.freshnessAsOf(_target),
      );

      final outlook = const ForecastAdapter().build(
        const AppState(),
        snap,
        now: DateTime(2026, 8, 1),
      );

      // Confirmed decision should promote the weak obligation into hard forecast.
      expect(outlook.riskLines, isEmpty);
      final feb = outlook.months[6];
      expect(feb.events.where((e) => e.label == 'LIC'), hasLength(1));
    });
  });

  group('month-end day-of-month never rolls out of the target month', () {
    test('salary on the 30th is dated 28 Feb and stays in February', () {
      final target = DateTime(2026, 2);
      final anchor = anchorFor(target);
      final items = build(
        salary: const SalaryProfile(
          confidence: SalaryConfidence.detectedStable,
          basePaise: 8000000,
          expectedDay: 30,
        ),
        targetMonth: target,
        anchor: anchor,
      );

      expect(byOwner(items, ForecastOwner.salary).dueDate, DateTime(2026, 2, 28));

      final result = _engine.reconcileMonth(
        targetMonth: target,
        anchor: anchor,
        items: items,
        now: DateTime(2026, 2, 5),
      );
      final salaryEvents = result.events.where(
        (e) => e.source == ForecastEventSource.salary,
      );
      expect(salaryEvents, hasLength(1));
      expect(salaryEvents.single.date, DateTime(2026, 2, 28));
      expect(salaryEvents.single.direction, LedgerDirection.inflow);
      expect(salaryEvents.single.amountPaise, 8000000);
      expect(
        result.coverageLines.where(
          (l) => l.reason == CoverageReason.futureEarmark,
        ),
        isEmpty,
      );
    });

    test('salary on the 31st is dated 30 Apr in a 30-day month', () {
      final target = DateTime(2026, 4);
      final items = build(
        salary: const SalaryProfile(
          confidence: SalaryConfidence.detectedStable,
          basePaise: 8000000,
          expectedDay: 31,
        ),
        targetMonth: target,
        anchor: anchorFor(target),
      );

      expect(byOwner(items, ForecastOwner.salary).dueDate, DateTime(2026, 4, 30));
    });

    test('salary on the 30th keeps 29 Feb in a leap year', () {
      final target = DateTime(2028, 2);
      final items = build(
        salary: const SalaryProfile(
          confidence: SalaryConfidence.detectedStable,
          basePaise: 8000000,
          expectedDay: 30,
        ),
        targetMonth: target,
        anchor: anchorFor(target),
      );

      expect(byOwner(items, ForecastOwner.salary).dueDate, DateTime(2028, 2, 29));
    });

    test('obligation dueDay 31 is dated 28 Feb and stays a February event', () {
      final target = DateTime(2026, 2);
      final anchor = anchorFor(target);
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 4700000,
            merchant: 'Rent',
            merchantNorm: 'rent',
            categoryKey: 'rent',
            dueDay: 31,
          ),
        ],
        targetMonth: target,
        anchor: anchor,
      );

      expect(items.single.dueDate, DateTime(2026, 2, 28));

      final result = _engine.reconcileMonth(
        targetMonth: target,
        anchor: anchor,
        items: items,
        now: DateTime(2026, 2, 5),
      );
      expect(result.events, hasLength(1));
      expect(result.events.single.date, DateTime(2026, 2, 28));
      expect(result.events.single.direction, LedgerDirection.outflow);
      expect(result.events.single.amountPaise, 4700000);
      expect(
        result.coverageLines.where(
          (l) => l.reason == CoverageReason.futureEarmark,
        ),
        isEmpty,
      );
    });
  });
}
