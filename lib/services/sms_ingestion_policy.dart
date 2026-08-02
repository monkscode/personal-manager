import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/sms_models.dart';

/// Confidence at or above which a parsed SMS transaction is auto-added on a
/// later scan (first scans always review). Interim value pending calibration
/// against the Phase I golden corpus (spec §6/§10, decision D9); a corpus
/// regression is expected to tune this. Single source of truth — the parser's
/// `needsReview` gate and the ingestion policy both read it.
const double kAutoAddConfidenceThreshold = 0.8;

enum IngestionAction { upsert, queueReview, skipDuplicate }

class IngestionDecision {
  const IngestionDecision({
    required this.action,
    required this.transaction,
    this.existingToFlag = const [],
  });

  final IngestionAction action;
  final ParsedTxn transaction;

  /// Already-stored rows that must be re-written because [transaction] joined
  /// their collision set. Every member is listed, not just the first — a third
  /// or fourth duplicate otherwise leaves earlier members in a stale set.
  final List<ParsedTxn> existingToFlag;
}

class SmsIngestionPolicy {
  const SmsIngestionPolicy._();

  static IngestionDecision classify({
    required ParsedTxn incoming,
    required List<ParsedTxn> existing,
    required bool isFirstScan,
    DateTime? now,
  }) {
    return _classify(
      incoming: incoming,
      smsIdMatches: existing,
      strongRefCandidates: existing,
      weakCollisionCandidates: existing,
      isFirstScan: isFirstScan,
      now: now,
    );
  }

  /// Same policy as [classify], but fed pre-filtered candidate rows instead of
  /// the whole table so callers can back each check with an index. Each list
  /// must be a *superset* of the rows that could match its check; the same pure
  /// predicates then refine them.
  static IngestionDecision classifyWithCandidates({
    required ParsedTxn incoming,
    required Iterable<ParsedTxn> smsIdMatches,
    required Iterable<ParsedTxn> strongRefCandidates,
    required Iterable<ParsedTxn> weakCollisionCandidates,
    required bool isFirstScan,
    DateTime? now,
  }) {
    return _classify(
      incoming: incoming,
      smsIdMatches: smsIdMatches,
      strongRefCandidates: strongRefCandidates,
      weakCollisionCandidates: weakCollisionCandidates,
      isFirstScan: isFirstScan,
      now: now,
    );
  }

  static IngestionDecision _classify({
    required ParsedTxn incoming,
    required Iterable<ParsedTxn> smsIdMatches,
    required Iterable<ParsedTxn> strongRefCandidates,
    required Iterable<ParsedTxn> weakCollisionCandidates,
    required bool isFirstScan,
    DateTime? now,
  }) {
    if (smsIdMatches.any((txn) => txn.smsId == incoming.smsId)) {
      return IngestionDecision(
        action: IngestionAction.skipDuplicate,
        transaction: incoming,
      );
    }

    if (strongRefCandidates.any((txn) => _strongReferenceDuplicate(txn, incoming))) {
      return IngestionDecision(
        action: IngestionAction.skipDuplicate,
        transaction: incoming,
      );
    }

    // Every stored row that shares the tuple *and* has nothing to tell it apart
    // from `incoming` is a member. Testing each candidate — rather than only the
    // first — is what stops a row that differs from the earliest member but
    // matches a later one from escaping as an auto-add.
    final collision = weakCollisionCandidates
        .where((txn) => _weakCollision(txn, incoming))
        .where((txn) => !_hasDistinguishingSignal(incoming, txn))
        .toList();
    if (collision.isNotEmpty) {
      final collisionSetId = collisionSetIdFor(incoming);
      return IngestionDecision(
        action: IngestionAction.queueReview,
        transaction: incoming.copyWith(
          reviewStatus: ReviewStatus.needsReview,
          reviewReason: ReviewReason.dedupCollision,
          collisionSetId: collisionSetId,
          coverageBucket: CoverageBucket.reviewPending,
        ),
        existingToFlag: [
          for (final member in collision)
            member.copyWith(
              reviewStatus: ReviewStatus.needsReview,
              reviewReason: ReviewReason.dedupCollision,
              collisionSetId: collisionSetId,
              coverageBucket: CoverageBucket.reviewPending,
            ),
        ],
      );
    }

    if (isFirstScan) {
      return IngestionDecision(
        action: IngestionAction.queueReview,
        transaction: incoming.copyWith(
          reviewStatus: ReviewStatus.needsReview,
          reviewReason: ReviewReason.firstScan,
          coverageBucket: CoverageBucket.reviewPending,
        ),
      );
    }

    if (incoming.confidence < kAutoAddConfidenceThreshold ||
        incoming.reviewReason == ReviewReason.parserUncertain) {
      return IngestionDecision(
        action: IngestionAction.queueReview,
        transaction: incoming.copyWith(
          reviewStatus: ReviewStatus.needsReview,
          reviewReason: incoming.reviewReason ?? ReviewReason.lowConfidence,
          coverageBucket: CoverageBucket.reviewPending,
        ),
      );
    }

    return IngestionDecision(
      action: IngestionAction.upsert,
      transaction: incoming.copyWith(
        reviewStatus: ReviewStatus.autoAdded,
        autoAddedAt: now ?? DateTime.now(),
        coverageBucket: CoverageBucket.datedEvent,
      ),
    );
  }

