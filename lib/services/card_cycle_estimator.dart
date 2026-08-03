import '../core/clamped_date.dart';
import '../data/card_models.dart';
import '../data/forecast_models.dart';
import '../data/sms_models.dart';

/// Confidence used for a card-cycle estimate when the billing cycle is unknown
/// (a "set card billing cycle" coverage line, not a dated event).
const double kCardCycleUnknownConfidence = 0.3;

/// The card-side confirmation that the holder has **paid their bill**, as
/// opposed to a merchant refunding a purchase. Both arrive as a credit on the
/// card, so the wording is the only thing separating them:
///
///     DEAR HDFCBANK CARDMEMBER, PAYMENT OF Rs.5000 RECEIVED TOWARDS YOUR
///     CREDIT CARD ENDING WITH 1234 ...
///     Payment of Rs.2500 has been received on your ICICI Bank Credit Card
///     XX12 through Bharat Bill Payment System ...
///
/// A refund cancels spend; a payment settles it. Counting a payment as a refund
/// makes paying the bill look like the holder spent less, which understates the
/// next statement and the cash outflow forecast from it.
///
/// Deliberately narrow: only a credit that positively identifies itself as a
/// payment is excluded, so an unlabelled card credit still counts as a refund
/// exactly as before.
bool isCardBillPayment(ParsedTxn txn) =>
    _billPayment.hasMatch(txn.rawBodyRedacted);

final RegExp _billPayment = RegExp(
  r'\bpayment\b[\s\S]{0,60}?\breceived\b'
  r'|\breceived\b[\s\S]{0,60}?\btowards\s+your\b',
  caseSensitive: false,
);

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
              t.direction == TransactionDirection.credit &&
              !isCardBillPayment(t),
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
      dueDate = clampedDate(
        statementMonth.year,
        statementMonth.month,
        cycle.dueDay,
      );
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
        // Nothing paid against a known statement: the whole statement is
        // outstanding. Leaving this null made a knowable amount look unknown
        // (TASK-24 M7).
        outstanding = statementTotalPaise;
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
