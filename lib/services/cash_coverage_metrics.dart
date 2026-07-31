import '../data/sms_models.dart';

/// Minimum ATM total (paise, ₹5,000) below which no cash-coverage caveat is
/// shown regardless of ratio (D6 spec default).
const int kCashMaterialityMinAtmPaise = 500000;

/// Below this cash-drain ratio no caveat is shown (D6 spec default, 10%).
const double kCashNoCaveatMaxRatio = 0.10;

/// Upper edge (inclusive) of the "caveat" band (D6 spec default, 25%).
const double kCashCaveatMaxRatio = 0.25;

/// Upper edge (inclusive) of the "cash-heavy" band; above it is low coverage
/// (D6 spec default, 40%).
const double kCashHeavyMaxRatio = 0.40;

/// Trailing window (days) over which the cash-drain ratio is computed.
const int kCashDrainWindowDays = 90;

/// Cash-coverage messaging level derived from the trailing cash-drain ratio.
///
/// These levels change only messaging/confidence wording; the underlying rupee
/// math is unaffected (spec §7 ATM/untracked cash treatment).
enum CashCoverageLevel { none, caveat, cashHeavy, lowCoverage }

/// Computes how much of tracked bank spending is opaque ATM cash, so a
/// heavy-cash user is not told a surplus is fully reliable (spec §7). ATM cash
/// is never auto-split into categories — it only feeds this coverage metric.
class CashCoverageMetrics {
  const CashCoverageMetrics();

  /// Trailing-[kCashDrainWindowDays] slice of [history] relative to [now].
  List<ParsedTxn> trailingWindow(List<ParsedTxn> history, DateTime now) {
    final cutoff = now.subtract(const Duration(days: kCashDrainWindowDays));
    return [
      for (final txn in history)
        if (txn.txnDate.isAfter(cutoff)) txn,
    ];
  }

  /// Σ ATM debit amounts in [window].
  int atmTotalPaise(List<ParsedTxn> window) => window
      .where(_isAtm)
      .fold<int>(0, (sum, txn) => sum + txn.amountPaise);

  /// Σ tracked discretionary bank-debit amounts in [window]. Excludes ATM cash
  /// (opaque) and transfers (not spend), so ATM is never diluted into or split
  /// across categories.
  int trackedDiscretionaryBankDebitPaise(List<ParsedTxn> window) => window
      .where(_isTrackedDiscretionaryBankDebit)
      .fold<int>(0, (sum, txn) => sum + txn.amountPaise);

  /// `atm / max(1, atm + tracked_discretionary_bank_debit)` over [window].
  double cashDrainRatio(List<ParsedTxn> window) {
    final atm = atmTotalPaise(window);
    if (atm == 0) return 0;
    final denominator = atm + trackedDiscretionaryBankDebitPaise(window);
    return atm / (denominator <= 0 ? 1 : denominator);
  }

  /// Messaging level for [window] using the D6 thresholds.
  CashCoverageLevel level(List<ParsedTxn> window) {
    if (atmTotalPaise(window) < kCashMaterialityMinAtmPaise) {
      return CashCoverageLevel.none;
    }
    final ratio = cashDrainRatio(window);
    if (ratio < kCashNoCaveatMaxRatio) return CashCoverageLevel.none;
    if (ratio <= kCashCaveatMaxRatio) return CashCoverageLevel.caveat;
    if (ratio <= kCashHeavyMaxRatio) return CashCoverageLevel.cashHeavy;
    return CashCoverageLevel.lowCoverage;
  }

  /// Σ ATM debits in [now]'s calendar month, up to and including [now]. Shown
  /// separately from the trailing ratio when material.
  int currentMonthToDateAtmPaise(List<ParsedTxn> history, DateTime now) => history
      .where(
        (txn) =>
            _isAtm(txn) &&
            txn.txnDate.year == now.year &&
            txn.txnDate.month == now.month &&
            !txn.txnDate.isAfter(now),
      )
      .fold<int>(0, (sum, txn) => sum + txn.amountPaise);

  /// Whether the current month's cash withdrawals clear the materiality floor.
  bool isCurrentMonthCashMaterial(List<ParsedTxn> history, DateTime now) =>
      currentMonthToDateAtmPaise(history, now) >= kCashMaterialityMinAtmPaise;

  bool _isAtm(ParsedTxn txn) =>
      txn.type == TxnType.atm && txn.direction == TransactionDirection.debit;

  bool _isTrackedDiscretionaryBankDebit(ParsedTxn txn) =>
      txn.direction == TransactionDirection.debit &&
      txn.instrument == PaymentInstrument.bank &&
      txn.type != TxnType.atm &&
      txn.type != TxnType.transfer;
}