  static bool _weakCollision(ParsedTxn a, ParsedTxn b) {
    return a.amountPaise == b.amountPaise &&
        a.txnLocalDate == b.txnLocalDate &&
        a.accountLast4 != null &&
        a.accountLast4 == b.accountLast4 &&
        a.direction == b.direction;
  }

  static bool _strongReferenceDuplicate(ParsedTxn a, ParsedTxn b) {
    final refA = a.refNumber?.trim();
    if (refA == null || refA.isEmpty || refA != b.refNumber?.trim()) {
      return false;
    }
    if (a.instrument != b.instrument || a.direction != b.direction) return false;
    if (a.amountPaise != b.amountPaise) return false;
    // Account, when present on both, must agree; an absent account no longer
    // blocks the match (a resent UPI alert often drops the a/c tail).
    if (a.accountLast4 != null &&
        b.accountLast4 != null &&
        a.accountLast4 != b.accountLast4) {
      return false;
    }
    return true;
  }

  /// Whether anything separates two rows that already share amount, day,
  /// account and direction: differing reference numbers, differing merchants,
  /// or differing balances. Public so [SmsLiveNormalizer] applies the same
  /// definition at read time that ingestion applied at write time.
  static bool hasDistinguishingSignal(ParsedTxn a, ParsedTxn b) =>
      _hasDistinguishingSignal(a, b);

  static bool _hasDistinguishingSignal(ParsedTxn a, ParsedTxn b) {
    final refA = a.refNumber?.trim();
    final refB = b.refNumber?.trim();
    if (refA != null &&
        refA.isNotEmpty &&
        refB != null &&
        refB.isNotEmpty &&
        refA != refB) {
      return true;
    }

    final merchantA = a.merchant?.trim().toLowerCase();
    final merchantB = b.merchant?.trim().toLowerCase();
    if (merchantA != null &&
        merchantA.isNotEmpty &&
        merchantB != null &&
        merchantB.isNotEmpty &&
        merchantA != merchantB) {
      return true;
    }

    return a.balancePaise != null &&
        b.balancePaise != null &&
        a.balancePaise != b.balancePaise;
  }

  /// The collision set a row belongs to, derived from its tuple **only**.
  ///
  /// Deliberately free of any `sms_id`: mixing one in made the id depend on
  /// which duplicate happened to arrive first, so a third message re-keyed the
  /// earliest member and orphaned the middle one in a set of its own. Keying on
  /// the tuple alone makes the id order-independent, so re-running ingestion is
  /// idempotent and every duplicate of the same tuple lands in one set.
  ///
  /// Shared with [SmsLiveNormalizer] so a set flagged at ingest time and one
  /// spotted at read time carry the same id.
  static String collisionSetIdFor(ParsedTxn txn) {
    final raw = [
      txn.amountPaise,
      txn.txnLocalDate,
      txn.accountLast4 ?? '',
      txn.direction.storageValue,
    ].join('|');
    return 'collision:${sha256.convert(utf8.encode(raw))}';
  }
}
