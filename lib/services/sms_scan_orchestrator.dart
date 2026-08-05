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
    // this debit, that commitment owns it and the notice must not raise a
    // second obligation beside it. The rupee is still attributed — just to the
    // stronger of the two signals, the one backed by real occurrences.
    //
    // The rule lives in `MandateOwnership` rather than here, and both places
    // that need it below ask the same object. A predicate spelled out at each
    // call site is not a rule (TASK-41).
    final ownership = MandateOwnership(candidates);

    // Every notice for one payee collapses onto `sms_mandate:<payee>` — the key
    // is payee-only on purpose, because the announced amount changes month to
    // month. The upsert merge then takes the incoming due date unconditionally,
    // so writing each notice as it is read leaves the row holding whichever one
    // the reader happened to yield last rather than the one actually next due.
    // On the device that left the PhonePe mandate announcing 30 Dec 2025 while
    // the newest notice for it said 29 Jul 2026 (TASK-42).
    final latestPerPayee = <String, ObligationRecord>{};
    // The payees some commitment owns *as this scan reads them*. A notice that
    // is owned is never written, so the stored row keeps whatever it last held
    // — on the device, a day-30 date from a December notice that no longer
    // matches the day-29 commitment. Judging the stored row on its own stale
    // fields would therefore never retire it. What the scan just read decides.
    final ownedPayeeKeys = <String>{};
    for (final notice in notices) {
      final obligation = noticeObligations.toObligation(notice, now: timestamp);
      if (ownership.owns(obligation)) {
        ownedPayeeKeys.add(obligation.dedupeKey);
        continue;
      }
      final held = latestPerPayee[obligation.dedupeKey];
      if (held == null || _announcedAfter(obligation, held)) {
        latestPerPayee[obligation.dedupeKey] = obligation;
      }
    }
    for (final obligation in latestPerPayee.values) {
      await obliRepo.upsert(obligation, now: timestamp);
    }

    // A payee is only redundant when *every* notice the scan read for it is
    // owned. `sms_mandate:` is keyed on the payee alone, and one payee can
    // front several unrelated mandates: Axis announces both the ₹120.07 Bharat
    // Connect postpaid bill and a ₹310 Bharat Connect gas bill as "towards
    // PhonePe". Retiring the row because one of its notices is owned would take
    // the other, unowned, debit out of the forecast with it — a silent
    // exclusion. Where an unowned notice exists the row stays live and now
    // carries that debit, written just above.
    final redundantPayeeKeys = ownedPayeeKeys.difference(
      latestPerPayee.keys.toSet(),
    );

    // The same rule, applied to rows already stored. The loop above only
    // declines to write a *new* notice obligation for an owned debit; one
    // written before the commitment locked stayed in the forecast beside it
    // forever (TASK-32's recorded finding). Runs after the notice loop so a
    // notice re-written this scan is retired only if a commitment owns it.
    final stored = await obliRepo.allActive();
    final retiredMandates = await obliRepo.retireMandates(
      dedupeKeys: {
        for (final obligation in stored)
          if (!obligation.isRetired &&
              obligation.dedupeKey.startsWith(kMandateKeyPrefix) &&
              (redundantPayeeKeys.contains(obligation.dedupeKey) ||
                  ownership.owns(obligation)))
            obligation.dedupeKey,
      },
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

  /// Whether [candidate] announces a later debit than [held].
  ///
  /// A notice always carries a date, so the nulls below are unreachable in
  /// practice; a dateless record simply never displaces one that has a date.
  static bool _announcedAfter(ObligationRecord candidate, ObligationRecord held) {
    final next = candidate.dueDate;
    final current = held.dueDate;
    if (next == null) return false;
    if (current == null) return true;
    return next.isAfter(current);
  }
}
