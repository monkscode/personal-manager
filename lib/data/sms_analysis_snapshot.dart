import 'card_models.dart';
import 'forecast_models.dart';
import 'forecast_risk_models.dart';
import 'models.dart';
import 'obligation_models.dart';
import 'sms_models.dart';
import '../services/card_cycle_estimator.dart';
import '../services/cash_coverage_metrics.dart';
import '../services/reconciliation_matcher.dart';
import '../services/recurring_debit_detector.dart';
import '../services/reserve_planner.dart';
import '../services/salary_income_detector.dart';
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
  const SmsAnalysisSnapshot({
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
    this.allTxns = const [],
    this.anchor,
    this.anchorFreshness,
    this.primaryAccountLast4,
  });

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

  /// Whether any SMS-derived transaction or obligation exists. Drives live mode.
  final bool hasData;

  final List<RecurringCommitment> commitments;
  final List<ReviewCandidate> reviewCandidates;
  final SalaryProfile salary;
  final List<IncomeCandidate> otherIncome;
  final SeasonalEstimate seasonal;

  /// Owned reconciliation items for [targetMonth], ready for the forecast
  /// reconciliation engine (paid/unpaid already resolved).
  final List<ReconciliationItem> reconciliationItems;

  final List<CardCycleEstimate> cards;
  final List<ParsedTxn> currentMonthTxns;

  /// The full active (non-dismissed) transaction history loaded for analysis,
  /// newest first. Drives the Activity tab's full history and the Home recent
  /// transactions strip. [currentMonthTxns] is the target-month subset.
  final List<ParsedTxn> allTxns;
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
  }) {
    final active = [
      for (final txn in history)
        if (txn.reviewStatus != ReviewStatus.dismissed) txn,
    ];
    final targetMonth = DateTime(now.year, now.month);
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
    final seasonal = const SeasonalEstimator().estimate(
      targetMonth1to12: now.month,
      discretionaryHistory: active,
      ownedOwnerKeys: ownedOwnerKeys,
      now: now,
    );

    final cards = _cardEstimates(active, targetMonth);

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
      reconciliationItems: List.unmodifiable(reconciliationItems),
      cards: List.unmodifiable(cards),
      currentMonthTxns: List.unmodifiable(currentMonthTxns),
      allTxns: List.unmodifiable(allTxns),
      yearOverYear: Map.unmodifiable(_yearOverYear(active, now)),
      cashLevel: cash.level(window),
      cashDrainRatio: cash.cashDrainRatio(window),
      currentMonthAtmPaise: cash.currentMonthToDateAtmPaise(active, now),
      obligations: List.unmodifiable(obligations),
      reservePlan: reservePlan,
      riskDecisions: List.unmodifiable(riskDecisions),
      anchor: anchor,
      anchorFreshness: anchor?.freshnessAsOf(now),
      primaryAccountLast4: primaryAccountLast4,
    );
  }

  // ---- reduction helpers --------------------------------------------------

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
  ) {
    final byCard = <String, List<ParsedTxn>>{};
    for (final txn in active) {
      if (txn.instrument != PaymentInstrument.card) continue;
      byCard.putIfAbsent(txn.accountLast4 ?? 'unknown', () => []).add(txn);
    }
    const estimator = CardCycleEstimator();
    return [
      for (final entry in byCard.entries)
        estimator.estimate(entry.value, statementMonth: targetMonth),
    ];
  }

  static Map<String, YearOverYearCategory> _yearOverYear(
    List<ParsedTxn> active,
    DateTime now,
  ) {
    final current = <String, int>{};
    final lastYear = <String, int>{};
    for (final txn in active) {
      if (txn.direction != TransactionDirection.debit) continue;
      if (txn.type == TxnType.transfer || txn.type == TxnType.atm) continue;
      if (txn.txnDate.month != now.month) continue;
      if (txn.txnDate.year == now.year) {
        current[txn.categoryKey] =
            (current[txn.categoryKey] ?? 0) + txn.amountPaise;
      } else if (txn.txnDate.year == now.year - 1) {
        lastYear[txn.categoryKey] =
            (lastYear[txn.categoryKey] ?? 0) + txn.amountPaise;
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
