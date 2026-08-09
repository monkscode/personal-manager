import 'card_models.dart';
import 'card_settlement_front_store.dart';
import 'forecast_models.dart';
import 'forecast_risk_models.dart';
import 'models.dart';
import 'obligation_models.dart';
import 'self_transfer_decision_store.dart';
import 'sms_models.dart';
import '../services/card_cycle_estimator.dart';
import '../services/card_settlement_candidates.dart';
import '../services/cash_coverage_metrics.dart';
import '../services/money_lens.dart';
import '../services/reconciliation_matcher.dart';
import '../services/recurring_debit_detector.dart';
import '../services/reserve_planner.dart';
import '../services/salary_income_detector.dart';
import '../services/self_transfer_detector.dart';
import '../services/seasonal_estimator.dart';

/// Months of history the reduced snapshot reads once. Covers same-month
/// last-year (year-over-year) plus the trailing-N seasonal window with headroom.
const int kAnalysisLookbackMonths = 13;

/// Same-month expected-vs-actual comparison for one category (spec §Insights
/// "this month last year vs now").
class YearOverYearCategory {
  const YearOverYearCategory({
    required this.categoryKey,
    required this.lastYearPaise,
    required this.currentPaise,
  });

  final String categoryKey;
  final int lastYearPaise;
  final int currentPaise;

  int get deltaPaise => currentPaise - lastYearPaise;
}

/// An immutable, **fully reduced** analysis of the SMS/obligation data path.
///
/// The async SQLite boundary is crossed exactly once to produce this (see
/// `TransactionsNotifier`); the synchronous UI never re-scans deep history. All
/// D1–D8 producers and the estimator run here, and their results are cached as
/// plain value objects.
class SmsAnalysisSnapshot {
  SmsAnalysisSnapshot({
    required this.targetMonth,
    required this.hasData,
    required this.commitments,
    required this.reviewCandidates,
    required this.salary,
    required this.otherIncome,
    required this.seasonal,
    required this.reconciliationItems,
    required this.cards,
    required this.currentMonthTxns,
    required this.yearOverYear,
    required this.cashLevel,
    required this.cashDrainRatio,
    required this.currentMonthAtmPaise,
    required this.obligations,
    required this.reservePlan,
    required this.riskDecisions,
    this.horizonSeasonal = const [],
    this.allTxns = const [],
    this.supersededRedeliveries = const [],
    this.anchor,
    this.anchorFreshness,
    this.primaryAccountLast4,
    this.selfTransferCandidates = const [],
    this.settlementCandidates = const [],
    this.confirmedSettlementFronts = const <String>{},
  }) : spendLensTxns = spendLensOf(
         allTxns.isNotEmpty ? allTxns : currentMonthTxns,
         confirmedSettlementFronts,
       ),
       everydayCashTxns = List.unmodifiable([
         // Same set `real_insights` calls `history`: [allTxns] when it was
         // filled, and the target month alone when it was not. Deriving over a
         // different set is how a lens quietly reports ₹0.
         for (final txn in allTxns.isNotEmpty ? allTxns : currentMonthTxns)
           if (MoneyLens.isEverydayCashSpend(txn, confirmedSettlementFronts))
             txn,
       ]);

  /// The spend lens over an already-filtered working set. The one definition,
  /// so [reduce] and the constructor cannot drift apart.
  static List<ParsedTxn> spendLensOf(
    List<ParsedTxn> txns,
    Set<String> confirmedFronts,
  ) => List.unmodifiable([
    for (final txn in txns)
      if (MoneyLens.isSpend(txn, confirmedFronts)) txn,
  ]);

  /// An empty snapshot with no SMS-derived data.
  factory SmsAnalysisSnapshot.empty(DateTime now) => SmsAnalysisSnapshot(
    targetMonth: DateTime(now.year, now.month),
    hasData: false,
    commitments: const [],
    reviewCandidates: const [],
    salary: const SalaryProfile(confidence: SalaryConfidence.insufficientData),
    otherIncome: const [],
    seasonal: SeasonalEstimate(targetMonth: now.month, byCategory: const {}),
    reconciliationItems: const [],
    cards: const [],
    currentMonthTxns: const [],
    yearOverYear: const {},
    cashLevel: CashCoverageLevel.none,
    cashDrainRatio: 0,
    currentMonthAtmPaise: 0,
    obligations: const [],
    reservePlan: const ReservePlan.empty(),
    riskDecisions: const [],
  );

