import '../data/forecast_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_models.dart';

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
      dedupeKey: 'sms_mandate:$merchantNorm',
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
