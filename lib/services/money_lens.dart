import '../data/sms_models.dart';
import 'card_cycle_estimator.dart';

/// The key a merchant is remembered by, or null when the row names no merchant.
///
/// One definition, used by the finder that proposes a front and by the lens
/// that consults one, so the two cannot drift apart on what a key is. Lowercase
/// and whitespace-collapsed only — no stemming, no prefix folding, nothing
/// clever. `amazon` is a proper prefix of `amazon pay credit c` and `cred store`
/// is a sibling of `cred club`, so any cleverness here erases real spending: the
/// unsupervised version of that idea was measured and wiped out 11 innocent
/// rows.
String? merchantFrontKey(ParsedTxn txn) {
  final merchant = txn.merchant;
  if (merchant == null) return null;
  final key = merchant.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  return key.isEmpty ? null : key;
}

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
  /// Cash taken out on a card is left out of both lenses and was documented
  /// here as being left to the existing ATM path — `ReconciliationMatcher`
  /// routing it to `atmWithdrawals`, `CashCoverageMetrics` counting it.
  ///
  /// That is not what happens, and the claim is corrected rather than repeated.
  /// Both of those paths test `type == TxnType.atm`, and no card row on the
  /// owner's device carries that type: all 23 HDFC ATM cash-outs are stored as
  /// `pos`, because the body names the debit card. Measured over the whole
  /// export, `type == atm && instrument == card` matches **zero** rows. So
  /// ₹3,56,000 of withdrawn cash is in no lens, no ATM item and no cash-coverage
  /// ratio — `CashCoverageMetrics` reports ₹0 and level `none` — and is owned by
  /// nothing at all.
  ///
  /// [reportsBankBalance] stops the card estimator adding a *second* wrong
  /// answer on top by billing that cash to a card. It deliberately does not
  /// resolve the ownership gap, which needs the type mis-tagging fixed at the
  /// parser and has a far wider blast radius.
  static bool isSpend(ParsedTxn txn, Set<String> confirmedFronts) {
    if (txn.isFutureDebitNotice) return false;
    if (txn.type == TxnType.transfer || txn.type == TxnType.atm) return false;
    if (txn.payeeType == PayeeType.selfTransfer) return false;
    if (isCardSettlement(txn, confirmedFronts)) return false;
    final body = txn.rawBodyRedacted.toLowerCase();
    if (_matchesAny(body, kCashWithdrawalMarkers)) return false;
    if (_matchesAny(body, kInvestmentMarkers)) return false;
    if (_matchesAny(body, kDepositMarkers)) return false;
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
  static bool isEverydayCashSpend(ParsedTxn txn, Set<String> confirmedFronts) {
    if (txn.direction != TransactionDirection.debit) return false;
    if (txn.type == TxnType.transfer || txn.type == TxnType.atm) return false;
    if (txn.payeeType == PayeeType.selfTransfer) return false;
    if (txn.instrument == PaymentInstrument.card) return false;
    if (txn.isFutureDebitNotice) return false;
    if (isCardSettlement(txn, confirmedFronts)) return false;
    final body = txn.rawBodyRedacted.toLowerCase();
    return !_matchesAny(body, kCashWithdrawalMarkers) &&
        !_matchesAny(body, kInvestmentMarkers) &&
        !_matchesAny(body, kDepositMarkers) &&
        !_matchesAny(body, kCreditCardPurchaseMarkers);
  }

  /// Whether this debit settles a credit-card bill, on either rail.
  ///
  /// **Keyed on the body or on the user's own answer, never on the amount and
  /// never on the instrument.** `_cardMarker` fires on the bare phrase
  /// `credit card`, so *"Payment of Rs.45,000 towards your HDFC Credit Card
  /// debited from A/c XX1234"* is stored as `instrument: card`, `type: pos` —
  /// indistinguishable from a purchase by instrument alone. The same bill paid
  /// through CRED arrives as `instrument: bank`. One event, two shapes.
  ///
  /// The amount is not consulted because it cannot be: reward points mean the
  /// bank debit is routinely smaller than the bill. Over the owner's device 42
  /// of 73 pairs carry a discount, up to Rs.242 (re-measured 2026-08-09; this
  /// said "19 of 31, up to Rs.44" from a source that did not reproduce — see
  /// `CardSettlementPair.pointsPaise`). A Rs.90 debit against a Rs.100 bill
  /// takes this exact path.
  ///
  /// **[confirmedFronts] replaces a hardcoded merchant list**, which was wrong
  /// in both directions: `\bcred\b | \bbilldesk\b | \bcc payment\b |
  /// \bcard bill\b` missed Rs.5,44,676 of card payments across 21 rows — Cheq
  /// Digital alone was Rs.5,35,438, a payment app nobody had thought to add —
  /// while matching `CRED Store` and erasing Rs.599 of real shopping. There is
  /// no list of names that stays right, so the app stopped keeping one:
  /// `CardSettlementCandidateFinder` proposes a merchant and the user confirms
  /// it once.
  ///
  /// There is deliberately no default for [confirmedFronts]. An empty default
  /// would let a new call site compile while silently losing every exclusion.
  static bool isCardSettlement(ParsedTxn txn, Set<String> confirmedFronts) {
    if (txn.direction != TransactionDirection.debit) return false;
    if (_paymentTowardsCard.hasMatch(txn.rawBodyRedacted)) return true;
    final key = merchantFrontKey(txn);
    return key != null && confirmedFronts.contains(key);
  }

  /// Whether this alert reports a running **bank balance**, which means the
  /// money has already left the account and no card will bill for it.
  ///
  /// This is the other half of the distinction [kCreditCardPurchaseMarkers]
  /// already names: a credit-card alert reports the available *limit*, a bank
  /// debit-card alert reports the available *balance*. Both arrive as
  /// `instrument: card` whenever the body says "Bank Card", so the wording is
  /// the only thing separating a purchase a statement will bill for from one
  /// the bank has already settled.
  ///
  /// Keyed on the balance and **not** on the cash-withdrawal wording, which
  /// would have been the obvious alternative. A credit-card *cash advance* is a
  /// withdrawal that does appear on the statement, so excluding on "withdrawn"
  /// would drop a real bill; a cash advance reports the limit, never a balance,
  /// so this signal cannot make that mistake. On the owner's device the choice
  /// is not a trade-off — all 23 ATM rows report a balance too — but the two
  /// rules are not equally safe on a body neither of us has seen yet.
  ///
  /// Word-anchored: a substring test for `bal` also matches `GLOBAL`, and
  /// `Bil. Avl Lmt` is a real credit-card body fragment.
  static bool reportsBankBalance(ParsedTxn txn) =>
      _bankBalance.hasMatch(txn.rawBodyRedacted);

  static final RegExp _bankBalance = RegExp(
    r'\bbal\b|\bavailable balance\b',
    caseSensitive: false,
  );

  /// A payment made *towards* a card — the debit-side counterpart of
  /// [isCardBillPayment]'s "payment received towards your card". Bounded gaps
  /// keep the three words in one clause: an unrelated body that happens to
  /// carry all three far apart does not match.
  static final RegExp _paymentTowardsCard = RegExp(
    r'\b(?:payment|paid)\b[\s\S]{0,60}?\btowards\b[\s\S]{0,40}?\bcard\b',
    caseSensitive: false,
  );

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

/// Bank deposit auto-debits — a recurring deposit is money moved into savings,
/// not consumption.
///
/// The trailing slash is load-bearing. [MoneyLens._matchesAny] is a plain
/// substring test, so the bare letters `rd` match the word *card* and would
/// silence every card purchase in the corpus. The bank always writes the rail
/// as `RD/<ref>/<payee>`, and `rd/` also covers the older `MOB-RD/` form.
///
/// Term deposits (`MOB-TD/`) are deliberately absent: `td/` is not safe as a
/// substring — it fires on `Grofers India Pvt Ltd/Gurgaon`.
const kDepositMarkers = ['rd/'];

/// Credit-card purchase alerts, identified by the reported available *limit*
/// (a bank debit-card purchase reports the available *balance* instead).
const kCreditCardPurchaseMarkers = [
  'avl lmt',
  'available limit',
  'available credit',
  'credit limit',
];
