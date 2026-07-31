import 'forecast_models.dart';
import 'sms_models.dart';

enum ObligationSourceType { gmail, smsRecurring, manual, configuredPlan }

enum ObligationReviewStatus { confirmed, needsReview, dismissed }

extension ObligationReviewStatusStorage on ObligationReviewStatus {
  String get storageValue => switch (this) {
    ObligationReviewStatus.confirmed => 'confirmed',
    ObligationReviewStatus.needsReview => 'needs_review',
    ObligationReviewStatus.dismissed => 'dismissed',
  };
}

extension ObligationSourceTypeStorage on ObligationSourceType {
  String get storageValue => switch (this) {
    ObligationSourceType.gmail => 'gmail',
    ObligationSourceType.smsRecurring => 'sms_recurring',
    ObligationSourceType.manual => 'manual',
    ObligationSourceType.configuredPlan => 'configured_plan',
  };
}

enum NextExpectedSource { explicitDueDate, lockedCadence, userEntered, unknown }

extension NextExpectedSourceStorage on NextExpectedSource {
  String get storageValue => switch (this) {
    NextExpectedSource.explicitDueDate => 'explicit_due_date',
    NextExpectedSource.lockedCadence => 'locked_cadence',
    NextExpectedSource.userEntered => 'user_entered',
    NextExpectedSource.unknown => 'unknown',
  };
}

extension AccountScopeStorage on AccountScope {
  String get storageValue => switch (this) {
    AccountScope.primary => 'primary',
    AccountScope.secondary => 'secondary',
    AccountScope.unknown => 'unknown',
  };
}

extension ReconciliationPaymentStatusStorage on ReconciliationPaymentStatus {
  String get storageValue => switch (this) {
    ReconciliationPaymentStatus.unpaid => 'unpaid',
    ReconciliationPaymentStatus.paid => 'paid',
    ReconciliationPaymentStatus.partial => 'partial',
    ReconciliationPaymentStatus.possiblyPaid => 'possibly_paid',
    ReconciliationPaymentStatus.outOfPrimaryScope => 'out_of_primary_scope',
  };
}

extension UserCadenceStatusStorage on UserCadenceStatus {
  String get storageValue => switch (this) {
    UserCadenceStatus.algorithmDetected => 'algorithm_detected',
    UserCadenceStatus.userConfirmed => 'user_confirmed',
    UserCadenceStatus.userDismissed => 'user_dismissed',
  };
}

class ObligationRecord {
  const ObligationRecord({
    required this.sourceType,
    required this.dedupeKey,
    required this.merchant,
    required this.merchantNorm,
    required this.categoryKey,
    required this.amountStatus,
    required this.recurrence,
    required this.paymentAccountScope,
    required this.paymentStatus,
    required this.nextExpectedSource,
    required this.payeeType,
    required this.userCadenceStatus,
    required this.confidence,
    required this.reviewStatus,
    required this.createdAt,
    required this.updatedAt,
    this.id,
    this.sourceId,
    this.amountPaise,
    this.dueDate,
    this.dueDay,
    this.dueMonth,
    this.paymentAccountHintLast4,
    this.amountPaidPaise,
    this.outstandingPaise,
    this.upiVpaNorm,
    this.reserveEnabled = false,
    this.reserveFundedPaise = 0,
  }) : assert(amountPaise == null || amountPaise >= 0),
       assert(reserveFundedPaise >= 0),
       assert(confidence >= 0 && confidence <= 1);

  final int? id;
  final ObligationSourceType sourceType;
  final String? sourceId;
  final String dedupeKey;
  final String merchant;
  final String merchantNorm;
  final String categoryKey;
  final int? amountPaise;
  final AmountStatus amountStatus;
  final ReconciliationRecurrence recurrence;
  final DateTime? dueDate;
  final int? dueDay;
  final int? dueMonth;
  final String? paymentAccountHintLast4;
  final AccountScope paymentAccountScope;
  final int? amountPaidPaise;
  final int? outstandingPaise;
  final ReconciliationPaymentStatus paymentStatus;
  final NextExpectedSource nextExpectedSource;
  final String? upiVpaNorm;
  final PayeeType payeeType;
  final UserCadenceStatus userCadenceStatus;
  final double confidence;
  final ObligationReviewStatus reviewStatus;
  final bool reserveEnabled;
  final int reserveFundedPaise;
  final DateTime createdAt;
  final DateTime updatedAt;

  ObligationRecord copyWith({
    int? id,
    ObligationSourceType? sourceType,
    String? sourceId,
    String? dedupeKey,
    String? merchant,
    String? merchantNorm,
    String? categoryKey,
    int? amountPaise,
    AmountStatus? amountStatus,
    ReconciliationRecurrence? recurrence,
    DateTime? dueDate,
    int? dueDay,
    int? dueMonth,
    String? paymentAccountHintLast4,
    AccountScope? paymentAccountScope,
    int? amountPaidPaise,
    int? outstandingPaise,
    ReconciliationPaymentStatus? paymentStatus,
    NextExpectedSource? nextExpectedSource,
    String? upiVpaNorm,
    PayeeType? payeeType,
    UserCadenceStatus? userCadenceStatus,
    double? confidence,
    ObligationReviewStatus? reviewStatus,
    bool? reserveEnabled,
    int? reserveFundedPaise,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ObligationRecord(
      id: id ?? this.id,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      dedupeKey: dedupeKey ?? this.dedupeKey,
      merchant: merchant ?? this.merchant,
      merchantNorm: merchantNorm ?? this.merchantNorm,
      categoryKey: categoryKey ?? this.categoryKey,
      amountPaise: amountPaise ?? this.amountPaise,
      amountStatus: amountStatus ?? this.amountStatus,
      recurrence: recurrence ?? this.recurrence,
      dueDate: dueDate ?? this.dueDate,
      dueDay: dueDay ?? this.dueDay,
      dueMonth: dueMonth ?? this.dueMonth,
      paymentAccountHintLast4:
          paymentAccountHintLast4 ?? this.paymentAccountHintLast4,
      paymentAccountScope: paymentAccountScope ?? this.paymentAccountScope,
      amountPaidPaise: amountPaidPaise ?? this.amountPaidPaise,
      outstandingPaise: outstandingPaise ?? this.outstandingPaise,
      paymentStatus: paymentStatus ?? this.paymentStatus,
      nextExpectedSource: nextExpectedSource ?? this.nextExpectedSource,
      upiVpaNorm: upiVpaNorm ?? this.upiVpaNorm,
      payeeType: payeeType ?? this.payeeType,
      userCadenceStatus: userCadenceStatus ?? this.userCadenceStatus,
      confidence: confidence ?? this.confidence,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      reserveEnabled: reserveEnabled ?? this.reserveEnabled,
      reserveFundedPaise: reserveFundedPaise ?? this.reserveFundedPaise,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
