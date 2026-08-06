import 'forecast_models.dart';

/// A credit card's billing cycle (spec §7 "Credit-card cycle treatment").
///
/// Sourced from Gmail/card statements, SMS bill reminders, repeated payment
/// dates, or user entry. Until known, the app shows a quantified "set card
/// billing cycle" coverage line instead of guessing due dates.
class CardCycle {
  const CardCycle({
    required this.cardLast4,
    required this.statementDay,
    required this.dueDay,
    this.issuer,
    this.cycleStartDay,
    this.paymentAccountHint,
    this.confidence = 0.5,
  }) : assert(confidence >= 0 && confidence <= 1);

  final String cardLast4;
  final String? issuer;
  final int? cycleStartDay;
  final int statementDay;
  final int dueDay;
  final String? paymentAccountHint;
  final double confidence;
}

/// The estimated state of one card cycle: how much spend has been seen, the
/// residual against a known statement, the single expected bank cash outflow,
/// and its payment status. Card-routed refunds reduce card figures only; they
/// are never a phantom bank inflow (spec §7).
class CardCycleEstimate {
  const CardCycleEstimate({
    required this.cardLast4,
    required this.cardCycleKey,
    required this.observedPurchasesPaise,
    required this.cardRefundsPaise,
    required this.cycleSpendSeenPaise,
    required this.statementEventAmountPaise,
    required this.paymentStatus,
    required this.needsCycleSetup,
    required this.confidence,
    this.statementTotalPaise,
    this.statementResidualPaise,
    this.outstandingPaise,
    this.dueDate,
    this.windowStart,
  });

  final String cardLast4;
  final String cardCycleKey;

  /// The card-side payment credit this estimate counts forward from, or null
  /// when the history holds none. Null means the figures below are everything
  /// ever seen on the card rather than one bill's worth, which is a difference
  /// the user has to be told about.
  final DateTime? windowStart;

  /// Σ card purchase debits observed in the cycle.
  final int observedPurchasesPaise;

  /// Σ card-routed refund credits observed in the cycle.
  final int cardRefundsPaise;

  /// `Σ purchases − Σ card refunds` — the cycle spend seen so far.
  final int cycleSpendSeenPaise;

  /// The single bank cash outflow to plan for: the outstanding when partial,
  /// otherwise the statement total, otherwise the observed-spend proxy.
  final int statementEventAmountPaise;

  /// The known statement total when a statement/bill has arrived.
  final int? statementTotalPaise;

  /// `statement_total − Σ observed_purchases + Σ observed_card_refunds` — the
  /// uncategorized residual, never statement + purchases.
  final int? statementResidualPaise;

  /// Remaining balance after a partial payment.
  final int? outstandingPaise;

  final ReconciliationPaymentStatus paymentStatus;

  /// Expected bank payment date, or null until the cycle is known.
  final DateTime? dueDate;

  /// True when the cycle is unknown and a "set card billing cycle" coverage
  /// line must be shown instead of a dated event.
  final bool needsCycleSetup;

  final double confidence;

  /// Card statements are always bank cash outflows.
  LedgerDirection get direction => LedgerDirection.outflow;
}
