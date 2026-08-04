import 'package:uuid/uuid.dart';

import '../data/obligation_models.dart';
import '../data/obligation_repository.dart';
import '../data/sms_models.dart';
import '../data/transaction_repository.dart';
import 'mandate_notice_obligations.dart';
import 'sms_ingestion_policy.dart';
import 'sms_transaction_parser.dart';

/// Aggregated outcome of a single scan run.
///
/// Non-success scans return [ScanRunResult.noOp] with an empty [scanBatchId]
/// and all counts zero — a scan that could not read is never reported as
/// "zero SMS found" (spec §5).
class ScanRunResult {
  const ScanRunResult({
    required this.status,
    required this.scanBatchId,
    required this.parsed,
    required this.autoAdded,
    required this.queuedReview,
    required this.skippedDuplicate,
    required this.collisionSets,
    required this.obligationCandidates,
    this.refreshedParse = 0,
    this.skippedMessages = 0,
    this.retiredObligations = 0,
  });

  factory ScanRunResult.noOp(SmsScanStatus status) => ScanRunResult(
    status: status,
    scanBatchId: '',
    parsed: 0,
    autoAdded: 0,
    queuedReview: 0,
    skippedDuplicate: 0,
    collisionSets: 0,
    obligationCandidates: 0,
    refreshedParse: 0,
  );

  final SmsScanStatus status;
  final String scanBatchId;
  final int parsed;
  final int autoAdded;
  final int queuedReview;
  final int skippedDuplicate;
  final int collisionSets;
  final int obligationCandidates;

  /// Already-stored rows whose derived fields were rewritten because the parser
  /// now reads their message differently. Distinct from [skippedDuplicate],
  /// which is the same message re-seen with nothing to correct.
  final int refreshedParse;

  /// Inbox messages the reader counted but never read, carried through from
  /// [SmsScanOutcome.skippedCount]. Non-zero means this run saw less than the
  /// user's history contains, and the UI must say so rather than present the
  /// result as a full picture (TASK-33).
  final int skippedMessages;

  /// Obligations stamped `retired_at` by this run because nothing can derive
  /// their dedupe key any more. Nothing was deleted; the rows keep their review
  /// status and reappear if a later scan derives the key again (TASK-37).
  final int retiredObligations;

  bool get isSuccess => status == SmsScanStatus.success;

  /// Whether this run actually covered the whole inbox. A scan that could not
  /// read at all is not complete either, so a no-op never claims coverage.
  bool get isComplete => isSuccess && skippedMessages == 0;
}

/// Seam for deriving recurring obligation candidates from a scan's persisted
/// transactions. The real recurring-debit detector arrives in Phase D; the
/// default [NoObligationCandidates] yields none so the pipeline is complete and
/// testable now.
abstract class ObligationCandidateSource {
  Future<List<ObligationRecord>> derive({
    required List<ParsedTxn> persisted,
    required String scanBatchId,
    required DateTime now,
  });

  /// Dedupe-key prefixes this source enumerates *exhaustively* on every
  /// [derive], and therefore authorises the orchestrator to retire within.
  ///
  /// Declaring a prefix is a promise: any stored key under it that [derive] did
  /// not return cannot be derived again, so it will be stamped `retired_at`.
  /// Return an empty set — the safe answer — unless that promise holds.
  ///
  /// Deliberately abstract rather than defaulted. A retirement sweep is
  /// destructive enough that every source should have to state its answer, and
  /// `implements` makes the compiler ask.
  Set<String> get sweptKeyPrefixes;
}

/// Default [ObligationCandidateSource] that produces no candidates.
class NoObligationCandidates implements ObligationCandidateSource {
  const NoObligationCandidates();

  @override
  Future<List<ObligationRecord>> derive({
    required List<ParsedTxn> persisted,
    required String scanBatchId,
    required DateTime now,
  }) async => const <ObligationRecord>[];

  /// Enumerates nothing, so it may retire nothing. Without this a scan wired
  /// to the default source would retire every obligation in the database.
  @override
  Set<String> get sweptKeyPrefixes => const <String>{};
}

/// Trigger-agnostic `parse → policy → persist → obligation-candidate` pipeline
/// shared by the on-demand scan and any future background trigger.
///
/// Only [SmsScanStatus.success] outcomes are parsed; every other status returns
/// a typed [ScanRunResult.noOp]. Deduplication, collision routing, first-scan
/// review-all, and the auto-add threshold are all delegated to
/// [TransactionRepository.ingestParsedTxn] / [SmsIngestionPolicy].
class SmsScanOrchestrator {
  SmsScanOrchestrator({
    this.parser = const SmsTransactionParser(),
    this.candidateSource = const NoObligationCandidates(),
    this.noticeObligations = const MandateNoticeObligations(),
    String Function()? newScanBatchId,
  }) : _newScanBatchId = newScanBatchId ?? _defaultBatchId;

  final SmsTransactionParser parser;
  final ObligationCandidateSource candidateSource;
  final MandateNoticeObligations noticeObligations;
  final String Function() _newScanBatchId;