  final DateTime targetMonth;

  /// Rows in [targetMonth] that a second alert for the same debit already
  /// carries, and which [reduce] therefore left out of the working set
  /// (TASK-43). Kept so the omission can be *named* rather than silently
  /// dropped — a suppressed duplicate must never look like money that vanished.
  final List<ParsedTxn> supersededRedeliveries;

  /// Whether any SMS-derived transaction or obligation exists. Drives live mode.
  final bool hasData;

  final List<RecurringCommitment> commitments;
  final List<ReviewCandidate> reviewCandidates;
  final SalaryProfile salary;
  final List<IncomeCandidate> otherIncome;
  final SeasonalEstimate seasonal;

  /// One seasonal estimate per month of the forecast horizon, indexed by offset
  /// from [targetMonth] — element 0 is [seasonal] itself.
  ///
  /// The estimator was called once, for the target month, so horizon months 1
  /// through 11 modelled rent and EMIs against full salary with no groceries,
  /// fuel or eating out at all — false-safe in the one direction the spec
  /// forbids (TASK-21). Empty means "not estimated", which the adapter reports
  /// as a coverage line rather than treating as zero spend.
  final List<SeasonalEstimate> horizonSeasonal;

  /// Owned reconciliation items for [targetMonth], ready for the forecast
  /// reconciliation engine (paid/unpaid already resolved).
  final List<ReconciliationItem> reconciliationItems;

  final List<CardCycleEstimate> cards;
  final List<ParsedTxn> currentMonthTxns;

  /// The full active (non-dismissed) transaction history loaded for analysis,
  /// newest first. Drives the Activity tab's full history and the Home recent
  /// transactions strip. [currentMonthTxns] is the target-month subset.
  final List<ParsedTxn> allTxns;

  /// [allTxns] narrowed to what the user actually consumed — card purchases on
  /// the day they were made, card refunds netting negative on the day they
  /// arrived, no card bill payments (`MoneyLens.isSpend`).
  ///
  /// Derived in the constructor rather than at each call site, so it is the
  /// **same** working set every consumer of [allTxns] reads and every exclusion
  /// `reduce` applies is inherited without being repeated. A predicate applied
  /// at call sites is not a rule; only one applied where the set is defined is
  /// (TASK-41). Named `spendLensTxns` because `real_insights` already has a
  /// local called `spendTxns` that means something narrower.
  final List<ParsedTxn> spendLensTxns;

  /// [allTxns] narrowed to genuine consumption that left the *bank*
  /// (`MoneyLens.isEverydayCashSpend`) — the planning baseline behind the
  /// required figure, which is a cash question, not a consumption one.
  final List<ParsedTxn> everydayCashTxns;

  /// Debit/credit pairs that look like money moving between the user's own
  /// accounts and that the user has **not answered yet**.
  ///
  /// Carried on the snapshot rather than detected by the review page so Home
  /// can tell there is a question outstanding without a second read of deep
  /// history. The page is otherwise only reached when a scan adds or queues a
  /// row, which never happens on an already-scanned device.
  final List<SelfTransferCandidate> selfTransferCandidates;

  /// Merchants the user has not yet answered "is this a card bill payment?"
  /// for. Empty once every front on this device is decided.
  final List<CardSettlementCandidate> settlementCandidates;

  /// The merchants the user confirmed are card-bill payment fronts. Carried on
  /// the snapshot because `real_insights` re-derives the settlement flag per
  /// row when it builds the activity list.
  final Set<String> confirmedSettlementFronts;

  final Map<String, YearOverYearCategory> yearOverYear;

  final CashCoverageLevel cashLevel;
  final double cashDrainRatio;
  final int currentMonthAtmPaise;

  /// Obligations loaded once from the database.
  final List<ObligationRecord> obligations;

  /// Reserve plan built from obligations.
  final ReservePlan reservePlan;

  /// Risk decisions loaded once from the database.
  final List<ForecastRiskDecision> riskDecisions;

  final BalanceAnchor? anchor;
  final AnchorFreshness? anchorFreshness;
  final String? primaryAccountLast4;

