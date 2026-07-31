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

  Future<void> upsert(ObligationRecord obligation, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final existing = await byDedupeKey(obligation.dedupeKey);
    final obligationToUpsert = existing?.id != null
        ? obligation.copyWith(id: existing!.id)
        : obligation;
    await _db.insert(
      'obligations',
      _toRow(
        obligationToUpsert,
        createdAt: existing?.createdAt ?? obligation.createdAt,
        updatedAt: timestamp,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ObligationRecord>> allActive() async {
    final rows = await _db.query(
      'obligations',
      where: 'review_status != ?',
      whereArgs: [ObligationReviewStatus.dismissed.storageValue],
      orderBy: 'merchant_norm ASC, id ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<ObligationRecord?> byDedupeKey(String dedupeKey) async {
    final rows = await _db.query(
      'obligations',
      where: 'dedupe_key = ?',
      whereArgs: [dedupeKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.single);
  }

  Future<int> importLegacyManualEntries(
    List<ExpenseEntry> entries, {
    DateTime? now,
  }) async {
    var imported = 0;
    final timestamp = now ?? DateTime.now();
    for (final entry in entries) {
      final record = _fromLegacyEntry(entry, timestamp);
      if (await byDedupeKey(record.dedupeKey) != null) {
        continue;
      }
      await upsert(record, now: timestamp);
      imported++;
    }
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