  static const _uuid = Uuid();

  static String _defaultBatchId() => 'scan:${_uuid.v4()}';

  Future<ScanRunResult> run({
    required SmsScanOutcome outcome,
    required TransactionRepository txRepo,
    required ObligationRepository obliRepo,
    required bool isFirstScan,
    required String bodyHashSalt,
    DateTime? now,
  }) async {
    if (!outcome.isSuccess) {
      return ScanRunResult.noOp(outcome.status);
    }

    final timestamp = now ?? DateTime.now();
    final scanBatchId = _newScanBatchId();

    var parsed = 0;
    var autoAdded = 0;
    var queuedReview = 0;
    var skippedDuplicate = 0;
    var refreshedParse = 0;
    final collisionSetIds = <String>{};
    final persisted = <ParsedTxn>[];
    final notices = <FutureDebitNotice>[];

    for (final sms in outcome.messages) {
      final result = parser.parse(
        sms,
        scanBatchId: scanBatchId,
        bodyHashSalt: bodyHashSalt,
      );

      // A future-dated notice is not an actual — it announces money that has
      // not moved. It becomes an obligation below rather than a debit row, so
      // it cannot double-count against the real debit that follows (TASK-32).
      final notice = result.notice;
      if (notice != null) {
        notices.add(notice);
        continue;
      }

      final parsedTxn = result.txn;
      if (parsedTxn == null) continue;
      parsed++;

      final decision = await txRepo.ingestParsedTxn(
        parsedTxn,
        isFirstScan: isFirstScan,
        now: timestamp,
      );

      switch (decision.action) {
        case IngestionAction.upsert:
          autoAdded++;
          persisted.add(decision.transaction);
        case IngestionAction.queueReview:
          queuedReview++;
          persisted.add(decision.transaction);
          final collisionSetId = decision.transaction.collisionSetId;
          if (collisionSetId != null &&
              decision.transaction.reviewReason == ReviewReason.dedupCollision) {
            collisionSetIds.add(collisionSetId);
          }
        case IngestionAction.refreshParse:
          // The message was already stored but the parser now reads it
          // differently. The row is rewritten with the corrected fields and
          // the user's review decision intact, and it joins `persisted` so the
          // corrected merchant reaches recurring detection — which is the whole
          // point of re-parsing.
          refreshedParse++;
          persisted.add(decision.transaction);
        case IngestionAction.skipDuplicate:
          skippedDuplicate++;
      }
    }

    final candidates = await candidateSource.derive(
      persisted: persisted,
      scanBatchId: scanBatchId,
      now: timestamp,
    );
    for (final candidate in candidates) {
      if (candidate.sourceType != ObligationSourceType.smsRecurring) {
        throw ArgumentError.value(
          candidate.sourceType,
          'candidate.sourceType',
          'SMS scan candidates must be ObligationSourceType.smsRecurring',
        );
      }
      await obliRepo.upsert(candidate, now: timestamp);
    }

    // Retire the keys this source can no longer derive. A dedupe key embeds the
    // merchant, so a parser fix makes the next scan derive a different key and
    // strands the old row — it projected into the forecast forever, beside the
    // row that replaced it. Runs after the upserts so a key that is both
    // re-derived and stored is written before it is considered (TASK-37).
    final retiredObligations = await obliRepo.retireUnderivable(
      keyPrefixes: candidateSource.sweptKeyPrefixes,
      derivedKeys: {for (final c in candidates) c.dedupeKey},
      now: timestamp,
    );

    // One owner per rupee: when history has already locked a commitment for
    // this payee, that commitment owns the future debit and the notice must not
    // raise a second obligation beside it. The rupee is still attributed — just
    // to the stronger of the two signals, the one backed by real occurrences.
    final ownedByCommitment = {for (final c in candidates) c.merchantNorm};
    for (final notice in notices) {
      final obligation = noticeObligations.toObligation(notice, now: timestamp);
      if (ownedByCommitment.contains(obligation.merchantNorm)) continue;
      await obliRepo.upsert(obligation, now: timestamp);
    }

    // The same rule, applied to rows already stored. The loop above only
    // declines to write a *new* notice obligation for an owned payee; one
    // written before the commitment locked stayed in the forecast beside it
    // forever (TASK-32's recorded finding). Runs after the notice loop so a
    // notice re-written this scan is retired only if a commitment owns it.
    final retiredMandates = await obliRepo.retireOwnedMandates(
      ownedMerchantNorms: ownedByCommitment,
      now: timestamp,
    );

    return ScanRunResult(
      status: SmsScanStatus.success,
      scanBatchId: scanBatchId,
      parsed: parsed,
      autoAdded: autoAdded,
      queuedReview: queuedReview,
      skippedDuplicate: skippedDuplicate,
      collisionSets: collisionSetIds.length,
      obligationCandidates: candidates.length,
      retiredObligations: retiredObligations + retiredMandates,
      refreshedParse: refreshedParse,
      skippedMessages: outcome.skippedCount,
    );
  }
}
