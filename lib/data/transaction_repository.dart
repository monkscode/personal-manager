import 'package:sqflite/sqflite.dart';

import '../services/sms_ingestion_policy.dart';
import 'forecast_models.dart';
import 'sms_models.dart';

class TransactionRepository {
  const TransactionRepository(this._db);

  final Database _db;

  Future<IngestionDecision> ingestParsedTxn(
    ParsedTxn incoming, {
    required bool isFirstScan,
    DateTime? now,
  }) async {
    return _db.transaction((txn) async {
      final smsIdMatches = await _candidates(
        txn,
        where: 'sms_id = ?',
        whereArgs: [incoming.smsId],
      );

      var strongRefCandidates = const <ParsedTxn>[];
      final ref = incoming.refNumber?.trim();
      if (ref != null && ref.isNotEmpty) {
        strongRefCandidates = await _candidates(
          txn,
          where:
              'ref_number = ? AND instrument = ? AND direction = ? AND amount_paise = ?',
          whereArgs: [
            ref,
            incoming.instrument.storageValue,
            incoming.direction.storageValue,
            incoming.amountPaise,
          ],
        );
      }

      var weakCollisionCandidates = const <ParsedTxn>[];
      if (incoming.accountLast4 != null) {
        weakCollisionCandidates = await _candidates(
          txn,
          where:
              'amount_paise = ? AND txn_local_date = ? AND account_last4 = ? AND direction = ?',
          whereArgs: [
            incoming.amountPaise,
            incoming.txnLocalDate,
            incoming.accountLast4,
            incoming.direction.storageValue,
          ],
        );
      }

      final decision = SmsIngestionPolicy.classifyWithCandidates(
        incoming: incoming,
        smsIdMatches: smsIdMatches,
        strongRefCandidates: strongRefCandidates,
        weakCollisionCandidates: weakCollisionCandidates,
        isFirstScan: isFirstScan,
        now: now,
      );

      if (decision.existingToFlag != null) {
        await _insertRow(txn, decision.existingToFlag!, DateTime.now());
      }
      if (decision.action != IngestionAction.skipDuplicate) {
        await _insertRow(txn, decision.transaction, now ?? DateTime.now());
      }
      return decision;
    });
  }

  Future<void> upsertParsedTxn(ParsedTxn txn, {DateTime? createdAt}) async {
    await _insertRow(_db, txn, createdAt ?? DateTime.now());
  }

