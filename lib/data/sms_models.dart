enum SmsScanStatus {
  success,
  unsupportedPlatform,
  permissionDenied,
  permissionPermanentlyDenied,
  failed,
}

extension SmsScanStatusStorage on SmsScanStatus {
  String get storageValue => switch (this) {
    SmsScanStatus.success => 'success',
    SmsScanStatus.unsupportedPlatform => 'unsupportedPlatform',
    SmsScanStatus.permissionDenied => 'permissionDenied',
    SmsScanStatus.permissionPermanentlyDenied => 'permissionPermanentlyDenied',
    SmsScanStatus.failed => 'failed',
  };
}

class SmsScanOutcome {
  const SmsScanOutcome._({
    required this.status,
    required this.messages,
    this.message,
  });

  factory SmsScanOutcome.success(List<RawSms> messages) {
    return SmsScanOutcome._(
      status: SmsScanStatus.success,
      messages: List.unmodifiable(messages),
    );
  }

  factory SmsScanOutcome.failure(SmsScanStatus status, {String? message}) {
    if (status == SmsScanStatus.success) {
      throw ArgumentError.value(
        status,
        'status',
        'Failure status cannot be success',
      );
    }
    return SmsScanOutcome._(
      status: status,
      messages: const [],
      message: message,
    );
  }

  final SmsScanStatus status;
  final List<RawSms> messages;
  final String? message;

  bool get isSuccess => status == SmsScanStatus.success;
}

class RawSms {
  const RawSms({
    required this.sender,
    required this.body,
    required this.receivedAt,
    this.providerId,
  });

  final String? providerId;
  final String sender;
  final String body;
  final DateTime receivedAt;
}

enum TransactionDirection { debit, credit }

extension TransactionDirectionStorage on TransactionDirection {
  String get storageValue => switch (this) {
    TransactionDirection.debit => 'debit',
    TransactionDirection.credit => 'credit',
  };
}

enum PaymentInstrument { bank, card }

extension PaymentInstrumentStorage on PaymentInstrument {
  String get storageValue => switch (this) {
    PaymentInstrument.bank => 'bank',
    PaymentInstrument.card => 'card',
  };
}

enum TxnType { upi, atm, pos, transfer, other }

extension TxnTypeStorage on TxnType {
  String get storageValue => switch (this) {
    TxnType.upi => 'upi',
    TxnType.atm => 'atm',
    TxnType.pos => 'pos',
    TxnType.transfer => 'transfer',
    TxnType.other => 'other',
  };
}

enum PayeeType { merchant, p2pIndividual, selfTransfer, wallet, unknown }

extension PayeeTypeStorage on PayeeType {
  String get storageValue => switch (this) {
    PayeeType.merchant => 'merchant',
    PayeeType.p2pIndividual => 'p2p_individual',
    PayeeType.selfTransfer => 'self_transfer',
    PayeeType.wallet => 'wallet',
    PayeeType.unknown => 'unknown',
  };
}

enum ReviewStatus { confirmed, autoAdded, needsReview, dismissed }

extension ReviewStatusStorage on ReviewStatus {
  String get storageValue => switch (this) {
    ReviewStatus.confirmed => 'confirmed',
    ReviewStatus.autoAdded => 'auto_added',
    ReviewStatus.needsReview => 'needs_review',
    ReviewStatus.dismissed => 'dismissed',
  };
}

enum ReviewReason {
  firstScan,
  lowConfidence,
  dedupCollision,
  parserUncertain,
  userFlagged,
}

extension ReviewReasonStorage on ReviewReason {
  String get storageValue => switch (this) {
    ReviewReason.firstScan => 'first_scan',
    ReviewReason.lowConfidence => 'low_confidence',
    ReviewReason.dedupCollision => 'dedup_collision',
    ReviewReason.parserUncertain => 'parser_uncertain',
    ReviewReason.userFlagged => 'user_flagged',
  };
}

enum TxnSource { sms, manual }

extension TxnSourceStorage on TxnSource {
  String get storageValue => switch (this) {
    TxnSource.sms => 'sms',
    TxnSource.manual => 'manual',
  };
}

enum CoverageBucket {
  anchorIncluded,
  datedEvent,
  quantifiedExcluded,
  reviewPending,
}

extension CoverageBucketStorage on CoverageBucket {
  String get storageValue => switch (this) {
    CoverageBucket.anchorIncluded => 'anchor_included',
    CoverageBucket.datedEvent => 'dated_event',
    CoverageBucket.quantifiedExcluded => 'quantified_excluded',
    CoverageBucket.reviewPending => 'review_pending',
  };
}

class ParsedTxn {
  ParsedTxn({
    required this.smsId,
    required this.sender,
    required this.direction,
    required this.instrument,
    required this.type,
    required this.amountPaise,
    required this.txnDate,
    required this.payeeType,
    required this.categoryKey,
    required this.confidence,
    required this.reviewStatus,
    required this.source,
    required this.coverageBucket,
    required this.rawBodyRedacted,
    required this.bodyHash,
    required this.scanBatchId,
    this.effectiveMonth,
    this.accountLast4,
    this.merchant,
    this.upiVpaNorm,
    this.reviewReason,
    this.autoAddedAt,
    this.collisionSetId,
    this.refNumber,
    this.balancePaise,
    this.ownerKey,
  }) : txnLocalDate = _localDate(txnDate),
       txnMonth = _localMonth(txnDate);

