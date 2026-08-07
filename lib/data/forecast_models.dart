import 'forecast_risk_models.dart';
import 'sms_models.dart';

/// Months of forward outlook the rolling ledger projects (matches the 12-bar
/// year chart the screens render).
///
/// Lives with the models rather than in `forecast_adapter.dart` so the snapshot
/// reducer can size its per-month seasonal estimates to the same horizon
/// without importing the adapter that consumes it (TASK-21).
const int kForecastHorizonMonths = 12;

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

  /// Dated outside the target month and already past its due date. Distinct
  /// from [futureEarmark]: this is money the user owes *now*, so it carries an
  /// action rather than being filed as a heads-up (TASK-24 M11).
  pastDueObligation,
  p2pConfirmationRequired,
  setCardCycle,
  transferBridgeReview,
  partialCardOutstanding,
  accountHintUncertain,
  overBudgetDiscretionary,
  cardCycleOnly,
  futureEarmark,

  /// Suppressed because a higher-precedence owner already carries this rupee.
  /// The amount is accounted for — by the winner — but it must still be named,
  /// or a dropped duplicate is indistinguishable from money that vanished.
  duplicateSuppressed,

  /// The forecast is opening on a fabricated ₹0 anchor because no bank SMS and
  /// no manual entry have ever supplied a balance. Distinct from
  /// [staleAnchor], which reports a real reading that has gone out of date
  /// (TASK-22).
  noBalanceEvidence,

  /// This month's everyday spending is not in the ledger — either there is no
  /// seasonal estimate for it, or the estimate was too weak to be treated as a
  /// hard event. Without this line a horizon month models rent and EMIs against
  /// full salary and reads as confidently in surplus (TASK-21).
  discretionaryNotModelled,

  /// A stored obligation whose dedupe key no scan can derive any more, so it is
  /// no longer projected. Usually harmless — a parser fix re-derived the same
  /// commitment under a corrected key and the live row carries the rupee — but
  /// it can also be a commitment that genuinely stopped, and the two are
  /// indistinguishable from here. Named so a commitment leaving the forecast is
  /// never silent (TASK-37).
  retiredObligation,
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
    this.hasEvidence = true,
  });

  final int amountPaise;
  final DateTime asOf;
  final String? accountLast4;
  final BalanceAnchorSource source;

  /// Whether this anchor traces back to an observed balance — an SMS reading or
  /// a number the user typed. `false` marks the fabricated ₹0 fallback the
  /// forecast synthesises when there is no balance evidence at all, and it must
  /// propagate to every month carried forward from it.
  ///
  /// An evidence-free anchor covers nothing: no amount may be treated as
  /// already reflected in it, and no month opening on it may read as confident
  /// (TASK-22).
  final bool hasEvidence;

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
    this.riskGroupKey,
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

  /// Set when this event is one slice of something the user reviews whole —
  /// see [ReconciliationItem.groupId]. Null for events reviewed on their own.
  final String? riskGroupKey;

  /// The identity risk decisions are keyed on: the group when there is one,
  /// otherwise the event's own [ownerKey].
  String get groupKey => riskGroupKey ?? ownerKey;
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
    required this.direction,
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

  /// Which way the money moves, copied from the event or reconciliation item
  /// this line describes.
  ///
  /// Required but nullable, so every construction site has to decide rather
  /// than inherit a default. `null` means the line is not a flow at all — the
  /// opening-balance line is the only such case. Consumers that total money
  /// moving one way must filter on this; summing lines blind to direction
  /// presents a credit as a debit.
  final LedgerDirection? direction;

  /// Whether the user has explicitly confirmed this line.
  final bool isUserConfirmed;

  /// The canonical obligation dedupe key for stable risk-decision matching.
  final String? obligationDedupeKey;
}

/// A forecast line that is where it is because the user decided so, paired with
/// the decision that put it there.
///
/// Exists because a risk decision used to be a one-way door (TASK-40): a
/// `dismissed` candidate reached no collection at all, and a `confirmed` one
/// moved into the hard lines, which render without controls. Neither could be
/// reversed from the app. This is a *control surface* — nothing sums it, and a
/// confirmed line appears here as well as in the ledger it now belongs to.
///
/// Only `confirmed` and `dismissed` are ever collected. A `pending` decision is
/// the absence of a decision, so there is nothing to undo.
class ForecastDecidedLine {
  const ForecastDecidedLine({required this.line, required this.status});

  /// For a confirmed decision this carries the *overridden* amount and date —
  /// the row the user sees must be the amount actually in the plan. For a
  /// dismissed one it is the untouched candidate, because an override on a
  /// dismissed decision never reached the ledger either.
  final ForecastLine line;

  final ForecastRiskDecisionStatus status;
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
    this.needsAttributionReview = false,
    this.groupId,
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

  /// The amount is certain but *what it belongs to* is not — two card
  /// statements a payment could equally have settled, say. The spec's rule is
  /// that an ambiguous attribution goes to review rather than being guessed.
  final bool needsAttributionReview;

  /// Marks this item as one slice of a larger thing the user reviews as a
  /// whole. The everyday-spending estimate is split one item per category per
  /// remaining day so the ledger can find a daily minimum balance; all the
  /// slices of a category share a [groupId], so the forecast can offer a single
  /// Confirm/Edit/Dismiss for the month instead of one per day.
  ///
  /// Null for anything reviewed on its own, which is everything else.
  final String? groupId;

  DateTime? get eventDate => actualDate ?? dueDate;
  String get ownerKey => '${owner.name}:$id';

  /// The identity a risk decision is stored against when this item is a slice
  /// of a group. Null when it is reviewed on its own — the caller then falls
  /// back to [ownerKey], which is the behaviour every ungrouped item keeps.
  String? get riskGroupKey => groupId == null ? null : '${owner.name}:$groupId';
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
