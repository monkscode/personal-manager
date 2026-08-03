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
    this.skippedCount = 0,
    this.message,
  });

  /// A scan that read every message the inbox offered.
  ///
  /// [skippedCount] is how many messages the scan knew about but never read —
  /// normally zero. It exists because a truncated read may **not** be reported
  /// as a plain success: the spec's "no silent exclusion" invariant requires
  /// anything dropped to be nameable in a coverage line. TASK-33 is the case
  /// that forced it — the reader was silently returning the newest 1,000
  /// messages of an 11,596-message inbox and calling it a success.
  factory SmsScanOutcome.success(
    List<RawSms> messages, {
    int skippedCount = 0,
  }) {
    if (skippedCount < 0) {
      throw ArgumentError.value(
        skippedCount,
        'skippedCount',
        'must not be negative',
      );
    }
    return SmsScanOutcome._(
      status: SmsScanStatus.success,
      messages: List.unmodifiable(messages),
      skippedCount: skippedCount,
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

  /// Messages counted in the inbox but never read. Non-zero means the result
  /// is partial and must say so downstream.
  final int skippedCount;
  final String? message;

  bool get isSuccess => status == SmsScanStatus.success;

  /// Whether the scan read everything it counted. A successful scan can still
  /// be incomplete; only both together mean "the whole inbox is in here".
  bool get isComplete => skippedCount == 0;
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

enum PayeeType {
  merchant,
  p2pIndividual,
  selfTransfer,
  wallet,

  /// A bank or clearing house standing in as the payee of a NACH/ACH mandate
  /// (`HDFC BANK LTD`, `Indian Clearing Corporation Lt`). It is a real
  /// originator and keeps its owner key so the rupee is attributed, but it is
  /// not a shop and must never be shown to the user as one (TASK-31).
  bankMandate,
  unknown,
}

extension PayeeTypeStorage on PayeeType {
  String get storageValue => switch (this) {
    PayeeType.merchant => 'merchant',
    PayeeType.p2pIndividual => 'p2p_individual',
    PayeeType.selfTransfer => 'self_transfer',
    PayeeType.wallet => 'wallet',
    PayeeType.bankMandate => 'bank_mandate',
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

/// The future tense that marks a bank message as an *announcement* of money
/// about to move rather than a record of money that moved.
///
/// Single source of truth, read at two moments. The parser consults it at write
/// time so a notice is never stored as an actual (TASK-32); the read paths
/// consult it via [ParsedTxnFutureNotice.isFutureDebitNotice] so the rows
/// already on disk — 30 of them on the author's device, ₹86,304, 26
/// user-confirmed — stop double-counting without anything being deleted.
///
/// It previously existed twice, as this regex in the parser and as a shorter
/// substring list in `real_insights`, which is why the estimator and the
/// recurring detector never saw the exclusion at all.
final RegExp kFutureDebitNoticePattern = RegExp(
  r'\bwill be (?:debited|credited|deducted)\b'
  r'|\bis due on\b'
  r'|\bdue for payment\b'
  r'|\bscheduled for\b'
  r'|\bupcoming mandate\b'
  r'|\bmandate set for\b',
  caseSensitive: false,
);

/// A debit the bank has *announced* but not yet executed — an upcoming NACH
/// mandate, an e-mandate pre-notice, or a card-bill auto-debit reminder.
///
/// It is deliberately **not** a [ParsedTxn]. The money has not moved, and the
/// real debit alert arrives days later; storing both counts the same rupee
/// twice (TASK-32, measured at 30 rows / ₹86,304 on a real device). What the
/// notice does carry — a payee, an amount and an explicit date — is exactly an
/// obligation, so it is routed there instead of being dropped.
class FutureDebitNotice {
  const FutureDebitNotice({
    required this.smsId,
    required this.sender,
    required this.amountPaise,
    required this.dueDate,
    required this.categoryKey,
    this.payee,
    this.accountLast4,
  }) : assert(amountPaise > 0);

  final String smsId;
  final String sender;
  final int amountPaise;

  /// The date the notice names for the debit, not the date it arrived.
  final DateTime dueDate;
  final String categoryKey;

  /// The named payee, lower-cased. Null when the body announces a debit but
  /// names nobody — the notice is still emitted so the amount is not silently
  /// excluded, but it cannot form an owner key.
  final String? payee;
  final String? accountLast4;
}

/// What one SMS yielded: a completed transaction, a future-dated notice, or
/// neither. Exactly one of [txn] and [notice] is ever non-null.
class SmsParseResult {
  const SmsParseResult({this.txn, this.notice});

  const SmsParseResult.none() : txn = null, notice = null;

  final ParsedTxn? txn;
  final FutureDebitNotice? notice;
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

extension ParsedTxnFutureNotice on ParsedTxn {
  /// Whether this stored row is really a bank *announcement* of a future debit
  /// rather than a completed one.
  ///
  /// Re-derived from the redacted body at read time, exactly like the
  /// cash-withdrawal and credit-card-purchase checks in `real_insights`, so it
  /// corrects rows written before the parser learned to route notices to
  /// obligations — without deleting a row the user has confirmed.
  bool get isFutureDebitNotice =>
      kFutureDebitNoticePattern.hasMatch(rawBodyRedacted);
}