  final String smsId;
  final String sender;
  final TransactionDirection direction;
  final PaymentInstrument instrument;
  final TxnType type;
  final int amountPaise;
  final DateTime txnDate;
  final String txnLocalDate;
  final String txnMonth;
  final String? effectiveMonth;
  final String? accountLast4;
  final String? merchant;
  final String? upiVpaNorm;
  final PayeeType payeeType;
  final String categoryKey;
  final double confidence;
  final ReviewStatus reviewStatus;
  final ReviewReason? reviewReason;
  final DateTime? autoAddedAt;
  final String? collisionSetId;
  final TxnSource source;
  final String? refNumber;
  final int? balancePaise;
  final String? ownerKey;
  final CoverageBucket coverageBucket;
  final String rawBodyRedacted;
  final String bodyHash;
  final String scanBatchId;

  bool get needsReview => reviewStatus == ReviewStatus.needsReview;

  /// This freshly-parsed row, carrying [stored]'s review decision.
  ///
  /// Used when a message that is already in the table is parsed again: the
  /// derived fields (direction, amount, merchant, instrument, category …) come
  /// from *this* parse, because the parser has since been corrected, while
  /// everything the user decided comes from the stored row.
  ///
  /// Deliberately not [copyWith]: that resolves every argument with `?? this.x`
  /// and so cannot copy a **null** across. A row the user confirmed has a null
  /// `reviewReason`, and a `copyWith`-based merge would leave the fresh parse's
  /// `parserUncertain` in place and drag a resolved row back into the review
  /// queue. Every decision field here is assigned unconditionally.
  ///
  /// `scanBatchId` is [stored]'s: it records when the message was first seen,
  /// which a re-parse does not change.
  ParsedTxn withDecisionsFrom(ParsedTxn stored) => ParsedTxn(
    smsId: smsId,
    sender: sender,
    direction: direction,
    instrument: instrument,
    type: type,
    amountPaise: amountPaise,
    txnDate: txnDate,
    payeeType: payeeType,
    categoryKey: categoryKey,
    confidence: confidence,
    source: source,
    rawBodyRedacted: rawBodyRedacted,
    bodyHash: bodyHash,
    effectiveMonth: effectiveMonth,
    accountLast4: accountLast4,
    merchant: merchant,
    upiVpaNorm: upiVpaNorm,
    refNumber: refNumber,
    balancePaise: balancePaise,
    ownerKey: ownerKey,
    // --- the user's, not the parser's ---
    reviewStatus: stored.reviewStatus,
    reviewReason: stored.reviewReason,
    autoAddedAt: stored.autoAddedAt,
    collisionSetId: stored.collisionSetId,
    coverageBucket: stored.coverageBucket,
    scanBatchId: stored.scanBatchId,
  );

  /// Whether a re-parse of the same message actually changed anything the
  /// parser derives. Keeps a rescan that found no corrections from rewriting
  /// every row it touches.
  bool hasSameParseAs(ParsedTxn other) =>
      direction == other.direction &&
      instrument == other.instrument &&
      type == other.type &&
      amountPaise == other.amountPaise &&
      txnLocalDate == other.txnLocalDate &&
      accountLast4 == other.accountLast4 &&
      merchant == other.merchant &&
      upiVpaNorm == other.upiVpaNorm &&
      payeeType == other.payeeType &&
      categoryKey == other.categoryKey &&
      confidence == other.confidence &&
      refNumber == other.refNumber &&
      balancePaise == other.balancePaise;

  ParsedTxn copyWith({
    ReviewStatus? reviewStatus,
    ReviewReason? reviewReason,
    DateTime? autoAddedAt,
    String? collisionSetId,
    CoverageBucket? coverageBucket,
    String? merchant,
    String? categoryKey,
    String? upiVpaNorm,
  }) {
    return ParsedTxn(
      smsId: smsId,
      sender: sender,
      direction: direction,
      instrument: instrument,
      type: type,
      amountPaise: amountPaise,
      txnDate: txnDate,
      payeeType: payeeType,
      categoryKey: categoryKey ?? this.categoryKey,
      confidence: confidence,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      source: source,
      coverageBucket: coverageBucket ?? this.coverageBucket,
      rawBodyRedacted: rawBodyRedacted,
      bodyHash: bodyHash,
      scanBatchId: scanBatchId,
      effectiveMonth: effectiveMonth,
      accountLast4: accountLast4,
      merchant: merchant ?? this.merchant,
      upiVpaNorm: upiVpaNorm ?? this.upiVpaNorm,
      reviewReason: reviewReason ?? this.reviewReason,
      autoAddedAt: autoAddedAt ?? this.autoAddedAt,
      collisionSetId: collisionSetId ?? this.collisionSetId,
      refNumber: refNumber,
      balancePaise: balancePaise,
      ownerKey: ownerKey,
    );
  }

  static String _localDate(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String _localMonth(DateTime date) {
    final local = date.toLocal();
    return '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}';
  }
}