  bool get isAnchorStale => anchorFreshness == AnchorFreshness.stale;

  /// Runs all D1–D8 producers + the estimator over already-loaded rows. Pure
  /// and deterministic given [now]; no I/O — the caller performs the single
  /// async read.
  static SmsAnalysisSnapshot reduce({
    required List<ParsedTxn> history,
    required List<ObligationRecord> obligations,
    required List<ForecastRiskDecision> riskDecisions,
    required List<ContribPlan> configuredPlans,
    required DateTime now,
    String? configuredSalaryRupees,
    SelfTransferDecisions selfTransferDecisions = const SelfTransferDecisions(
      {},
    ),
    CardSettlementFronts settlementFronts = CardSettlementFronts.empty,
  }) {
    // The working set every producer below reads from.
    //
    // A future-debit notice is excluded *here*, not at each consumer. Rows
    // written before TASK-32 taught the parser to route notices to obligations
    // are still on disk as completed debits — a reparse rewrites a stored row
    // but cannot retire one — and the bank sends the real debit alert a day or
    // two later, so each of those rows double-counts a rupee that is already
    // owned. The check used to sit on four leaf consumers instead, which meant
    // `spentThisMonthPaise` excluded the phantom while `currentMonthTxns` —
    // and therefore reconciliation, the forecast events and the drivers list
    // built from them — still counted it. Filtering the working set is what
    // makes the exclusion hold for read paths added later too (TASK-41).
    // A second bank alert for a debit another row already carries is excluded
    // on the same argument: one owner per rupee, and the exclusion belongs
    // where the set is defined so every later read path inherits it (TASK-43).
    final active = [
      for (final txn in history)
        if (txn.reviewStatus != ReviewStatus.dismissed &&
            !txn.isFutureDebitNotice &&
            txn.supersededBySmsId == null)
          txn,
    ];
    final confirmedFronts = settlementFronts.confirmed;
    final targetMonth = DateTime(now.year, now.month);
    // Kept so the omission can be named. Only the target month's are carried:
    // the coverage lines that consume them are month-scoped.
    final supersededRedeliveries = [
      for (final txn in history)
        if (txn.reviewStatus != ReviewStatus.dismissed &&
            txn.supersededBySmsId != null &&
            txn.txnMonth == _monthKey(targetMonth))
          txn,
    ];
    final credits = [
      for (final txn in active)
        if (txn.direction == TransactionDirection.credit) txn,
    ];

    const salaryDetector = SalaryIncomeDetector();
    final primaryAccountLast4 = salaryDetector.resolvePrimaryAccountLast4(
      active,
      now: now,
      mostRecentBalanceAccountLast4: _mostRecentBalanceAccount(active),
    );
    final anchor = _deriveAnchor(active, primaryAccountLast4);

    const detector = RecurringDebitDetector();
    final commitments = detector.detect(
      active,
      configuredPlans: configuredPlans,
      now: now,
    );
    final reviewCandidates = detector.possibleRecurring(
      active,
      configuredPlans: configuredPlans,
      now: now,
    );

    final salary = salaryDetector.detectSalary(
      credits,
      configuredSalaryRupees: configuredSalaryRupees,
      now: now,
    );
    final otherIncome = salaryDetector.detectOtherIncome(credits, now: now);

    final ownedOwnerKeys = _ownedOwnerKeys(active, commitments);
    // One estimate per horizon month, not just the target month: every future
    // month needs its own seasonal magnitude or it projects fixed costs against
    // full salary and reads as confidently in surplus (TASK-21). December's
    // higher spend lands in December because the estimator is asked about
    // December.
    final horizonSeasonal = <SeasonalEstimate>[
      for (var offset = 0; offset < kForecastHorizonMonths; offset++)
        const SeasonalEstimator().estimate(
          targetMonth1to12: DateTime(
            targetMonth.year,
            targetMonth.month + offset,
          ).month,
          discretionaryHistory: active,
          ownedOwnerKeys: ownedOwnerKeys,
          now: now,
        ),
    ];
    final seasonal = horizonSeasonal.first;

    final cards = _cardEstimates(active, targetMonth, confirmedFronts);

    final currentMonthTxns = [
      for (final txn in active)
        if (txn.txnMonth == _ym(targetMonth)) txn,
    ];
    final matcherAnchor =
        anchor ??
        BalanceAnchor(
          amountPaise: 0,
          asOf: now,
          source: BalanceAnchorSource.projectedCarryForward,
          hasEvidence: false,
        );
    final reconciliationItems = const ReconciliationMatcher().buildItems(
      actuals: currentMonthTxns,
      obligations: obligations,
      commitments: commitments,
      seasonal: seasonal,
      salary: salary,
      cards: cards,
      anchor: matcherAnchor,
      targetMonth: targetMonth,
      confirmedFronts: confirmedFronts,
    );

    const cash = CashCoverageMetrics();
    final window = cash.trailingWindow(active, now);

    final reservePlan = const ReservePlanner().build(
      obligations: obligations,
      now: now,
      expectedSalaryDay: salary.expectedDay,
    );

    final allTxns = [...active]
      ..sort((a, b) => b.txnDate.compareTo(a.txnDate));

    return SmsAnalysisSnapshot(
      targetMonth: targetMonth,
      hasData: active.isNotEmpty || obligations.isNotEmpty,
      commitments: List.unmodifiable(commitments),
      reviewCandidates: List.unmodifiable(reviewCandidates),
      salary: salary,
      otherIncome: List.unmodifiable(otherIncome),
      seasonal: seasonal,
      horizonSeasonal: horizonSeasonal,
      reconciliationItems: List.unmodifiable(reconciliationItems),
      cards: List.unmodifiable(cards),
      currentMonthTxns: List.unmodifiable(currentMonthTxns),
      allTxns: List.unmodifiable(allTxns),
      supersededRedeliveries: List.unmodifiable(supersededRedeliveries),
      yearOverYear: Map.unmodifiable(
        _yearOverYear(spendLensOf(active, confirmedFronts), now),
      ),
      cashLevel: cash.level(window),
      cashDrainRatio: cash.cashDrainRatio(window),
      currentMonthAtmPaise: cash.currentMonthToDateAtmPaise(active, now),
      obligations: List.unmodifiable(obligations),
      reservePlan: reservePlan,
      riskDecisions: List.unmodifiable(riskDecisions),
      anchor: anchor,
      anchorFreshness: anchor?.freshnessAsOf(now),
      primaryAccountLast4: primaryAccountLast4,
      // Detected over `active`, so a dismissed or superseded row is not
      // proposed, and filtered to what the user has not answered — a stored
      // "no" is as final as a stored "yes".
      selfTransferCandidates: List.unmodifiable([
        for (final candidate in const SelfTransferDetector().candidates(active))
          if (!selfTransferDecisions.isDecided(candidate.debit.smsId))
            candidate,
      ]),
      settlementCandidates: List.unmodifiable(
        const CardSettlementCandidateFinder().find(active, settlementFronts),
      ),
      confirmedSettlementFronts: confirmedFronts,
    );
  }

