import '../data/obligation_models.dart';
import '../data/forecast_models.dart';
import '../data/sms_analysis_snapshot.dart' show kAnalysisLookbackMonths;
import '../data/models.dart';
import '../data/sms_models.dart';
import '../data/transaction_repository.dart';
import 'recurring_debit_detector.dart';
import 'sms_scan_orchestrator.dart';

/// The [ObligationCandidateSource] the scan orchestrator uses in production:
/// it runs the [RecurringDebitDetector] over the full transaction history and
/// converts each locked [RecurringCommitment] into a durable, `smsRecurring`
/// [ObligationRecord] (spec §3). Re-scans upsert by a stable dedupe key, so a
/// commitment is refreshed in place rather than duplicated.
class RecurringObligationCandidates implements ObligationCandidateSource {
  RecurringObligationCandidates({
    required this.transactions,
    this.configuredPlans = const [],
    this.detector = const RecurringDebitDetector(),
    this.lookbackMonths = kAnalysisLookbackMonths,
  });

  final TransactionRepository transactions;
  final List<ContribPlan> configuredPlans;
  final RecurringDebitDetector detector;
  final int lookbackMonths;

  /// `derive` runs the detector over the entire lookback window and emits one
  /// obligation per locked commitment, so the `sms_recurring:` space is fully
  /// enumerated on every scan and a stored key that did not come back is
  /// unre-derivable.
  ///
  /// Scoped to that one prefix on purpose. `sms_mandate:` keys are minted by
  /// [MandateNoticeObligations] from notices in the message stream, which this
  /// source does not read and therefore cannot vouch for; sweeping them here
  /// would retire live obligations on the first scan that saw no notice.
  /// A `configuredPlanKey` is likewise outside the prefix and never swept.
  @override
  Set<String> get sweptKeyPrefixes => const {'sms_recurring:'};

  @override
  Future<List<ObligationRecord>> derive({
    required List<ParsedTxn> persisted,
    required String scanBatchId,
    required DateTime now,
  }) async {
    // Recurrence can only be detected against full history, not the handful of
    // messages a single scan adds — so read the same lookback window the
    // snapshot uses rather than only [persisted].
    final lookbackStart = DateTime(now.year, now.month - lookbackMonths, 1);
    final history = await transactions.allSince(lookbackStart);
    final commitments = detector.detect(
      history,
      configuredPlans: configuredPlans,
      now: now,
    );
    return [for (final commitment in commitments) _toObligation(commitment, now)];
  }

  ObligationRecord _toObligation(RecurringCommitment commitment, DateTime now) {
    final recurrence = _recurrence(commitment.cadence);
    return ObligationRecord(
      sourceType: ObligationSourceType.smsRecurring,
      // A configured-plan match shares the plan's dedupe key so the two owners
      // fold together (D8); otherwise a stable per-merchant/cadence key.
      dedupeKey: commitment.configuredPlanKey ??
          'sms_recurring:${commitment.merchantNorm}:${commitment.cadence.name}',
      merchant: _label(commitment),
      merchantNorm: commitment.merchantNorm,
      categoryKey: commitment.categoryKey,
      amountPaise: commitment.amountPaise,
      amountStatus: AmountStatus.known,
      recurrence: recurrence,
      dueDate: commitment.nextExpected,
      dueDay: commitment.nextExpected.day,
      dueMonth: commitment.nextExpected.month,
      paymentAccountScope: AccountScope.primary,
      paymentStatus: ReconciliationPaymentStatus.unpaid,
      nextExpectedSource: NextExpectedSource.lockedCadence,
      payeeType: commitment.payeeType,
      // Algorithm-detected until the user confirms the cadence in review — and
      // the review status has to say so too. Stamping `confirmed` here made the
      // matcher report `isUserConfirmed`, which is the only thing that lifts a
      // 0.7-confidence guess over the 0.8 hard-commitment bar: an algorithm's
      // guess was being presented back as the user's own decision.
      userCadenceStatus: UserCadenceStatus.algorithmDetected,
      confidence: commitment.confidence,
      reviewStatus: ObligationReviewStatus.needsReview,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// The name the forecast shows. `merchantNorm` stays the grouping key; only
  /// the label changes, so attribution is untouched.
  ///
  /// A bank-mandate payee is title-cased and qualified: the user sees
  /// "Indian Clearing Corporation Lt mandate" rather than a line that reads like
  /// a shop they bought something from (TASK-31's bank-as-payee decision).
  static String _label(RecurringCommitment commitment) {
    if (commitment.payeeType != PayeeType.bankMandate) {
      return commitment.merchantNorm;
    }
    final titled = commitment.merchantNorm
        .split(' ')
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
    return '$titled mandate';
  }

  static ReconciliationRecurrence _recurrence(RecurringCadence cadence) =>
      switch (cadence) {
        RecurringCadence.monthly => ReconciliationRecurrence.monthly,
        RecurringCadence.quarterly => ReconciliationRecurrence.quarterly,
        // The reconciliation model has no half-yearly bucket; it folds into
        // annual (D8).
        RecurringCadence.halfYearly ||
        RecurringCadence.annual =>
          ReconciliationRecurrence.annual,
      };
}
