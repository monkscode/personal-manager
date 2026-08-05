import '../data/forecast_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_models.dart';
import 'recurring_debit_detector.dart';

/// Key prefix for an obligation minted from a bank pre-notification.
const String kMandateKeyPrefix = 'sms_mandate:';

/// Confidence carried by an obligation built from a single bank
/// pre-notification.
///
/// The bank states the payee, the amount and the date outright, so it is a
/// stronger claim than a cadence inferred from history. It stays below the 0.8
/// hard-commitment bar because it is still the algorithm's reading of one
/// message, not the user's decision (TASK-18).
const double kMandateNoticeConfidence = 0.75;

/// Owner label for a notice that announces a debit but names no payee. The
/// rupee still gets a line rather than vanishing (spec: no silent exclusion).
const String kUnnamedMandateMerchant = 'unnamed mandate';

/// Converts a [FutureDebitNotice] into the durable obligation it describes.
///
/// A pre-notification is the cleanest recurring-commitment signal an inbox
/// carries: payee, amount and an explicit date, stated by the bank before the
/// money moves. Before TASK-32 these were stored as completed debits and
/// double-counted against the real debit that followed.
class MandateNoticeObligations {
  const MandateNoticeObligations();

  ObligationRecord toObligation(
    FutureDebitNotice notice, {
    required DateTime now,
  }) {
    final merchantNorm = notice.payee ?? kUnnamedMandateMerchant;
    return ObligationRecord(
      sourceType: ObligationSourceType.smsRecurring,
      sourceId: 'sms:${notice.smsId}',
      // Keyed on the payee alone. The amount is deliberately absent: a postpaid
      // bill mandate announces a different amount every month (₹118, ₹167,
      // ₹181 measured on device), and keying on it would leave a fresh
      // orphaned obligation behind every month instead of refreshing one row.
      dedupeKey: '$kMandateKeyPrefix$merchantNorm',
      merchant: merchantNorm,
      merchantNorm: merchantNorm,
      categoryKey: notice.categoryKey,
      amountPaise: notice.amountPaise,
      amountStatus: AmountStatus.known,
      // One notice announces one dated debit. It proves a date, not a cadence —
      // next month's notice refreshes this same row with the next date, which
      // is what `explicitDueDate` means.
      recurrence: ReconciliationRecurrence.onetime,
      dueDate: notice.dueDate,
      dueDay: notice.dueDate.day,
      dueMonth: notice.dueDate.month,
      paymentAccountHintLast4: notice.accountLast4,
      paymentAccountScope: AccountScope.primary,
      paymentStatus: ReconciliationPaymentStatus.unpaid,
      nextExpectedSource: NextExpectedSource.explicitDueDate,
      payeeType: PayeeType.merchant,
      userCadenceStatus: UserCadenceStatus.algorithmDetected,
      confidence: kMandateNoticeConfidence,
      reviewStatus: ObligationReviewStatus.needsReview,
      createdAt: now,
      updatedAt: now,
    );
  }
}

/// Whether a commitment a scan has locked already owns the debit that a
/// mandate obligation announces.
///
/// One owner per rupee. A mandate obligation is a single bank
/// pre-notification: it proves a date, not a cadence. Once history locks a
/// commitment for the same debit, that commitment is the stronger of the two
/// signals — it is backed by real occurrences — and the notice standing beside
/// it is a second owner for one rupee.
///
/// **The join is deliberately not merchant text.** Axis announces the device's
/// ₹120.07 autopay as `phonepe` ("towards PhonePe for Autopay") and records the
/// debit that same mandate produces as `bharat connect postpaid bill payment`
/// ("debited towards AutoPay Bharat Connect PostPaid Bill Payment"). One
/// commitment, two spellings with no token in common — no amount of string
/// similarity joins them. The reverse trap is sharper still: `google` and
/// `google asia pacific pte.ltd` are nearly the same string and are two
/// *different* subscriptions, on two different banks, falling on the 28th and
/// the 11th. Text similarity gets the real duplicate wrong and would merge the
/// two real commitments, so what the notice *announces* decides instead.
class MandateOwnership {
  const MandateOwnership(this._commitments);

  final List<ObligationRecord> _commitments;

  bool owns(ObligationRecord mandate) => _commitments.any(
    (commitment) =>
        _samePayee(commitment, mandate) ||
        _announcesSameDebit(commitment, mandate),
  );

  /// The original join, kept: when both sides spell the payee the same way
  /// there is nothing to infer.
  static bool _samePayee(ObligationRecord commitment, ObligationRecord mandate) =>
      commitment.merchantNorm.isNotEmpty &&
      commitment.merchantNorm == mandate.merchantNorm;

  /// The notice names the same day of the month and the same amount as the
  /// commitment's own next debit.
  ///
  /// Both halves are load-bearing, and the device supplies a counter-example
  /// for dropping either. Day alone would merge `axis bank cc` (₹1,275) with
  /// `hdfc bank ltd` (₹61,415) — both due on the 5th. Amount alone would merge
  /// the two ₹1,999 Google subscriptions. A notice that names no day is never
  /// joined at all, or `unnamed mandate` would be retired by whichever
  /// commitment happened to cost the same.
  ///
  /// **Named limitation.** A postpaid-bill mandate announces a different amount
  /// every month, so a notice can drift outside the jitter window and survive
  /// as a separate obligation. That failure is visible and reviewable in the
  /// forecast; the opposite one — retiring a commitment the user really owes —
  /// would be silent, so the window stays tight on purpose.
  static bool _announcesSameDebit(
    ObligationRecord commitment,
    ObligationRecord mandate,
  ) {
    final day = mandate.dueDay;
    final expectedDay = commitment.dueDay;
    if (day == null || expectedDay == null || day != expectedDay) return false;
    final amount = mandate.amountPaise;
    final expected = commitment.amountPaise;
    if (amount == null || expected == null) return false;
    final ratio = (expected * kRecurringAmountJitterRatio).round();
    final tolerance = ratio > kRecurringAmountJitterFloorPaise
        ? ratio
        : kRecurringAmountJitterFloorPaise;
    return (amount - expected).abs() <= tolerance;
  }
}
