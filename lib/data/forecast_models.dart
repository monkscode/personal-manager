import 'sms_models.dart';

enum LedgerDirection { inflow, outflow }

enum ForecastEventSource {
  salary,
  otherIncome,
  recurring,
  gmailBill,
  seasonal,
  transfer,
  manual,
  untrackedCash,
  cardOutstanding,
  cardStatement,
  cardPayment,
  refund,
  configuredContribution,
  currentActual,
}

enum BalanceAnchorSource {
  smsBankBalance,
  manualUserEntry,
  projectedCarryForward,
}

enum AnchorFreshness { current, amber, stale }

enum CoverageReason {
  untrackedCash,
  staleAnchor,
  outOfPrimaryScope,
  unscheduledObligation,
  reviewNeeded,
  possiblyAlreadyPaid,
  p2pConfirmationRequired,
  setCardCycle,
  transferBridgeReview,
  partialCardOutstanding,
  accountHintUncertain,
  overBudgetDiscretionary,
  cardCycleOnly,
  futureEarmark,
}

enum CoverageAction {
  confirmBalance,
  setDueMonth,
  dismiss,
  markUnpaid,
  linkAccount,
  review,
  confirmIncome,
  setCardCycle,
  none,
}

enum ForecastLineStatus {
  opening,
  paid,
  unpaid,
  overdue,
  alreadyInAnchor,
  projected,
  review,
  coverage,
  estimated,
  exceeded,
  reconciled,
}

class BalanceAnchor {
  const BalanceAnchor({
    required this.amountPaise,
    required this.asOf,
    required this.source,
    this.accountLast4,
  });

  final int amountPaise;
  final DateTime asOf;
  final String? accountLast4;
  final BalanceAnchorSource source;

  AnchorFreshness freshnessAsOf(DateTime now) {
    final anchorDay = DateTime(asOf.year, asOf.month, asOf.day);
    final nowDay = DateTime(now.year, now.month, now.day);
    final ageDays = nowDay.difference(anchorDay).inDays;
    return switch (ageDays) {
      <= 1 => AnchorFreshness.current,
      <= 5 => AnchorFreshness.amber,
      _ => AnchorFreshness.stale,
    };
  }
}

class ForecastEvent {
  const ForecastEvent({
    required this.date,
    required this.amountPaise,
    required this.direction,
    required this.source,
    required this.ownerKey,
    required this.label,
    required this.confidence,
    this.isUserConfirmed = false,
    this.obligationDedupeKey,
  }) : assert(amountPaise >= 0),
       assert(confidence >= 0 && confidence <= 1);

  final DateTime date;
  final int amountPaise;
  final LedgerDirection direction;
  final ForecastEventSource source;
  final String ownerKey;
  final String label;
  final double confidence;

  /// Whether the user has explicitly confirmed this event (obligation
  /// reviewStatus == confirmed or a risk decision promotes it).
  final bool isUserConfirmed;

  /// The canonical obligation dedupe key, if this event originated from an
  /// obligation. Used for stable matching against risk decisions.
  final String? obligationDedupeKey;
}

class ForecastCoverageLine {
  const ForecastCoverageLine({
    required this.label,
    required this.reason,
    required this.action,
    required this.confidence,
    this.amountPaise,
    this.ownerKey,
  }) : assert(amountPaise == null || amountPaise >= 0),
       assert(confidence >= 0 && confidence <= 1);

  final String label;
  final int? amountPaise;
  final CoverageReason reason;
  final CoverageAction action;
  final double confidence;
  final String? ownerKey;
}

class ForecastLine {
  const ForecastLine({
    required this.label,
    required this.amountPaise,
    required this.source,
    required this.ownerKey,
    required this.status,
    required this.confidence,
    this.date,
    this.note,
    this.isUserConfirmed = false,
    this.obligationDedupeKey,
  }) : assert(confidence >= 0 && confidence <= 1);

  final String label;
  final int amountPaise;
  final ForecastEventSource source;
  final DateTime? date;
  final String ownerKey;
  final ForecastLineStatus status;
  final double confidence;
  final String? note;

  /// Whether the user has explicitly confirmed this line.
  final bool isUserConfirmed;

  /// The canonical obligation dedupe key for stable risk-decision matching.
  final String? obligationDedupeKey;
}

