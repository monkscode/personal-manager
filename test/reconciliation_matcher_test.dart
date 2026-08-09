import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/card_models.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_cycle_estimator.dart';
import 'package:expense_insight/services/card_settlement_pairer.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/forecast_reconciliation_engine.dart';
import 'package:expense_insight/services/reconciliation_matcher.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/reconciliation_invariants.dart';

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
  String rawBodyRedacted = 'redacted',
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
  rawBodyRedacted: rawBodyRedacted,
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
  DateTime? retiredAt,
}) => ObligationRecord(
  retiredAt: retiredAt,
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

// 'cred' is the fixture-wide stand-in for a confirmed settlement front: every
// `payment(...)`/`actual(merchant: 'CRED', ...)` fixture in this file exists
// to exercise the card-payment lane, and under exact-key matching a default
// of {'cred'} cannot accidentally catch any other merchant here (the one test
// that checks the opposite uses 'SACRED HEART SCHOOL', which does not
// normalise to 'cred').
const _defaultConfirmedFronts = {'cred'};

List<ReconciliationItem> build({
  List<ParsedTxn> actuals = const [],
  List<ObligationRecord> obligations = const [],
  List<RecurringCommitment> commitments = const [],
  SeasonalEstimate seasonal = _noSeasonal,
  SalaryProfile salary = _noSalary,
  List<CardCycleEstimate> cards = const [],
  DateTime? targetMonth,
  BalanceAnchor? anchor,
  Set<String> confirmedFronts = _defaultConfirmedFronts,
  Map<String, CardSettlementPair> settlementPairs = const {},
}) => _matcher.buildItems(
  actuals: actuals,
  obligations: obligations,
  commitments: commitments,
  seasonal: seasonal,
  salary: salary,
  cards: cards,
  anchor: anchor ?? _anchor,
  targetMonth: targetMonth ?? _target,
  confirmedFronts: confirmedFronts,
  settlementPairs: settlementPairs,
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

/// Reconcile and assert rupee conservation on the way through, so every
/// end-to-end fixture in this file is held to the invariant.
ForecastReconciliationResult reconcile({
  required DateTime targetMonth,
  required BalanceAnchor anchor,
  required List<ReconciliationItem> items,
  DateTime? now,
}) {
  final result = _engine.reconcileMonth(
    targetMonth: targetMonth,
    anchor: anchor,
    items: items,
    now: now,
  );
  expectRupeeConservation(result, items);
  return result;
}

void main() {
  test('D8 annual heads-up expiry constant is the confirmed 15 months', () {
    expect(kAnnualHeadsUpExpiryMonths, 15);
  });

  group('Spec A — one definition of a card settlement serves both', () {
    test('a merchant whose name merely contains "cred" is not a payment', () {
      final items = build(
        actuals: [
          actual(
            amountPaise: 500000,
            date: DateTime(2026, 8, 12),
            merchant: 'SACRED HEART SCHOOL',
            categoryKey: 'other',
            smsId: 'school',
          ),
        ],
      );

      expect(items.where((i) => i.owner == ForecastOwner.cardPayment), isEmpty);
    });

    test('a settlement stored as a card row reaches the payment lane', () {
      // It used to fall through to `instrument == card` and be dropped
      // outright: the money left the bank and no item owned it.
      final items = build(
        actuals: [
          actual(
            amountPaise: 4500000,
            date: DateTime(2026, 8, 20),
            instrument: PaymentInstrument.card,
            type: TxnType.pos,
            merchant: null,
            categoryKey: 'other',
            smsId: 'settlement',
            rawBodyRedacted:
                'Payment of [amount] towards your HDFC Credit Card debited '
                'from A/c [account]',
          ),
        ],
      );

      final payments = items
          .where((i) => i.owner == ForecastOwner.cardPayment)
          .toList();
      expect(payments, hasLength(1));
      expect(payments.single.amountPaise, 4500000);
    });
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
      final seasonal = items.where(
        (i) => i.owner == ForecastOwner.discretionarySpend,
      );
      // Spread over the days still ahead of the anchor (1 Aug), summing back to
      // the estimate exactly — no paise rounded away.
      expect(seasonal.fold<int>(0, (sum, i) => sum + i.amountPaise!), 950000);
      expect(seasonal.every((i) => i.direction == LedgerDirection.outflow), isTrue);
      expect(seasonal.map((i) => i.dueDate).toSet(), hasLength(30));
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

      final result = reconcile(
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

      final result = reconcile(
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

  group('an algorithm guess does not harden the forecast', () {
    // A plain 3-occurrence commitment carries confidence 0.7, below the 0.8
    // reserve bar, so `isUserConfirmed` was the only thing lifting it over.
    ObligationRecord smsRecurring({
      required ObligationReviewStatus reviewStatus,
    }) => ObligationRecord(
      id: 7,
      sourceType: ObligationSourceType.smsRecurring,
      dedupeKey: 'sms_recurring:netflix:monthly',
      merchant: 'netflix',
      merchantNorm: 'netflix',
      categoryKey: 'subscriptions',
      amountPaise: 50000,
      amountStatus: AmountStatus.known,
      recurrence: ReconciliationRecurrence.monthly,
      dueDate: DateTime(2026, 8, 5),
      paymentAccountScope: AccountScope.primary,
      paymentStatus: ReconciliationPaymentStatus.unpaid,
      nextExpectedSource: NextExpectedSource.lockedCadence,
      payeeType: PayeeType.merchant,
      userCadenceStatus: UserCadenceStatus.algorithmDetected,
      confidence: kRecurringBaseConfidence,
      reviewStatus: reviewStatus,
      createdAt: DateTime(2026, 1),
      updatedAt: DateTime(2026, 7),
    );

    bool hardensFor(ObligationReviewStatus reviewStatus) {
      final items = build(
        obligations: [smsRecurring(reviewStatus: reviewStatus)],
        targetMonth: _target,
        anchor: anchorFor(_target),
      );
      final result = reconcile(
        targetMonth: _target,
        anchor: anchorFor(_target),
        items: items,
        now: DateTime(2026, 8, 2),
      );
      final event = result.events.singleWhere(
        (e) => e.ownerKey.contains('netflix'),
      );
      // Mirrors ForecastAdapter._isHard: user-confirmed, or over the bar.
      return event.isUserConfirmed || event.confidence >= kReserveHardConfidence;
    }

    test('an unconfirmed guess stays soft at 0.7 confidence', () {
      expect(hardensFor(ObligationReviewStatus.needsReview), isFalse);
    });

    test('once the user confirms it, it hardens', () {
      expect(hardensFor(ObligationReviewStatus.confirmed), isTrue);
    });
  });

  group('refunds are capped per original debit', () {
    ParsedTxn purchase({
      required int amountPaise,
      required int day,
      String merchant = 'AMAZON',
      String? refNumber,
      String smsId = 'buy',
    }) => actual(
      amountPaise: amountPaise,
      date: DateTime(2026, 8, day),
      merchant: merchant,
      categoryKey: 'shopping',
      refNumber: refNumber,
      smsId: smsId,
    );

    ParsedTxn refund({
      required int amountPaise,
      required int day,
      String merchant = 'AMAZON',
      String? refNumber,
      required String smsId,
    }) => actual(
      amountPaise: amountPaise,
      date: DateTime(2026, 8, day),
      direction: TransactionDirection.credit,
      merchant: merchant,
      categoryKey: 'shopping_refund',
      refNumber: refNumber,
      smsId: smsId,
    );

    int refundTotal(List<ReconciliationItem> items) => items
        .where((i) => i.owner == ForecastOwner.refund)
        .fold<int>(0, (sum, i) => sum + i.amountPaise!);

    test('two refunds with different references share one cap', () {
      // Item-level refunds on one multi-item order: routine, and each group
      // used to be capped at the full purchase independently.
      final items = build(
        actuals: [
          purchase(amountPaise: 1000000, day: 3),
          refund(amountPaise: 600000, day: 10, refNumber: 'R1', smsId: 'r1'),
          refund(amountPaise: 700000, day: 12, refNumber: 'R2', smsId: 'r2'),
        ],
      );
      expect(refundTotal(items), 1000000);
    });

    test('a refund with no plausible purchase goes to review, not income', () {
      final items = build(
        actuals: [
          purchase(amountPaise: 20000, day: 3),
          refund(amountPaise: 300000, day: 10, smsId: 'r-big'),
        ],
      );
      expect(items.where((i) => i.owner == ForecastOwner.otherIncome), isEmpty);
      final held = items.singleWhere((i) => i.id == 'refund:r-big');
      expect(held.needsAttributionReview, isTrue);
    });

    test('a refund dated before its candidate purchase is not matched to it', () {
      final items = build(
        actuals: [
          purchase(amountPaise: 500000, day: 20),
          refund(amountPaise: 500000, day: 4, smsId: 'r-early'),
        ],
      );
      expect(
        items.singleWhere((i) => i.id == 'refund:r-early').needsAttributionReview,
        isTrue,
      );
    });

    test('a single refund within its cap still credits normally', () {
      final items = build(
        actuals: [
          purchase(amountPaise: 1000000, day: 3),
          refund(amountPaise: 400000, day: 10, smsId: 'r-ok'),
        ],
      );
      expect(refundTotal(items), 400000);
      final credited = items.singleWhere((i) => i.id == 'refund:r-ok');
      expect(credited.refundOfId, 'actual:buy');
      expect(credited.needsAttributionReview, isFalse);
    });
  });

  group('the fold does not depend on the order actuals arrive in', () {
    // X is reachable by both debits; Y only by the ambiguous one.
    final namedObligation = obligation(
      sourceType: ObligationSourceType.gmail,
      amountPaise: 1000000,
      dueDate: DateTime(2026, 8, 10),
      dedupeKey: 'gmail:sip',
    );
    final anonymousCommitment = commitment(
      amountPaise: 1000000,
      merchantNorm: '',
      nextExpected: DateTime(2026, 8, 10),
    );
    final ambiguous = actual(
      amountPaise: 1000000,
      date: DateTime(2026, 8, 9),
      merchant: 'ICICI Pru MF',
      categoryKey: 'investment',
      smsId: 'debit-a',
    );
    final unique = actual(
      amountPaise: 1000000,
      date: DateTime(2026, 8, 11),
      merchant: 'ICICI Pru MF',
      categoryKey: 'other',
      smsId: 'debit-b',
    );

    List<ReconciliationItem> foldWith(List<ParsedTxn> actuals) => build(
      obligations: [namedObligation],
      commitments: [anonymousCommitment],
      actuals: actuals,
    );

    test('a unique match is not downgraded by a later ambiguous one', () {
      final forwards = foldWith([ambiguous, unique]);
      final backwards = foldWith([unique, ambiguous]);

      ReconciliationPaymentStatus statusOf(List<ReconciliationItem> items) =>
          items.singleWhere((i) => i.id == 'obl:gmail:sip').paymentStatus;

      expect(statusOf(forwards), statusOf(backwards));
      expect(statusOf(forwards), ReconciliationPaymentStatus.paid);
    });

    test('both orderings give the same ledger total', () {
      int totalFor(List<ParsedTxn> actuals) {
        final items = foldWith(actuals);
        final result = reconcile(
          targetMonth: _target,
          anchor: _anchor,
          items: items,
          now: DateTime(2026, 8, 15),
        );
        return result.events
            .where((e) => e.direction == LedgerDirection.outflow)
            .fold<int>(0, (sum, e) => sum + e.amountPaise);
      }

      expect(totalFor([ambiguous, unique]), totalFor([unique, ambiguous]));
    });
  });

  group('month-to-date spend is netted out of the seasonal estimate', () {
    // 22 July: anchor read this morning, ₹7,000 of food already spent this
    // month, seasonal food estimate ₹10,000. Only ₹3,000 is still to come.
    final july = DateTime(2026, 7);
    BalanceAnchor anchorOn(int day) => BalanceAnchor(
      amountPaise: 4000000,
      asOf: DateTime(2026, 7, day),
      source: BalanceAnchorSource.smsBankBalance,
    );

    SeasonalEstimate food(int amountPaise) => SeasonalEstimate(
      targetMonth: 7,
      byCategory: {
        'food': CategorySeasonalEstimate(
          categoryKey: 'food',
          amountPaise: amountPaise,
          confidence: 0.8,
        ),
      },
    );

    List<ParsedTxn> foodSpend(List<(int, int)> dayAndPaise) => [
      for (final (day, paise) in dayAndPaise)
        actual(
          amountPaise: paise,
          date: DateTime(2026, 7, day),
          merchant: 'BIGBASKET',
          categoryKey: 'food',
          smsId: 'food-$day',
        ),
    ];

    int seasonalTotal(List<ReconciliationItem> items) => items
        .where((i) => i.source == ForecastItemSource.estimator)
        .fold<int>(0, (sum, i) => sum + i.amountPaise!);

    test('the estimate is reduced by what is already spent', () {
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 400000), (12, 300000)]),
        targetMonth: july,
        anchor: anchorOn(22),
      );
      expect(seasonalTotal(items), 300000);
    });

    test('spending past the estimate never goes negative', () {
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 900000), (12, 600000)]),
        targetMonth: july,
        anchor: anchorOn(22),
      );
      expect(seasonalTotal(items), 0);
    });

    test('the residual is spread over the remaining days, not dropped on the 28th', () {
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 400000), (12, 300000)]),
        targetMonth: july,
        anchor: anchorOn(22),
      );
      final dates = items
          .where((i) => i.source == ForecastItemSource.estimator)
          .map((i) => i.dueDate!.day)
          .toList();
      // 23..31 inclusive.
      expect(dates, [23, 24, 25, 26, 27, 28, 29, 30, 31]);
    });

    test('every day of a category shares one group id, so it reviews once', () {
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 400000), (12, 300000)]),
        targetMonth: july,
        anchor: anchorOn(22),
      );
      final slices = items
          .where((i) => i.source == ForecastItemSource.estimator)
          .toList();

      // Nine days, one reviewable thing. Without the shared id the forecast
      // offers Confirm/Edit/Dismiss nine times over for one month of food.
      expect(slices, hasLength(9));
      expect(
        slices.map((i) => i.groupId).toSet(),
        {'seasonal:food'},
      );
    });

    test('there is no overnight cliff between the 28th and the 29th', () {
      int requiredOn(int day) {
        final anchor = anchorOn(day);
        final items = build(
          seasonal: food(1000000),
          actuals: foodSpend([(5, 400000)]),
          targetMonth: july,
          anchor: anchor,
        );
        final result = reconcile(
          targetMonth: july,
          anchor: anchor,
          items: items,
          now: DateTime(2026, 7, day),
        );
        return result.events
            .where((e) => e.direction == LedgerDirection.outflow)
            .fold<int>(0, (sum, e) => sum + e.amountPaise);
      }

      // Before: day 28 stopped being after the anchor on the 29th and the whole
      // estimate was reclassified away overnight.
      final onThe28th = requiredOn(28);
      final onThe29th = requiredOn(29);
      expect(onThe28th, greaterThan(0));
      expect(onThe29th, greaterThan(0));
      expect((onThe28th - onThe29th).abs(), lessThan(onThe28th ~/ 2));
    });

    test('already-spent transactions are traceable but not subtracted', () {
      final anchor = anchorOn(22);
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 400000)]),
        targetMonth: july,
        anchor: anchor,
      );
      final result = reconcile(
        targetMonth: july,
        anchor: anchor,
        items: items,
        now: DateTime(2026, 7, 22),
      );

      final spent = result.assignments.singleWhere(
        (a) => a.itemId == 'spend:food-5',
      );
      expect(spent.coverageBucket, CoverageBucket.anchorIncluded);
      expect(spent.status, ForecastLineStatus.alreadyInAnchor);
      expect(
        result.lines.any(
          (l) =>
              l.ownerKey == 'discretionarySpend:spend:food-5' &&
              l.status == ForecastLineStatus.alreadyInAnchor,
        ),
        isTrue,
      );
      expect(
        result.events.any((e) => e.ownerKey.contains('spend:food-5')),
        isFalse,
        reason: 'rupees inside the anchor must not be subtracted again',
      );
    });

    test('discretionary spend after the anchor is still real cash out', () {
      final anchor = anchorOn(10);
      final items = build(
        seasonal: food(1000000),
        actuals: foodSpend([(5, 200000), (18, 300000)]),
        targetMonth: july,
        anchor: anchor,
      );
      final result = reconcile(
        targetMonth: july,
        anchor: anchor,
        items: items,
        now: DateTime(2026, 7, 22),
      );
      expect(
        result.events.any(
          (e) =>
              e.ownerKey == 'discretionarySpend:spend:food-18' &&
              e.amountPaise == 300000,
        ),
        isTrue,
      );
    });
  });

  group('the transfer bridge is wired into the matcher', () {
    ObligationRecord secondaryLic({int amountPaise = 4700000, int? id = 1}) =>
        obligation(
          sourceType: ObligationSourceType.gmail,
          amountPaise: amountPaise,
          merchant: 'LIC Premium',
          merchantNorm: 'lic premium',
          categoryKey: 'insurance',
          dueDate: DateTime(2026, 8, 14),
          scope: AccountScope.secondary,
          dedupeKey: 'gmail:lic-$id',
          id: id,
        );

    ParsedTxn selfTransfer({
      required int amountPaise,
      required int day,
      required String smsId,
    }) => actual(
      amountPaise: amountPaise,
      date: DateTime(2026, 8, day),
      type: TxnType.transfer,
      merchant: 'Self HDFC 9012',
      categoryKey: 'transfer',
      smsId: smsId,
    );

    test('a funding transfer names the obligation it funds', () {
      final items = build(
        obligations: [secondaryLic()],
        actuals: [
          selfTransfer(amountPaise: 4700000, day: 12, smsId: 'xfer'),
        ],
      );

      final transfer = byOwner(items, ForecastOwner.transfer);
      expect(transfer.transferBridgeToId, 'obl:gmail:lic-1');
    });

    test('the funded obligation is not also subtracted', () {
      final items = build(
        obligations: [secondaryLic()],
        actuals: [
          selfTransfer(amountPaise: 4700000, day: 12, smsId: 'xfer'),
        ],
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 20),
      );
      expect(result.events, hasLength(1));
      expect(result.events.single.source, ForecastEventSource.transfer);
      expect(result.events.single.amountPaise, 4700000);
    });

    test('two transfers for one obligation are both kept and both named', () {
      final items = build(
        obligations: [secondaryLic()],
        actuals: [
          selfTransfer(amountPaise: 4700000, day: 11, smsId: 'xfer-a'),
          selfTransfer(amountPaise: 4700000, day: 13, smsId: 'xfer-b'),
        ],
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 20),
      );
      // Two real primary debits stay two real debits; the ambiguity is about
      // which one funded the bill, not about whether the cash left.
      expect(
        result.events
            .where((e) => e.source == ForecastEventSource.transfer)
            .fold<int>(0, (sum, e) => sum + e.amountPaise),
        9400000,
      );
    });

    test('a transfer that funds nothing carries no bridge', () {
      final items = build(
        obligations: [secondaryLic()],
        actuals: [
          selfTransfer(amountPaise: 250000, day: 12, smsId: 'xfer-small'),
        ],
      );
      expect(byOwner(items, ForecastOwner.transfer).transferBridgeToId, isNull);
    });
  });

  group('every observed card payment reaches the ledger', () {
    /// [cycleConfigured] false is the shape the app actually ships: nothing in
    /// `lib/` constructs a [CardCycle], so no estimate ever carries a
    /// `dueDate`. Every other test here supplies one, which only the guess
    /// path needs.
    CardCycleEstimate card({
      required String last4,
      required int statementPaise,
      int dueDay = 20,
      bool cycleConfigured = true,
    }) => CardCycleEstimate(
      cardLast4: last4,
      cardCycleKey: 'card:$last4:2026-08',
      observedPurchasesPaise: statementPaise,
      cardRefundsPaise: 0,
      cycleSpendSeenPaise: statementPaise,
      statementEventAmountPaise: statementPaise,
      statementTotalPaise: statementPaise,
      paymentStatus: ReconciliationPaymentStatus.unpaid,
      dueDate: cycleConfigured ? DateTime(2026, 8, dueDay) : null,
      needsCycleSetup: !cycleConfigured,
      confidence: 0.9,
    );

    ParsedTxn payment({
      required int amountPaise,
      required int day,
      required String smsId,
    }) => actual(
      amountPaise: amountPaise,
      date: DateTime(2026, 8, day),
      merchant: 'CRED',
      categoryKey: 'card_payment',
      smsId: smsId,
    );

    test('two payments in one cycle are both cash out, not one', () {
      final items = build(
        cards: [card(last4: '4321', statementPaise: 5000000)],
        actuals: [
          payment(amountPaise: 2000000, day: 10, smsId: 'pay-1'),
          payment(amountPaise: 3000000, day: 18, smsId: 'pay-2'),
        ],
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 25),
      );
      final cardCash = result.events.where(
        (e) => e.source == ForecastEventSource.cardPayment,
      );
      expect(cardCash.fold<int>(0, (sum, e) => sum + e.amountPaise), 5000000);
    });

    test('two cards with distinct amounts each take their own payment', () {
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 2000000),
          card(last4: '9876', statementPaise: 7500000),
        ],
        actuals: [
          payment(amountPaise: 2000000, day: 15, smsId: 'pay-small'),
          payment(amountPaise: 7500000, day: 16, smsId: 'pay-large'),
        ],
      );

      String cycleOf(String smsId) => items
          .singleWhere((i) => i.id == 'cardpay:$smsId')
          .cardCycleKey!;
      expect(cycleOf('pay-small'), 'card:4321:2026-08');
      expect(cycleOf('pay-large'), 'card:9876:2026-08');
    });

    test('two cards with indistinguishable amounts go to review, not a guess', () {
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 3000000),
          card(last4: '9876', statementPaise: 3000000),
        ],
        actuals: [payment(amountPaise: 3000000, day: 15, smsId: 'pay-x')],
      );

      final pay = items.singleWhere((i) => i.id == 'cardpay:pay-x');
      expect(pay.cardCycleKey, isNull);

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 25),
      );
      expect(
        result.assignments
            .singleWhere((a) => a.itemId == 'cardpay:pay-x')
            .coverageBucket,
        CoverageBucket.reviewPending,
      );
      expect(
        result.coverageLines.any(
          (l) => l.ownerKey == 'cardPayment:cardpay:pay-x',
        ),
        isTrue,
      );
    });

    /// The pair as `SmsAnalysisSnapshot` hands it over: the bank debit, and the
    /// card's own acknowledgement of the same bill. Only [ack.accountLast4] is
    /// read here, so the ack carries no more than it needs to.
    Map<String, CardSettlementPair> settlement(
      ParsedTxn debit, {
      required String? ackCardLast4,
    }) => {
      debit.smsId: CardSettlementPair(
        debit: debit,
        ack: actual(
          amountPaise: debit.amountPaise,
          date: debit.txnDate,
          direction: TransactionDirection.credit,
          instrument: PaymentInstrument.card,
          merchant: null,
          categoryKey: 'card_payment',
          accountLast4: ackCardLast4,
          smsId: 'ack-${debit.smsId}',
        ),
      ),
    };

    test('the card that acknowledged the bill owns the payment, even when the '
        'amounts cannot tell two cards apart', () {
      final pay = payment(amountPaise: 3000000, day: 15, smsId: 'pay-x');
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 3000000),
          card(last4: '9876', statementPaise: 3000000),
        ],
        actuals: [pay],
        settlementPairs: settlement(pay, ackCardLast4: '9876'),
      );

      final item = items.singleWhere((i) => i.id == 'cardpay:pay-x');
      expect(item.cardCycleKey, 'card:9876:2026-08');
      expect(item.needsAttributionReview, isFalse);
    });

    test('the acknowledgement outranks a matching amount', () {
      // Reward points mean the bank debit is routinely smaller than the bill,
      // so "the amount looks like card 4321's statement" is evidence the card
      // itself can overrule — and here does.
      final pay = payment(amountPaise: 2000000, day: 15, smsId: 'pay-y');
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 2000000),
          card(last4: '9876', statementPaise: 7500000),
        ],
        actuals: [pay],
        settlementPairs: settlement(pay, ackCardLast4: '9876'),
      );

      final item = items.singleWhere((i) => i.id == 'cardpay:pay-y');
      expect(item.cardCycleKey, 'card:9876:2026-08');
      expect(item.needsAttributionReview, isFalse);
    });

    test('the acknowledgement names the cycle with no cycle configured at all',
        () {
      // The production shape. With no `dueDate` on any estimate the guess below
      // cannot start, so before the acknowledgement was consulted every card
      // bill payment reached the ledger with a null cycle.
      final pay = payment(amountPaise: 3000000, day: 15, smsId: 'pay-v');
      final items = build(
        cards: [
          card(
            last4: '4321',
            statementPaise: 3000000,
            cycleConfigured: false,
          ),
          card(
            last4: '9876',
            statementPaise: 3000000,
            cycleConfigured: false,
          ),
        ],
        actuals: [pay],
        settlementPairs: settlement(pay, ackCardLast4: '9876'),
      );

      final item = items.singleWhere((i) => i.id == 'cardpay:pay-v');
      expect(item.cardCycleKey, 'card:9876:2026-08');
      expect(item.needsAttributionReview, isFalse);
    });

    test('an acknowledgement naming no card leaves the guess alone', () {
      // Real: the parser admits an acknowledgement on 2 of 5 signals, so a
      // genuinely paired ack can carry a null accountLast4.
      final pay = payment(amountPaise: 3000000, day: 15, smsId: 'pay-z');
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 3000000),
          card(last4: '9876', statementPaise: 3000000),
        ],
        actuals: [pay],
        settlementPairs: settlement(pay, ackCardLast4: null),
      );

      final item = items.singleWhere((i) => i.id == 'cardpay:pay-z');
      expect(item.cardCycleKey, isNull);
      expect(item.needsAttributionReview, isTrue);
    });

    test('an acknowledgement naming a card no cycle knows leaves the guess '
        'alone', () {
      final pay = payment(amountPaise: 3000000, day: 15, smsId: 'pay-w');
      final items = build(
        cards: [
          card(last4: '4321', statementPaise: 3000000),
          card(last4: '9876', statementPaise: 3000000),
        ],
        actuals: [pay],
        settlementPairs: settlement(pay, ackCardLast4: '5555'),
      );

      final item = items.singleWhere((i) => i.id == 'cardpay:pay-w');
      expect(item.cardCycleKey, isNull);
      expect(item.needsAttributionReview, isTrue);
    });

    test('a single payment in a cycle still settles its statement', () {
      final items = build(
        cards: [card(last4: '4321', statementPaise: 5000000)],
        actuals: [payment(amountPaise: 5000000, day: 18, smsId: 'pay-solo')],
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 25),
      );
      final cardCash = result.events.where(
        (e) =>
            e.source == ForecastEventSource.cardPayment ||
            e.source == ForecastEventSource.cardStatement,
      );
      expect(cardCash, hasLength(1));
      expect(cardCash.single.amountPaise, 5000000);
    });
  });

  group('transfer-typed debits fold before falling back to the transfer lane', () {
    ObligationRecord lic({String? sourceId}) => obligation(
      sourceType: ObligationSourceType.gmail,
      amountPaise: 4700000,
      merchant: 'LIC OF INDIA',
      merchantNorm: 'lic of india',
      categoryKey: 'insurance',
      dueDate: DateTime(2026, 8, 14),
      dedupeKey: 'gmail:lic',
      sourceId: sourceId,
    );

    ParsedTxn licDebit({String? refNumber, String smsId = 'neft'}) => actual(
      amountPaise: 4700000,
      date: DateTime(2026, 8, 14),
      type: TxnType.transfer,
      merchant: 'LIC OF INDIA',
      categoryKey: 'insurance',
      refNumber: refNumber,
      smsId: smsId,
    );

    void expectSettledOnce(List<ReconciliationItem> items) {
      expect(
        byOwner(items, ForecastOwner.gmailBill).paymentStatus,
        ReconciliationPaymentStatus.paid,
      );
      expect(
        items.where((i) => i.owner == ForecastOwner.transfer),
        isEmpty,
        reason: 'a transfer that settled an obligation is not also an outflow',
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 20),
      );
      expect(
        result.events.fold<int>(0, (sum, e) => sum + e.amountPaise),
        4700000,
      );
    }

    test('a NEFT bill payment is subtracted once, not twice', () {
      expectSettledOnce(
        build(
          obligations: [lic(sourceId: 'REF123')],
          actuals: [licDebit(refNumber: 'REF123')],
        ),
      );
    });

    test('an IMPS bill payment behaves the same', () {
      expectSettledOnce(
        build(
          obligations: [lic(sourceId: 'REF456')],
          actuals: [licDebit(refNumber: 'REF456', smsId: 'imps')],
        ),
      );
    });

    test('amount, merchant and date fold it even with no reference', () {
      expectSettledOnce(
        build(obligations: [lic()], actuals: [licDebit()]),
      );
    });

    test('a self-transfer matching no obligation stays a transfer', () {
      final items = build(
        obligations: [lic()],
        actuals: [
          actual(
            amountPaise: 2500000,
            date: DateTime(2026, 8, 9),
            type: TxnType.transfer,
            merchant: 'SELF ACCOUNT 9012',
            categoryKey: 'transfer',
            smsId: 'self',
          ),
        ],
      );
      final transfer = byOwner(items, ForecastOwner.transfer);
      expect(transfer.amountPaise, 2500000);
      expect(
        byOwner(items, ForecastOwner.gmailBill).paymentStatus,
        ReconciliationPaymentStatus.unpaid,
      );
    });

    test('a NEFT debit matching no obligation stays a transfer', () {
      final items = build(
        actuals: [
          actual(
            amountPaise: 1500000,
            date: DateTime(2026, 8, 9),
            type: TxnType.transfer,
            merchant: 'RAMESH KUMAR',
            categoryKey: 'transfer',
            smsId: 'neft-p2p',
          ),
        ],
      );
      expect(byOwner(items, ForecastOwner.transfer).amountPaise, 1500000);
    });
  });

  group('match keys separate obligations by amount (§7 one owner per rupee)', () {
    // A card bill and a home-loan EMI at the same bank, both monthly. Before
    // amount bands these shared `merch:hdfc:monthly` and the loser vanished.
    List<ObligationRecord> hdfcPair({
      int billPaise = 500000,
      int emiPaise = 4500000,
    }) => [
      obligation(
        sourceType: ObligationSourceType.gmail,
        amountPaise: billPaise,
        merchant: 'HDFC',
        merchantNorm: 'hdfc',
        dueDate: DateTime(2026, 8, 12),
        dedupeKey: 'gmail:hdfc-card',
        id: 1,
      ),
      obligation(
        sourceType: ObligationSourceType.manual,
        amountPaise: emiPaise,
        merchant: 'HDFC',
        merchantNorm: 'hdfc',
        dueDate: DateTime(2026, 8, 20),
        dedupeKey: 'manual:hdfc-emi',
        id: 2,
      ),
    ];

    test('two amounts at one merchant both reach the ledger', () {
      final items = build(obligations: hdfcPair());
      expect(
        items.map((i) => i.matchKey).toSet(),
        hasLength(2),
        reason: 'a ₹5,000 bill and a ₹45,000 EMI are not the same obligation',
      );

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 2),
      );
      expect(
        result.events.map((e) => e.amountPaise).toSet(),
        {500000, 4500000},
      );
    });

    test('the same amount twice is still deduped, and the loser is named', () {
      final items = build(obligations: hdfcPair(emiPaise: 500000));
      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 2),
      );

      expect(result.events, hasLength(1));
      final suppressed = result.coverageLines.singleWhere(
        (line) => line.reason == CoverageReason.duplicateSuppressed,
      );
      expect(suppressed.amountPaise, 500000);
      expect(suppressed.ownerKey, 'gmailBill:obl:manual:hdfc-emi');
    });

    test('a ₹5,000 debit does not clear the ₹45,000 EMI it references', () {
      // The reference lane skips the amount check, which is how one small
      // payment used to mark a large obligation paid.
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: 500000,
            merchant: 'HDFC',
            merchantNorm: 'hdfc',
            dueDate: DateTime(2026, 8, 12),
            dedupeKey: 'gmail:hdfc-card',
            sourceId: 'REF900',
            id: 1,
          ),
          obligation(
            sourceType: ObligationSourceType.manual,
            amountPaise: 4500000,
            merchant: 'HDFC',
            merchantNorm: 'hdfc',
            dueDate: DateTime(2026, 8, 20),
            dedupeKey: 'manual:hdfc-emi',
            sourceId: 'REF900',
            id: 2,
          ),
        ],
        actuals: [
          actual(
            amountPaise: 500000,
            date: DateTime(2026, 8, 12),
            merchant: 'HDFC',
            refNumber: 'REF900',
            smsId: 'pay-card',
          ),
        ],
      );

      final paid = items.where(
        (i) => i.paymentStatus == ReconciliationPaymentStatus.paid,
      );
      expect(paid, hasLength(1));
      expect(paid.single.amountPaise, 500000);
      // Left alone, not held for review: nothing suggests the EMI was paid, so
      // it must stay in the ledger rather than be excluded into review.
      expect(
        items
            .singleWhere((i) => i.id == 'obl:manual:hdfc-emi')
            .paymentStatus,
        ReconciliationPaymentStatus.unpaid,
      );
    });

    test('an amountless sibling leaves the key unbanded so both still fold', () {
      // An unknown amount is not a different amount: banding around it would
      // split the pair and subtract the same bill twice.
      final items = build(
        obligations: [
          obligation(
            sourceType: ObligationSourceType.gmail,
            amountPaise: null,
            amountStatus: AmountStatus.missing,
            merchant: 'HDFC',
            merchantNorm: 'hdfc',
            dueDate: DateTime(2026, 8, 12),
            dedupeKey: 'gmail:hdfc-card',
            id: 1,
          ),
        ],
        commitments: [
          commitment(
            amountPaise: 500000,
            merchantNorm: 'hdfc',
            nextExpected: DateTime(2026, 8, 12),
          ),
        ],
      );
      expect(items.map((i) => i.matchKey).toSet(), hasLength(1));
    });

    test('a losing member of a three-way group is never silently dropped', () {
      final items = build(
        obligations: hdfcPair(emiPaise: 500000),
        commitments: [
          commitment(
            amountPaise: 500000,
            merchantNorm: 'hdfc',
            nextExpected: DateTime(2026, 8, 12),
          ),
        ],
      );
      expect(items.map((i) => i.matchKey).toSet(), hasLength(1));

      final result = reconcile(
        targetMonth: _target,
        anchor: _anchor,
        items: items,
        now: DateTime(2026, 8, 2),
      );
      expect(result.events, hasLength(1));
      expect(
        result.coverageLines
            .where((l) => l.reason == CoverageReason.duplicateSuppressed)
            .map((l) => l.ownerKey)
            .toSet(),
        hasLength(2),
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
          confirmedFronts: const <String>{},
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

        final result = reconcile(
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

      final result = reconcile(
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
        final result = reconcile(
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

      final result = reconcile(
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

      final result = reconcile(
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

  group('TASK-37 — a retired obligation owns nothing in the target month', () {
    // This is the path the device's duplicates actually took. The stored
    // `sms_mandate:` obligations are `onetime`, and `_obligationHitsMonth`
    // returns false for onetime, so they never project into a horizon month at
    // all — the three ₹1,999 lines were in August, the *target* month, which
    // is reconciled here rather than by `_projectCanonicalObligations`.
    // Skipping retired rows there alone left the real defect on screen.
    ObligationRecord google({DateTime? retiredAt}) => obligation(
      sourceType: ObligationSourceType.smsRecurring,
      amountPaise: 199900,
      merchant: 'xfkxfma537eoyvuzwkvss3vbvbr1oxoo',
      merchantNorm: 'xfkxfma537eoyvuzwkvss3vbvbr1oxoo',
      dueDate: DateTime(2026, 8, 28),
      retiredAt: retiredAt,
    );

    test('a live one becomes an owner (guard)', () {
      final items = build(obligations: [google()]);

      expect(items.where((i) => i.amountPaise == 199900), hasLength(1));
    });

    test('a retired one does not', () {
      final items = build(obligations: [google(retiredAt: DateTime(2026, 8, 4))]);

      expect(items.where((i) => i.amountPaise == 199900), isEmpty);
    });
  });
}