  // ---- reduction helpers --------------------------------------------------

  static String _monthKey(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-'
      '${month.month.toString().padLeft(2, '0')}';

  static String? _mostRecentBalanceAccount(List<ParsedTxn> active) {
    ParsedTxn? newest;
    for (final txn in active) {
      if (txn.balancePaise == null) continue;
      if (txn.instrument != PaymentInstrument.bank) continue;
      if (txn.accountLast4 == null) continue;
      if (newest == null || txn.txnDate.isAfter(newest.txnDate)) newest = txn;
    }
    return newest?.accountLast4;
  }

  static BalanceAnchor? _deriveAnchor(
    List<ParsedTxn> active,
    String? primaryAccountLast4,
  ) {
    if (primaryAccountLast4 == null) return null;
    ParsedTxn? newest;
    for (final txn in active) {
      if (txn.balancePaise == null) continue;
      if (txn.instrument != PaymentInstrument.bank) continue;
      if (txn.accountLast4 != primaryAccountLast4) continue;
      if (newest == null || txn.txnDate.isAfter(newest.txnDate)) newest = txn;
    }
    if (newest == null) return null;
    return BalanceAnchor(
      amountPaise: newest.balancePaise!,
      asOf: newest.txnDate,
      accountLast4: newest.accountLast4,
      source: BalanceAnchorSource.smsBankBalance,
    );
  }

  static Set<String> _ownedOwnerKeys(
    List<ParsedTxn> active,
    List<RecurringCommitment> commitments,
  ) {
    final commitmentNorms = {for (final c in commitments) c.merchantNorm};
    return {
      for (final txn in active)
        if (txn.ownerKey != null &&
            commitmentNorms.contains(_normMerchant(txn)))
          txn.ownerKey!,
    };
  }

  static List<CardCycleEstimate> _cardEstimates(
    List<ParsedTxn> active,
    DateTime targetMonth,
    Set<String> confirmedFronts,
  ) {
    final byCard = <String, List<ParsedTxn>>{};
    for (final txn in active) {
      if (txn.instrument != PaymentInstrument.card) continue;
      byCard.putIfAbsent(txn.accountLast4 ?? 'unknown', () => []).add(txn);
    }
    const estimator = CardCycleEstimator();
    return [
      for (final entry in byCard.entries)
        _estimateSinceLastPayment(
          estimator,
          entry.value,
          targetMonth,
          confirmedFronts,
        ),
    ];
  }

  /// One card's estimate, counted forward from the last time its bill was paid.
  ///
  /// The window is applied **here**, where the per-card set is built, and not
  /// inside the estimator: which transactions belong to a cycle is a question
  /// about set membership, and TASK-41's rule is that membership is decided
  /// once, where the set is defined. It also keeps the estimator's own
  /// bill-payment guard reachable — a payment credit is always the boundary, so
  /// windowing inside would have made TASK-28's net unable to fire.
  ///
  /// With no payment credit in history the window has no start and every row is
  /// counted, which is a lifetime total and is labelled as one rather than
  /// presented as a single bill.
  static CardCycleEstimate _estimateSinceLastPayment(
    CardCycleEstimator estimator,
    List<ParsedTxn> cardTxns,
    DateTime targetMonth,
    Set<String> confirmedFronts,
  ) {
    final windowStart = lastCardBillPaymentDate(cardTxns);
    return estimator.estimate(
      windowStart == null
          ? cardTxns
          : [
              for (final txn in cardTxns)
                if (txn.txnDate.isAfter(windowStart)) txn,
            ],
      statementMonth: targetMonth,
      windowStart: windowStart,
      // The card is named from the full history, not the window: a card whose
      // every row predates its last payment still has an identity, and falling
      // back to 'unknown' there would merge it with a genuinely unidentified
      // card.
      cardLast4Fallback: cardTxns
          .map((t) => t.accountLast4)
          .firstWhere((last4) => last4 != null, orElse: () => null),
      confirmedFronts: confirmedFronts,
    );
  }

  /// Same-month-last-year comparison, over [spendLensTxns].
  ///
  /// It used to carry its own predicate — debit, not transfer/atm, not a
  /// notice — which never consulted `_isConsumptionSpend` and so counted a card
  /// purchase *and* the settlement that paid for it. That is one rupee with two
  /// owners in the one place the user compares months side by side.
  static Map<String, YearOverYearCategory> _yearOverYear(
    List<ParsedTxn> spendLensTxns,
    DateTime now,
  ) {
    final current = <String, int>{};
    final lastYear = <String, int>{};
    for (final txn in spendLensTxns) {
      if (txn.txnDate.month != now.month) continue;
      final paise = MoneyLens.signedSpendPaise(txn);
      if (txn.txnDate.year == now.year) {
        current[txn.categoryKey] = (current[txn.categoryKey] ?? 0) + paise;
      } else if (txn.txnDate.year == now.year - 1) {
        lastYear[txn.categoryKey] = (lastYear[txn.categoryKey] ?? 0) + paise;
      }
    }
    final keys = {...current.keys, ...lastYear.keys};
    return {
      for (final key in keys)
        key: YearOverYearCategory(
          categoryKey: key,
          lastYearPaise: lastYear[key] ?? 0,
          currentPaise: current[key] ?? 0,
        ),
    };
  }

  static String _ym(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}';

  static String _normMerchant(ParsedTxn txn) =>
      (txn.merchant ?? txn.upiVpaNorm ?? txn.sender)
          .toLowerCase()
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
}
