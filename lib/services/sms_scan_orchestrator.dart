import 'package:uuid/uuid.dart';

import '../data/obligation_models.dart';
import '../data/obligation_repository.dart';
import '../data/sms_models.dart';
import '../data/transaction_repository.dart';
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
  );

  final SmsScanStatus status;
  final String scanBatchId;
  final int parsed;
  final int autoAdded;
  final int queuedReview;
  final int skippedDuplicate;
  final int collisionSets;
  final int obligationCandidates;

  bool get isSuccess => status == SmsScanStatus.success;
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
    String Function()? newScanBatchId,
  }) : _newScanBatchId = newScanBatchId ?? _defaultBatchId;

  final SmsTransactionParser parser;
  final ObligationCandidateSource candidateSource;
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
    final collisionSetIds = <String>{};
    final persisted = <ParsedTxn>[];

    for (final sms in outcome.messages) {
      final parsedTxn = parser.parseOne(
        sms,
        scanBatchId: scanBatchId,
        bodyHashSalt: bodyHashSalt,
      );
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

    return ScanRunResult(
      status: SmsScanStatus.success,
      scanBatchId: scanBatchId,
      parsed: parsed,
      autoAdded: autoAdded,
      queuedReview: queuedReview,
      skippedDuplicate: skippedDuplicate,
      collisionSets: collisionSetIds.length,
      obligationCandidates: candidates.length,
    );
  }
}
