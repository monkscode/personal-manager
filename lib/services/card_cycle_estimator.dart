import '../data/card_models.dart';
import '../data/forecast_models.dart';
import '../data/sms_models.dart';

/// Confidence used for a card-cycle estimate when the billing cycle is unknown
/// (a "set card billing cycle" coverage line, not a dated event).
const double kCardCycleUnknownConfidence = 0.3;

/// Estimates a card's current cycle spend, statement residual, and the single
/// expected bank cash outflow (spec §7). The bank ledger counts card usage
/// exactly once — via the statement/payment event — never per purchase.
class CardCycleEstimator {
  const CardCycleEstimator();

  CardCycleEstimate estimate(
    List<ParsedTxn> cardTxns, {
    CardCycle? cycle,
    DateTime? statementMonth,
    int? statementTotalPaise,
    int? amountPaidPaise,
  }) {
    final observedPurchases = cardTxns
        .where(
          (t) =>
              t.instrument == PaymentInstrument.card &&
              t.direction == TransactionDirection.debit &&
              t.type != TxnType.atm,
        )
        .fold<int>(0, (sum, t) => sum + t.amountPaise);
    final cardRefunds = cardTxns
        .where(
          (t) =>
              t.instrument == PaymentInstrument.card &&
              t.direction == TransactionDirection.credit,
        )
        .fold<int>(0, (sum, t) => sum + t.amountPaise);

    final cycleSpendSeen = observedPurchases - cardRefunds;

    final cardLast4 = cycle?.cardLast4 ??
        cardTxns
            .map((t) => t.accountLast4)
            .firstWhere((last4) => last4 != null, orElse: () => null) ??
        'unknown';

    final needsCycleSetup = cycle == null;
    final monthTag = statementMonth == null
        ? 'unknown'
        : '${statementMonth.year.toString().padLeft(4, '0')}-'
            '${statementMonth.month.toString().padLeft(2, '0')}';
    final cardCycleKey = 'card:$cardLast4:$monthTag';

    final DateTime? dueDate;
    if (cycle != null && statementMonth != null) {
      dueDate = DateTime(statementMonth.year, statementMonth.month, cycle.dueDay);
    } else {
      dueDate = null;
    }

    int? statementResidual;
    if (statementTotalPaise != null) {
      statementResidual =
          statementTotalPaise - observedPurchases + cardRefunds;
    }

    ReconciliationPaymentStatus paymentStatus;
    int? outstanding;
    int statementEventAmount;
    if (statementTotalPaise != null) {
      if (amountPaidPaise != null && amountPaidPaise >= statementTotalPaise) {
        paymentStatus = ReconciliationPaymentStatus.paid;
        outstanding = 0;
        statementEventAmount = statementTotalPaise;
      } else if (amountPaidPaise != null && amountPaidPaise > 0) {
        paymentStatus = ReconciliationPaymentStatus.partial;
        outstanding = statementTotalPaise - amountPaidPaise;
        statementEventAmount = outstanding;
      } else {
        paymentStatus = ReconciliationPaymentStatus.unpaid;
        statementEventAmount = statementTotalPaise;
      }
    } else {
      // No statement yet: the observed-spend proxy is the plan-for amount.
      paymentStatus = ReconciliationPaymentStatus.unpaid;
      statementEventAmount = cycleSpendSeen < 0 ? 0 : cycleSpendSeen;
    }

    return CardCycleEstimate(
      cardLast4: cardLast4,
      cardCycleKey: cardCycleKey,
      observedPurchasesPaise: observedPurchases,
      cardRefundsPaise: cardRefunds,
      cycleSpendSeenPaise: cycleSpendSeen,
      statementEventAmountPaise: statementEventAmount,
      statementTotalPaise: statementTotalPaise,
      statementResidualPaise: statementResidual,
      outstandingPaise: outstanding,
      paymentStatus: paymentStatus,
      dueDate: dueDate,
      needsCycleSetup: needsCycleSetup,
      confidence: cycle?.confidence ?? kCardCycleUnknownConfidence,
    );
  }
}