class ForecastMonthResult {
  const ForecastMonthResult({
    required this.openingBalancePaise,
    required this.closingBalancePaise,
    required this.minimumBalancePaise,
    required this.minimumBalanceDate,
    required this.shortfallPaise,
    required this.events,
    required this.coverageLines,
    required this.anchor,
    required this.anchorFreshness,
    required this.lines,
  }) : assert(shortfallPaise >= 0);

  final int openingBalancePaise;
  final int closingBalancePaise;
  final int minimumBalancePaise;
  final DateTime minimumBalanceDate;
  final int shortfallPaise;
  final List<ForecastEvent> events;
  final List<ForecastCoverageLine> coverageLines;
  final BalanceAnchor anchor;
  final AnchorFreshness anchorFreshness;
  final List<ForecastLine> lines;
}

class OwnedForecastItem {
  const OwnedForecastItem({
    required this.itemId,
    required this.ownerKey,
    required this.owner,
    required this.coverageBucket,
    required this.status,
    this.amountPaise,
  }) : assert(amountPaise == null || amountPaise >= 0);

  final String itemId;
  final String ownerKey;
  final ForecastOwner owner;
  final CoverageBucket coverageBucket;
  final ForecastLineStatus status;
  final int? amountPaise;
}

enum ForecastOwner {
  recurringCommitment,
  gmailBill,
  configuredContribution,
  cardPurchase,
  cardStatement,
  cardPayment,
  refund,
  transfer,
  atmCash,
  nonPrimaryAccountObligation,
  annualUnscheduled,
  recurringP2pOutflow,
  p2pIncomeCandidate,
  discretionarySpend,
  salary,
  otherIncome,
}

enum ForecastItemSource { sms, gmail, manual, configuredPlan, estimator }

enum AccountScope { primary, secondary, unknown }

enum AmountStatus { known, missing, estimated }

enum ReconciliationPaymentStatus {
  unpaid,
  paid,
  partial,
  possiblyPaid,
  outOfPrimaryScope,
}

enum ReconciliationRecurrence { onetime, monthly, quarterly, annual }

enum ReconciliationInstrument { bank, card }

enum UserCadenceStatus { algorithmDetected, userConfirmed, userDismissed }

class ReconciliationItem {
  const ReconciliationItem({
    required this.id,
    required this.label,
    required this.amountPaise,
    required this.direction,
    required this.owner,
    required this.source,
    this.dueDate,
    this.actualDate,
    this.matchKey,
    this.instrument = ReconciliationInstrument.bank,
    this.accountScope = AccountScope.primary,
    this.amountStatus = AmountStatus.known,
    this.paymentStatus = ReconciliationPaymentStatus.unpaid,
    this.recurrence = ReconciliationRecurrence.onetime,
    this.userCadenceStatus = UserCadenceStatus.userConfirmed,
    this.confidence = 1,
    this.transferBridgeToId,
    this.refundOfId,
    this.cardCycleKey,
    this.effectiveMonth,
    this.isUserConfirmed = false,
    this.obligationDedupeKey,
  }) : assert(amountPaise == null || amountPaise >= 0),
       assert(confidence >= 0 && confidence <= 1);

  final String id;
  final String label;
  final int? amountPaise;
  final LedgerDirection direction;
  final ForecastOwner owner;
  final ForecastItemSource source;
  final DateTime? dueDate;
  final DateTime? actualDate;
  final String? matchKey;
  final ReconciliationInstrument instrument;
  final AccountScope accountScope;
  final AmountStatus amountStatus;
  final ReconciliationPaymentStatus paymentStatus;
  final ReconciliationRecurrence recurrence;
  final UserCadenceStatus userCadenceStatus;
  final double confidence;
  final String? transferBridgeToId;
  final String? refundOfId;
  final String? cardCycleKey;
  final String? effectiveMonth;

  /// Whether the user has confirmed this obligation (ObligationReviewStatus.confirmed).
  final bool isUserConfirmed;

  /// Canonical obligation dedupe key for stable risk-decision matching.
  final String? obligationDedupeKey;

  DateTime? get eventDate => actualDate ?? dueDate;
  String get ownerKey => '${owner.name}:$id';
}

class ForecastReconciliationResult {
  const ForecastReconciliationResult({
    required this.events,
    required this.coverageLines,
    required this.lines,
    required this.assignments,
  });

  final List<ForecastEvent> events;
  final List<ForecastCoverageLine> coverageLines;
  final List<ForecastLine> lines;
  final List<OwnedForecastItem> assignments;
}
