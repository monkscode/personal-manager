import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../core/money.dart';
import 'forecast_models.dart';
import 'models.dart';
import 'obligation_models.dart';
import 'sms_models.dart';

class ObligationRepository {
  const ObligationRepository(this._db);

  final Database _db;

  /// Writes [obligation], merging it over any row that already holds the same
  /// `dedupeKey`.
  ///
  /// The caller is the SMS scan loop, which re-derives a whole record from
  /// message history on every scan and therefore carries only defaults for the
  /// columns the user owns. Preserving those is the default here and refreshing
  /// is opt-in (see [_merge]) — otherwise each scan would silently discard the
  /// user's reserve progress, dismissals and payment record.
  ///
  /// The read and the write run in one transaction because the merge is a
  /// read-modify-write.
  Future<void> upsert(ObligationRecord obligation, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    await _db.transaction((txn) async {
      final existing = await _byDedupeKey(txn, obligation.dedupeKey);
      await _upsertWithin(txn, obligation, existing, timestamp);
    });
  }

  static Future<void> _upsertWithin(
    DatabaseExecutor db,
    ObligationRecord incoming,
    ObligationRecord? existing,
    DateTime timestamp,
  ) async {
    final merged = existing == null ? incoming : _merge(existing, incoming);
    await db.insert(
      'obligations',
      _toRow(
        merged,
        createdAt: existing?.createdAt ?? incoming.createdAt,
        updatedAt: timestamp,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Refreshes the columns a scan legitimately re-derives from SMS/Gmail, and
  /// preserves everything else from [existing].
  ///
  /// The preserved set is exactly the columns that hold *user intent* rather
  /// than derived data: `reserveEnabled`, `reserveFundedPaise`,
  /// `userCadenceStatus`, `reviewStatus`, `paymentStatus`, `amountPaidPaise`
  /// and `outstandingPaise` — plus the row identity (`id`, `sourceType`).
  /// Nothing a user can change through the UI may be sourced from the incoming
  /// scan record.
  /// Written out in full rather than via `copyWith`. `copyWith` resolves every
  /// argument with `?? this.x`, so it cannot carry a *null* across: an
  /// obligation that loses its due date on a rescan would keep the stale one
  /// forever. Constructing explicitly makes the preserved set visible in one
  /// place and lets a cleared field actually clear.
  static ObligationRecord _merge(
    ObligationRecord existing,
    ObligationRecord incoming,
  ) => ObligationRecord(
    // Row identity — never re-derived.
    id: existing.id,
    sourceType: existing.sourceType,
    dedupeKey: existing.dedupeKey,
    createdAt: existing.createdAt,
    // User intent — never sourced from a scan.
    reserveEnabled: existing.reserveEnabled,
    reserveFundedPaise: existing.reserveFundedPaise,
    userCadenceStatus: existing.userCadenceStatus,
    reviewStatus: existing.reviewStatus,
    paymentStatus: existing.paymentStatus,
    amountPaidPaise: existing.amountPaidPaise,
    outstandingPaise: existing.outstandingPaise,
    // Derived — refreshed from the incoming record, nulls included.
    sourceId: incoming.sourceId,
    merchant: incoming.merchant,
    merchantNorm: incoming.merchantNorm,
    categoryKey: incoming.categoryKey,
    amountPaise: incoming.amountPaise,
    amountStatus: incoming.amountStatus,
    recurrence: incoming.recurrence,
    dueDate: incoming.dueDate,
    dueDay: incoming.dueDay,
    dueMonth: incoming.dueMonth,
    paymentAccountHintLast4: incoming.paymentAccountHintLast4,
    paymentAccountScope: incoming.paymentAccountScope,
    nextExpectedSource: incoming.nextExpectedSource,
    upiVpaNorm: incoming.upiVpaNorm,
    payeeType: incoming.payeeType,
    confidence: incoming.confidence,
    updatedAt: incoming.updatedAt,
    // Derived, and therefore cleared: being upserted at all means a source just
    // re-derived this key, so whatever retired it no longer holds. A commitment
    // that pauses for a cycle and resumes comes back instead of staying dead.
    // This is why `_merge` constructs explicitly rather than using `copyWith` —
    // `copyWith` cannot carry a null across.
    retiredAt: incoming.retiredAt,
  );

  Future<List<ObligationRecord>> allActive() async {
    final rows = await _db.query(
      'obligations',
      where: 'review_status != ?',
      whereArgs: [ObligationReviewStatus.dismissed.storageValue],
      orderBy: 'merchant_norm ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  /// Stamps `retired_at` on every row whose `dedupeKey` starts with one of
  /// [keyPrefixes] and is absent from [derivedKeys]. Returns the number stamped.
  ///
  /// The contract this rests on: the caller has just enumerated the *whole*
  /// key-space behind those prefixes, so a stored key that did not come back
  /// cannot be derived any more. Only a source that guarantees that may pass a
  /// prefix — see `ObligationCandidateSource.sweptKeyPrefixes`, which is
  /// deliberately empty for sources that enumerate nothing.
  ///
  /// Nothing is deleted. The row keeps its `review_status`, its reserve
  /// progress and its id, because a scan that discards the user's obligation
  /// decisions is TASK-02 — the Critical this repository already had once.
  /// Rows already retired are left alone so the original timestamp survives.
  Future<int> retireUnderivable({
    required Set<String> keyPrefixes,
    required Set<String> derivedKeys,
    required DateTime now,
  }) async {
    if (keyPrefixes.isEmpty) return 0;
    var retired = 0;
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'obligations',
        columns: ['id', 'dedupe_key'],
        where: 'retired_at IS NULL',
      );
      for (final row in rows) {
        final key = row['dedupe_key']! as String;
        if (!keyPrefixes.any(key.startsWith)) continue;
        if (derivedKeys.contains(key)) continue;
        await txn.update(
          'obligations',
          {
            'retired_at': now.millisecondsSinceEpoch,
            'updated_at': now.millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [row['id']],
        );
        retired++;
      }
    });
    return retired;
  }

  Future<ObligationRecord?> byDedupeKey(String dedupeKey) =>
      _byDedupeKey(_db, dedupeKey);

  static Future<ObligationRecord?> _byDedupeKey(
    DatabaseExecutor db,
    String dedupeKey,
  ) async {
    final rows = await db.query(
      'obligations',
      where: 'dedupe_key = ?',
      whereArgs: [dedupeKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  /// Migrates the user's legacy `manualTx` payload. Runs once at first launch,
  /// in a single transaction: a partial import is a state the user can neither
  /// see nor retry cleanly, so a failure part-way must commit nothing.
  Future<int> importLegacyManualEntries(
    List<ExpenseEntry> entries, {
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    var imported = 0;
    await _db.transaction((txn) async {
      var count = 0;
      for (final entry in entries) {
        final record = _fromLegacyEntry(entry, timestamp);
        if (await _byDedupeKey(txn, record.dedupeKey) != null) {
          continue;
        }
        await _upsertWithin(txn, record, null, timestamp);
        count++;
      }
      imported = count;
    });
    return imported;
  }

  Future<void> updateReserveProgress(
    String dedupeKey, {
    required bool enabled,
    required int fundedPaise,
    DateTime? now,
  }) async {
    if (fundedPaise < 0) {
      throw ArgumentError.value(
        fundedPaise,
        'fundedPaise',
        'must be non-negative',
      );
    }
    await _db.update(
      'obligations',
      {
        'reserve_enabled': enabled ? 1 : 0,
        'reserve_funded_paise': fundedPaise,
        'updated_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
      },
      where: 'dedupe_key = ?',
      whereArgs: [dedupeKey],
    );
  }

  static ObligationRecord _fromLegacyEntry(ExpenseEntry entry, DateTime now) {
    final merchantNorm = _normalize(entry.name);
    final amountPaise = MoneyParser.paiseFromRupeeNumber(entry.amount);
    final recurrence = _recurrence(entry.recurrence);
    // Normalize dueDate to yyyy-mm-dd format for stable hash (ignore time and timezone)
    final dueDateNormalized = entry.dueDate == null
        ? 'no-date'
        : '${entry.dueDate!.year.toString().padLeft(4, '0')}-${entry.dueDate!.month.toString().padLeft(2, '0')}-${entry.dueDate!.day.toString().padLeft(2, '0')}';
    final dedupeRaw = [
      'legacy',
      merchantNorm,
      entry.categoryKey,
      amountPaise,
      recurrence.name,
      dueDateNormalized,
    ].join('|');
    final digest = sha256.convert(utf8.encode(dedupeRaw)).toString();

    return ObligationRecord(
      sourceType: ObligationSourceType.manual,
      sourceId: 'legacy:$digest',
      dedupeKey: 'legacy:$digest',
      merchant: entry.name,
      merchantNorm: merchantNorm,
      categoryKey: entry.categoryKey,
      amountPaise: amountPaise,
      amountStatus: AmountStatus.known,
      recurrence: recurrence,
      dueDate: entry.dueDate,
      dueDay: entry.dueDate?.day,
      dueMonth: entry.dueDate?.month,
      paymentAccountScope: AccountScope.unknown,
      paymentStatus: ReconciliationPaymentStatus.unpaid,
      nextExpectedSource: entry.dueDate == null
          ? NextExpectedSource.unknown
          : NextExpectedSource.userEntered,
      payeeType: PayeeType.unknown,
      userCadenceStatus: UserCadenceStatus.userConfirmed,
      confidence: 1,
      reviewStatus: ObligationReviewStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );
  }

  static Map<String, Object?> _toRow(
    ObligationRecord obligation, {
    required DateTime createdAt,
    required DateTime updatedAt,
  }) {
    return {
      'id': obligation.id,
      'source_type': obligation.sourceType.storageValue,
      'source_id': obligation.sourceId,
      'dedupe_key': obligation.dedupeKey,
      'merchant': obligation.merchant,
      'merchant_norm': obligation.merchantNorm,
      'category_key': obligation.categoryKey,
      'amount_paise': obligation.amountPaise,
      'amount_status': obligation.amountStatus.name,
      'recurrence': obligation.recurrence.name,
      'due_date': obligation.dueDate?.millisecondsSinceEpoch,
      'due_day': obligation.dueDay,
      'due_month': obligation.dueMonth,
      'payment_account_hint_last4': obligation.paymentAccountHintLast4,
      'payment_account_scope': obligation.paymentAccountScope.storageValue,
      'amount_paid_paise': obligation.amountPaidPaise,
      'outstanding_paise': obligation.outstandingPaise,
      'payment_status': obligation.paymentStatus.storageValue,
      'next_expected_source': obligation.nextExpectedSource.storageValue,
      'upi_vpa_norm': obligation.upiVpaNorm,
      'payee_type': obligation.payeeType.storageValue,
      'user_cadence_status': obligation.userCadenceStatus.storageValue,
      'confidence': obligation.confidence,
      'review_status': obligation.reviewStatus.storageValue,
      'reserve_enabled': obligation.reserveEnabled ? 1 : 0,
      'reserve_funded_paise': obligation.reserveFundedPaise,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
      'retired_at': obligation.retiredAt?.millisecondsSinceEpoch,
    };
  }

  static ObligationRecord _fromRow(Map<String, Object?> row) {
    return ObligationRecord(
      id: row['id'] as int?,
      sourceType: _sourceType(row['source_type']! as String),
      sourceId: row['source_id'] as String?,
      dedupeKey: row['dedupe_key']! as String,
      merchant: row['merchant']! as String,
      merchantNorm: row['merchant_norm']! as String,
      categoryKey: row['category_key']! as String,
      amountPaise: row['amount_paise'] as int?,
      amountStatus: AmountStatus.values.byName(row['amount_status']! as String),
      recurrence: ReconciliationRecurrence.values.byName(
        row['recurrence']! as String,
      ),
      dueDate: _date(row['due_date'] as int?),
      dueDay: row['due_day'] as int?,
      dueMonth: row['due_month'] as int?,
      paymentAccountHintLast4: row['payment_account_hint_last4'] as String?,
      paymentAccountScope: _accountScope(
        row['payment_account_scope']! as String,
      ),
      amountPaidPaise: row['amount_paid_paise'] as int?,
      outstandingPaise: row['outstanding_paise'] as int?,
      paymentStatus: _paymentStatus(row['payment_status']! as String),
      nextExpectedSource: _nextExpectedSource(
        row['next_expected_source']! as String,
      ),
      upiVpaNorm: row['upi_vpa_norm'] as String?,
      payeeType: _payeeType(row['payee_type']! as String),
      userCadenceStatus: _userCadenceStatus(
        row['user_cadence_status']! as String,
      ),
      confidence: (row['confidence']! as num).toDouble(),
      reviewStatus: _reviewStatus(row['review_status']! as String),
      reserveEnabled: (row['reserve_enabled']! as int) == 1,
      reserveFundedPaise: row['reserve_funded_paise']! as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at']! as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
      retiredAt: _date(row['retired_at'] as int?),
    );
  }

  static String _normalize(String value) =>
      value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  static ReconciliationRecurrence _recurrence(String value) => switch (value) {
    'monthly' => ReconciliationRecurrence.monthly,
    'quarterly' => ReconciliationRecurrence.quarterly,
    'annual' => ReconciliationRecurrence.annual,
    _ => ReconciliationRecurrence.onetime,
  };

  static DateTime? _date(int? millis) =>
      millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);

  static ObligationSourceType _sourceType(String value) => switch (value) {
    'gmail' => ObligationSourceType.gmail,
    'sms_recurring' => ObligationSourceType.smsRecurring,
    'manual' => ObligationSourceType.manual,
    'configured_plan' => ObligationSourceType.configuredPlan,
    _ => throw ArgumentError.value(value, 'source_type'),
  };

  static NextExpectedSource _nextExpectedSource(String value) =>
      switch (value) {
        'explicit_due_date' => NextExpectedSource.explicitDueDate,
        'locked_cadence' => NextExpectedSource.lockedCadence,
        'user_entered' => NextExpectedSource.userEntered,
        'unknown' => NextExpectedSource.unknown,
        _ => throw ArgumentError.value(value, 'next_expected_source'),
      };

  static AccountScope _accountScope(String value) => switch (value) {
    'primary' => AccountScope.primary,
    'secondary' => AccountScope.secondary,
    'unknown' => AccountScope.unknown,
    _ => throw ArgumentError.value(value, 'payment_account_scope'),
  };

  static ReconciliationPaymentStatus _paymentStatus(String value) =>
      switch (value) {
        'unpaid' => ReconciliationPaymentStatus.unpaid,
        'paid' => ReconciliationPaymentStatus.paid,
        'partial' => ReconciliationPaymentStatus.partial,
        'possibly_paid' => ReconciliationPaymentStatus.possiblyPaid,
        'out_of_primary_scope' => ReconciliationPaymentStatus.outOfPrimaryScope,
        _ => throw ArgumentError.value(value, 'payment_status'),
      };

  static UserCadenceStatus _userCadenceStatus(String value) => switch (value) {
    'algorithm_detected' => UserCadenceStatus.algorithmDetected,
    'user_confirmed' => UserCadenceStatus.userConfirmed,
    'user_dismissed' => UserCadenceStatus.userDismissed,
    _ => throw ArgumentError.value(value, 'user_cadence_status'),
  };

  static PayeeType _payeeType(String value) => switch (value) {
    'merchant' => PayeeType.merchant,
    'p2p_individual' => PayeeType.p2pIndividual,
    'self_transfer' => PayeeType.selfTransfer,
    'wallet' => PayeeType.wallet,
    'bank_mandate' => PayeeType.bankMandate,
    'unknown' => PayeeType.unknown,
    _ => throw ArgumentError.value(value, 'payee_type'),
  };

  static ObligationReviewStatus _reviewStatus(String value) => switch (value) {
    'confirmed' => ObligationReviewStatus.confirmed,
    'needs_review' => ObligationReviewStatus.needsReview,
    'dismissed' => ObligationReviewStatus.dismissed,
    _ => throw ArgumentError.value(value, 'review_status'),
  };
}
