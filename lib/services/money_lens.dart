import '../data/sms_models.dart';
import 'card_cycle_estimator.dart';

/// The two questions the app asks about a stored debit, kept apart because the
/// answers differ.
///
/// One predicate used to answer both. `_isConsumptionSpend` was named for spend
/// and tested for cash: it excluded every card purchase, because a card
/// purchase is not a bank outflow, and it admitted the later card bill payment,
/// because that one is. So a ₹500 card purchase on 6 August appeared in the
/// Transactions list and in no total, while a ₹45,000 bill payment counted in
/// full as spend in a month the user may have consumed almost nothing.
///
///   * [isSpend] — *did the user consume this, on this date*. What the
///     "spent this month" figure and the trend chart answer.
///   * [isEverydayCashSpend] — the planning baseline that feeds the required
///     figure. Deliberately still a cash lens: it is [isSpend]'s predecessor
///     with one exclusion added, not a re-derivation.
///
/// [isCardSettlement] is what both consult to leave a bill payment out.
///
/// Both are re-derived from the redacted SMS body at read time, so a correction
/// here reaches rows already on disk without a rescan or a migration.
class MoneyLens {
  const MoneyLens._();

  /// Whether the user consumed this amount on [ParsedTxn.txnDate].
  ///
  /// A card purchase counts here on the day it was made, which is the whole
  /// point of the split. A card refund counts *negatively* on the day it
  /// arrives — see [signedSpendPaise], which is how a caller reads the amount.
  ///
  /// Card cash advances are knowingly left out of both lenses and left to the
  /// existing ATM path: `ReconciliationMatcher` still routes them to
  /// `atmWithdrawals` and `CashCoverageMetrics` still counts them. The
  /// disagreement is recorded rather than resolved here.
  static bool isSpend(ParsedTxn txn) {
    if (txn.isFutureDebitNotice) return false;
    if (txn.type == TxnType.transfer || txn.type == TxnType.atm) return false;
    if (txn.payeeType == PayeeType.selfTransfer) return false;
    if (isCardSettlement(txn)) return false;
    final body = txn.rawBodyRedacted.toLowerCase();
    if (_matchesAny(body, kCashWithdrawalMarkers)) return false;
    if (_matchesAny(body, kInvestmentMarkers)) return false;
    if (txn.direction == TransactionDirection.credit) {
      // Only a card credit nets against spend, and only when it is a merchant
      // refund. The card-side "payment received towards your credit card" is
      // the other half of a settlement, and reading it as a refund would make
      // paying the bill look like the holder spent ₹45,000 less.
      return txn.instrument == PaymentInstrument.card &&
          !isCardBillPayment(txn);
    }
    return true;
  }

  /// The signed contribution [txn] makes to a spend total, for a row [isSpend]
  /// admits. A refund is negative on the date it arrives, so a category can go
  /// negative and is shown negative — flooring at zero would drop the
  /// difference silently.
  static int signedSpendPaise(ParsedTxn txn) =>
      txn.direction == TransactionDirection.credit
      ? -txn.amountPaise
      : txn.amountPaise;

  /// Whether this is genuine consumption that left the user's **bank** this
  /// period — the planning baseline behind the required figure.
  ///
  /// Excludes cash withdrawals (cash on hand, not yet spent), investment and
  /// SIP auto-debits (savings, not consumption), card purchases (not a bank
  /// outflow), future notices, transfers and self-transfers. The
  /// available-limit body check is a read-time safety net for rows the
  /// instrument classifier got wrong: some banks mis-tag an ATM cash-out as a
  /// POS purchase because the body names the debit card, so the raw body is the
  /// reliable signal.
  ///
  /// The one thing this adds to what it replaces is [isCardSettlement]: a bank
  /// debit paying off a card bill is a real cash outflow, but it is not
  /// consumption in the month it is paid, and counting it inflated the baseline
  /// by an entire statement.
  static bool isEverydayCashSpend(ParsedTxn txn) {
    if (txn.direction != TransactionDirection.debit) return false;
    if (txn.type == TxnType.transfer || txn.type == TxnType.atm) return false;
    if (txn.payeeType == PayeeType.selfTransfer) return false;
    if (txn.instrument == PaymentInstrument.card) return false;
    if (txn.isFutureDebitNotice) return false;
    if (isCardSettlement(txn)) return false;
    final body = txn.rawBodyRedacted.toLowerCase();
    return !_matchesAny(body, kCashWithdrawalMarkers) &&
        !_matchesAny(body, kInvestmentMarkers) &&
        !_matchesAny(body, kCreditCardPurchaseMarkers);
  }

  /// Whether this debit settles a credit-card bill, on either rail.
  ///
  /// **Keyed on the body, never on the instrument.** `_cardMarker` fires on the
  /// bare phrase `credit card`, so *"Payment of Rs.45,000 towards your HDFC
  /// Credit Card debited from A/c XX1234"* is stored as `instrument: card`,
  /// `direction: debit`, `type: pos` — indistinguishable from a purchase by
  /// instrument alone. A CRED or BillDesk payment for the same bill arrives as
  /// `instrument: bank`. One event, two shapes, so the wording decides.
  ///
  /// The merchant heuristic matches **whole words**. `_norm` is lowercase plus
  /// whitespace collapse, so a substring test for `cred` also matched
  /// `SACRED HEART SCHOOL`, `INCREDIBLE INDIA` and `CREDAI`. That used to
  /// misroute a reconciliation item; here it would silently remove real money
  /// from the user's spend total.
  static bool isCardSettlement(ParsedTxn txn) {
    if (txn.direction != TransactionDirection.debit) return false;
    if (_paymentTowardsCard.hasMatch(txn.rawBodyRedacted)) return true;
    final merchant = txn.merchant;
    if (merchant == null) return false;
    return _settlementMerchant.hasMatch(_norm(merchant));
  }

  /// A payment made *towards* a card — the debit-side counterpart of
  /// [isCardBillPayment]'s "payment received towards your card". Bounded gaps
  /// keep the three words in one clause: an unrelated body that happens to
  /// carry all three far apart does not match.
  static final RegExp _paymentTowardsCard = RegExp(
    r'\b(?:payment|paid)\b[\s\S]{0,60}?\btowards\b[\s\S]{0,40}?\bcard\b',
    caseSensitive: false,
  );

  /// Card-bill fronts and the phrases banks use when the payee is the bill
  /// itself. Word-anchored on both sides; see [isCardSettlement].
  static final RegExp _settlementMerchant = RegExp(
    r'\bcred\b|\bbilldesk\b|\bcc payment\b|\bcard bill\b',
    caseSensitive: false,
  );

  static String _norm(String value) =>
      value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  static bool _matchesAny(String body, List<String> markers) =>
      markers.any(body.contains);
}

/// ATM / cash-out signals. Some banks mis-tag these as POS because the body
/// mentions the debit card, so the raw body — not the parsed type — is reliable.
const kCashWithdrawalMarkers = ['withdrawn', 'cash withdrawal', 'atm wdl'];

/// Recurring investment / SIP auto-debit originators (Indian broking houses and
/// mutual-fund clearing corporations). These are savings, not spend.
const kInvestmentMarkers = [
  'groww',
  'indian clearing corp',
  'iccl',
  'zerodha',
  'mutual fund',
  'invest tech',
  'nse clearing',
  'bse star',
  'kfintech',
];

/// Credit-card purchase alerts, identified by the reported available *limit*
/// (a bank debit-card purchase reports the available *balance* instead).
const kCreditCardPurchaseMarkers = [
  'avl lmt',
  'available limit',
  'available credit',
  'credit limit',
];
