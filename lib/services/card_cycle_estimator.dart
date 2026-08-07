import '../core/clamped_date.dart';
import '../data/card_models.dart';
import '../data/forecast_models.dart';
import '../data/sms_models.dart';
import 'money_lens.dart';

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
///     HDFC Bank Cardmember, Online Payment of Rs.1358 vide REF was credited
///     to your card ending 1234 On 31/JAN/26 ...
///
/// The third wording says "credited" and never "received", so it read as a
/// refund: 8 rows in the device corpus, ₹40,797 lifetime, ₹2,554 of it inside
/// the 13-month window and netted off spend.
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
  r'|\breceived\b[\s\S]{0,60}?\btowards\s+your\b'
  // Anchored on "payment" for the same reason as the first branch: cashback
  // and an excess-amount reversal are also "credited to your ... card", and
  // both are genuine refunds that must keep netting against spend.
  r'|\bpayment\b[\s\S]{0,60}?\bcredited\s+to\s+your\b[\s\S]{0,20}?\bcard\b',
  caseSensitive: false,
);

/// The date of the most recent card-side payment credit in [cardTxns], or null
/// when the holder has never been seen paying this card.
///
/// Deliberately the *card* side. The bank-side debit that pays a bill may
/// arrive through CRED or BillDesk carrying no card number at all, so it cannot
/// be attributed to a card; the card's own acknowledgement always can.
///
/// Lives here, beside [isCardBillPayment], but is applied by the caller that
/// builds the per-card set — see `SmsAnalysisSnapshot._cardEstimates`. Which
/// transactions belong in a cycle is a question about set membership, and the
/// estimator answers a different one: given a set, what do the figures come to.
DateTime? lastCardBillPaymentDate(List<ParsedTxn> cardTxns) {
  DateTime? latest;
  for (final txn in cardTxns) {
    if (txn.instrument != PaymentInstrument.card) continue;
    if (txn.direction != TransactionDirection.credit) continue;
    if (!isCardBillPayment(txn)) continue;
    if (latest == null || txn.txnDate.isAfter(latest)) latest = txn.txnDate;
  }
  return latest;
}

/// Estimates a card's current cycle spend, statement residual, and the single
/// expected bank cash outflow (spec §7). The bank ledger counts card usage
/// exactly once — via the statement/payment event — never per purchase.
class CardCycleEstimator {
  const CardCycleEstimator();

  /// [windowStart] is recorded, never applied. [cardTxns] is already the set
  /// the caller decided belongs to this cycle; passing the date here is what
  /// lets a reader of the estimate say *which* window the figures cover, and
  /// null says the figures are everything ever seen on the card.
  CardCycleEstimate estimate(
    List<ParsedTxn> cardTxns, {
    CardCycle? cycle,
    DateTime? statementMonth,
    int? statementTotalPaise,
    int? amountPaidPaise,
    DateTime? windowStart,
    String? cardLast4Fallback,
  }) {
    final observedPurchases = cardTxns
        .where(
          (t) =>
              t.instrument == PaymentInstrument.card &&
              t.direction == TransactionDirection.debit &&
              t.type != TxnType.atm &&
              // A bank writing its settlement debit as "payment towards your
              // HDFC Credit Card" is stored as a card debit with `type: pos` —
              // indistinguishable from a purchase by instrument alone. Counting
              // it here added the bill to the spend the bill is for.
              !MoneyLens.isCardSettlement(t) &&
              // A debit that already left a bank account cannot be on any
              // statement. The `type != atm` test above cannot reach these:
              // *every* card row on the owner's device is typed `pos`,
              // including HDFC's ATM cash-outs, because the body names the
              // debit card. So the guard sits in the right place and consults
              // a field that never disagrees with itself — reading the body is
              // what `MoneyLens` already does, for this exact reason.
              !MoneyLens.reportsBankBalance(t),
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
        cardLast4Fallback ??
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
      windowStart: windowStart,
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