  Future<void> _insertRow(
    DatabaseExecutor executor,
    ParsedTxn txn,
    DateTime createdAt,
  ) async {
    await executor.insert(
      'transactions',
      _toRow(txn, createdAt),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ParsedTxn>> _candidates(
    DatabaseExecutor executor, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final rows = await executor.query(
      'transactions',
      where: where,
      whereArgs: whereArgs,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<List<ParsedTxn>> queryByMonth(String txnMonth) async {
    final rows = await _db.query(
      'transactions',
      where: 'txn_month = ?',
      whereArgs: [txnMonth],
      orderBy: 'txn_date ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<List<ParsedTxn>> queryByCategory(String categoryKey) async {
    final rows = await _db.query(
      'transactions',
      where: 'category_key = ?',
      whereArgs: [categoryKey],
      orderBy: 'txn_date ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// All rows imported in a given scan batch, oldest first — the review queue
  /// for a just-completed scan.
  Future<List<ParsedTxn>> queryByScanBatch(String scanBatchId) async {
    final rows = await _db.query(
      'transactions',
      where: 'scan_batch_id = ?',
      whereArgs: [scanBatchId],
      orderBy: 'txn_date ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// All rows in a given review status, oldest first.
  Future<List<ParsedTxn>> queryByReviewStatus(ReviewStatus status) async {
    final rows = await _db.query(
      'transactions',
      where: 'review_status = ?',
      whereArgs: [status.storageValue],
      orderBy: 'txn_date ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Auto-added rows, most recently added first — the "recently auto-added"
  /// correction view (spec §5, audit for mis-parsed auto-adds).
  Future<List<ParsedTxn>> recentlyAutoAdded({int limit = 50}) async {
    final rows = await _db.query(
      'transactions',
      where: 'review_status = ? AND auto_added_at IS NOT NULL',
      whereArgs: [ReviewStatus.autoAdded.storageValue],
      orderBy: 'auto_added_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Updates a row's [ReviewStatus] (confirm/dismiss/re-review) by `sms_id`,
  /// keeping `needs_review` consistent. Dismissed rows remain queryable for
  /// audit but are excluded from forecasts by the reading queries. Returns the
  /// number of rows updated.
  Future<int> updateReviewStatus(
    String smsId,
    ReviewStatus status, {
    ReviewReason? reviewReason,
    CoverageBucket? coverageBucket,
  }) async {
    final values = <String, Object?>{
      'review_status': status.storageValue,
      'needs_review': status == ReviewStatus.needsReview ? 1 : 0,
      'review_reason': reviewReason?.storageValue,
    };
    if (coverageBucket != null) {
      values['coverage_bucket'] = coverageBucket.storageValue;
    }
    return _db.update(
      'transactions',
      values,
      where: 'sms_id = ?',
      whereArgs: [smsId],
    );
  }

  Future<List<ParsedTxn>> allSince(DateTime since) async {
    final rows = await _db.query(
      'transactions',
      where: 'txn_date >= ?',
      whereArgs: [since.millisecondsSinceEpoch],
      orderBy: 'txn_date ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<BalanceAnchor?> latestBalanceAnchor({
    required String primaryAccountLast4,
  }) async {
    final rows = await _db.query(
      'transactions',
      where:
          'instrument = ? AND balance_paise IS NOT NULL AND account_last4 = ? AND review_status != ?',
      whereArgs: [
        PaymentInstrument.bank.storageValue,
        primaryAccountLast4,
        ReviewStatus.dismissed.storageValue,
      ],
      orderBy: 'txn_date DESC, id DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    return BalanceAnchor(
      amountPaise: row['balance_paise']! as int,
      asOf: DateTime.fromMillisecondsSinceEpoch(row['txn_date']! as int),
      accountLast4: row['account_last4'] as String?,
      source: BalanceAnchorSource.smsBankBalance,
    );
  }

  static Map<String, Object?> _toRow(ParsedTxn txn, DateTime createdAt) {
    return {
      'sms_id': txn.smsId,
      'sender': txn.sender,
      'direction': txn.direction.storageValue,
      'instrument': txn.instrument.storageValue,
      'type': txn.type.storageValue,
      'amount_paise': txn.amountPaise,
      'txn_date': txn.txnDate.millisecondsSinceEpoch,
      'txn_local_date': txn.txnLocalDate,
      'txn_month': txn.txnMonth,
      'effective_month': txn.effectiveMonth,
      'account_last4': txn.accountLast4,
      'merchant': txn.merchant,
      'upi_vpa_norm': txn.upiVpaNorm,
      'payee_type': txn.payeeType.storageValue,
      'category_key': txn.categoryKey,
      'confidence': txn.confidence,
      'needs_review': txn.needsReview ? 1 : 0,
      'review_status': txn.reviewStatus.storageValue,
      'review_reason': txn.reviewReason?.storageValue,
      'auto_added_at': txn.autoAddedAt?.millisecondsSinceEpoch,
      'scan_batch_id': txn.scanBatchId,
      'collision_set_id': txn.collisionSetId,
      'source': txn.source.storageValue,
      'ref_number': txn.refNumber,
      'balance_paise': txn.balancePaise,
      'owner_key': txn.ownerKey,
      'coverage_bucket': txn.coverageBucket.storageValue,
      'raw_body_redacted': txn.rawBodyRedacted,
      'body_hash': txn.bodyHash,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }

  static ParsedTxn _fromRow(Map<String, Object?> row) {
    return ParsedTxn(
      smsId: row['sms_id']! as String,
      sender: row['sender']! as String,
      direction: _direction(row['direction']! as String),
      instrument: _instrument(row['instrument']! as String),
      type: _type(row['type']! as String),
      amountPaise: row['amount_paise']! as int,
      txnDate: DateTime.fromMillisecondsSinceEpoch(row['txn_date']! as int),
      effectiveMonth: row['effective_month'] as String?,
      accountLast4: row['account_last4'] as String?,
      merchant: row['merchant'] as String?,
      upiVpaNorm: row['upi_vpa_norm'] as String?,
      payeeType: _payeeType(row['payee_type']! as String),
      categoryKey: row['category_key']! as String,
      confidence: (row['confidence']! as num).toDouble(),
      reviewStatus: _reviewStatus(row['review_status']! as String),
      reviewReason: _reviewReason(row['review_reason'] as String?),
      autoAddedAt: _date(row['auto_added_at'] as int?),
      collisionSetId: row['collision_set_id'] as String?,
      source: _source(row['source']! as String),
      refNumber: row['ref_number'] as String?,
      balancePaise: row['balance_paise'] as int?,
      ownerKey: row['owner_key'] as String?,
      coverageBucket: _coverageBucket(row['coverage_bucket']! as String),
      rawBodyRedacted: row['raw_body_redacted']! as String,
      bodyHash: row['body_hash']! as String,
      scanBatchId: row['scan_batch_id']! as String,
    );
  }

  static DateTime? _date(int? millis) =>
      millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);

  static TransactionDirection _direction(String value) => switch (value) {
    'debit' => TransactionDirection.debit,
    'credit' => TransactionDirection.credit,
    _ => throw ArgumentError.value(value, 'direction'),
  };

  static PaymentInstrument _instrument(String value) => switch (value) {
    'bank' => PaymentInstrument.bank,
    'card' => PaymentInstrument.card,
    _ => throw ArgumentError.value(value, 'instrument'),
  };

  static TxnType _type(String value) => switch (value) {
    'upi' => TxnType.upi,
    'atm' => TxnType.atm,
    'pos' => TxnType.pos,
    'transfer' => TxnType.transfer,
    'other' => TxnType.other,
    _ => throw ArgumentError.value(value, 'type'),
  };

  static PayeeType _payeeType(String value) => switch (value) {
    'merchant' => PayeeType.merchant,
    'p2p_individual' => PayeeType.p2pIndividual,
    'self_transfer' => PayeeType.selfTransfer,
    'wallet' => PayeeType.wallet,
    'unknown' => PayeeType.unknown,
    _ => throw ArgumentError.value(value, 'payee_type'),
  };

  static ReviewStatus _reviewStatus(String value) => switch (value) {
    'confirmed' => ReviewStatus.confirmed,
    'auto_added' => ReviewStatus.autoAdded,
    'needs_review' => ReviewStatus.needsReview,
    'dismissed' => ReviewStatus.dismissed,
    _ => throw ArgumentError.value(value, 'review_status'),
  };

  static ReviewReason? _reviewReason(String? value) => switch (value) {
    null => null,
    'first_scan' => ReviewReason.firstScan,
    'low_confidence' => ReviewReason.lowConfidence,
    'dedup_collision' => ReviewReason.dedupCollision,
    'parser_uncertain' => ReviewReason.parserUncertain,
    'user_flagged' => ReviewReason.userFlagged,
    _ => throw ArgumentError.value(value, 'review_reason'),
  };

  static TxnSource _source(String value) => switch (value) {
    'sms' => TxnSource.sms,
    'manual' => TxnSource.manual,
    _ => throw ArgumentError.value(value, 'source'),
  };

  static CoverageBucket _coverageBucket(String value) => switch (value) {
    'anchor_included' => CoverageBucket.anchorIncluded,
    'dated_event' => CoverageBucket.datedEvent,
    'quantified_excluded' => CoverageBucket.quantifiedExcluded,
    'review_pending' => CoverageBucket.reviewPending,
    _ => throw ArgumentError.value(value, 'coverage_bucket'),
  };
}
