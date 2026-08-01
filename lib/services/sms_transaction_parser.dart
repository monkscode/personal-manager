import '../core/money.dart';
import '../data/sms_models.dart';
import 'sms_ingestion_policy.dart';
import 'sms_privacy.dart';

class SmsTransactionParser {
  const SmsTransactionParser();

  static const _knownBankFragments = [
    'hdfc',
    'icici',
    'sbi',
    'axis',
    'kotak',
    'yesbank',
    'idfc',
    'indusind',
    'federal',
    'canara',
    'pnb',
  ];

  static const _upiHandles = [
    'okhdfcbank',
    'oksbi',
    'okicici',
    'ybl',
    'paytm',
    'axl',
    'ibl',
    'upi',
  ];

  static final RegExp _knownBankBody = RegExp(
    r'\b(?:hdfc|icici|sbi|axis|kotak|yesbank|idfc|indusind|federal|canara|pnb)\b',
  );
  static final RegExp _amount = RegExp(
    r'(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]+)?)',
    caseSensitive: false,
  );
  static final RegExp _account = RegExp(
    r'\b(?:a/c|ac|acct|account|ending)\s*(?:no\.?\s*)?[*xX]*(\d{4})\b',
    caseSensitive: false,
  );
  static final RegExp _cardEnding = RegExp(
    r'\bcard\s+ending\s+(\d{4})\b',
    caseSensitive: false,
  );
  static final RegExp _ref = RegExp(
    r'\b(?:upi\s*)?(?:ref(?:erence)?|rrn|txn(?:\s*id)?|transaction\s*id)\s*[:#-]?\s*([A-Za-z0-9]{6,})',
    caseSensitive: false,
  );
  static final RegExp _vpa = RegExp(
    r'\b[A-Za-z0-9._-]+@[A-Za-z][A-Za-z0-9._-]+\b',
  );

  // Direction verbs. Debit precedence: when both a debit and a credit verb
  // appear, debit wins unless the credit verb is an explicit inflow
  // (refund/reversal/repayment) — money genuinely returning to the holder.
  static final RegExp _debitVerb = RegExp(
    r'\bdebited\b|\bdeducted\b|\bspent\b|\bpaid\b|\bcharged\b|\bpurchased\b|\bsent to\b|\bwithdrawn\b',
  );
  static final RegExp _creditVerb = RegExp(
    r'\bcredited\b|\bdeposited\b|\breceived\b|\brefund(?:ed)?\b|\breversed\b|\brepayment\b',
  );
  static final RegExp _explicitInflow = RegExp(
    r'\brefund(?:ed)?\b|\breversed\b|\brepayment\b',
  );
  // A balance/limit phrase immediately before an amount marks that amount as a
  // balance (not the transaction value). Anchored to the end of the preceding
  // window so only an adjacent phrase counts.
  static final RegExp _balancePrefix = RegExp(
    r'(?:avl\.?\s*bal|available\s+balance|a/c\s+bal|ac\s+bal|updated\s+balance|available\s+credit(?:\s+limit)?|available\s+limit|credit\s+limit|card\s+limit)\s*(?:is|:)?\s*$',
    caseSensitive: false,
  );
  // Verbs used to pick which of several amounts is the transaction amount.
  static final RegExp _txnVerb = RegExp(
    r'debited|credited|spent|paid|deducted|charged|purchased|deposited|received|withdrawn|sent',
  );

  ParsedTxn? parseOne(
    RawSms sms, {
    required String scanBatchId,
    required String bodyHashSalt,
  }) {
    final body = sms.body;
    final lower = body.toLowerCase();
    if (!_isStrictBankSms(sms.sender, lower)) return null;
    if (_isOtpOrPromo(lower)) return null;

    final amount = _extractAmount(body, lower);
    final amountPaise = amount.paise;
    final accountLast4 =
        _account.firstMatch(body)?.group(1) ??
        _cardEnding.firstMatch(body)?.group(1);
    final refNumber = _ref.firstMatch(body)?.group(1);
    final hasKnownBankSender = _isKnownBankSender(sms.sender);
    final balancePaise = _extractBalancePaise(body, lower);
    final upiVpa = _extractUpiVpa(body);
    final signals = [
      amountPaise != null,
      accountLast4 != null,
      balancePaise != null,
      refNumber != null,
      hasKnownBankSender,
    ].where((v) => v).length;
    if (amountPaise == null || signals < 2) return null;

    final direction = _direction(lower);
    if (direction == null) return null;

    final instrument = _instrument(lower);
    final type = _type(lower, upiVpa);
    final merchant = _merchant(lower, upiVpa, instrument);
    final categoryKey = _category(lower, merchant);
    final confidence = _confidence(
      hasKnownBankSender: hasKnownBankSender,
      hasUpi: type == TxnType.upi,
      hasMerchant: merchant != null,
      body: body,
    );

    // A parser-uncertain row is kept but always routed to review, even at high
    // confidence, so an ambiguous amount is never silently auto-added.
    final needsReview =
        confidence < kAutoAddConfidenceThreshold || amount.uncertain;
    final reviewReason = amount.uncertain
        ? ReviewReason.parserUncertain
        : (confidence < kAutoAddConfidenceThreshold
              ? ReviewReason.lowConfidence
              : null);

    return ParsedTxn(
      smsId: SmsPrivacy.stableSmsId(sms, salt: bodyHashSalt),
      sender: sms.sender,
      direction: direction,
      instrument: instrument,
      type: type,
      amountPaise: amountPaise,
      txnDate: sms.receivedAt,
      accountLast4: accountLast4,
      merchant: merchant,
      upiVpaNorm: upiVpa,
      payeeType: _payeeType(upiVpa),
      categoryKey: categoryKey,
      confidence: confidence,
      reviewStatus: needsReview
          ? ReviewStatus.needsReview
          : ReviewStatus.autoAdded,
      reviewReason: reviewReason,
      source: TxnSource.sms,
      refNumber: refNumber,
      balancePaise: balancePaise,
      coverageBucket: needsReview
          ? CoverageBucket.reviewPending
          : CoverageBucket.datedEvent,
      rawBodyRedacted: SmsPrivacy.redactBody(body),
      bodyHash: SmsPrivacy.bodyHash(body, salt: bodyHashSalt),
      scanBatchId: scanBatchId,
    );
  }

  bool _isStrictBankSms(String sender, String lower) {
    return _isKnownBankSender(sender) ||
        (_knownBankBody.hasMatch(lower) && _amount.hasMatch(lower));
  }

  bool _isKnownBankSender(String sender) {
    final normalized = sender.toLowerCase();
    return _knownBankFragments.any(normalized.contains);
  }

  bool _isOtpOrPromo(String lower) {
    final otp = RegExp(r'\botp\b|\bone\s*time\s*password\b').hasMatch(lower);
    final promo =
        RegExp(
          r'\boffer\b|\bcashback offer\b|\bdiscount\b|\bsale\b',
        ).hasMatch(lower) &&
        !RegExp(
          r'\bdebited\b|\bcredited\b|\bspent\b|\bpaid\b|\bcharged\b',
        ).hasMatch(lower);
    return otp || promo;
  }

  _AmountResult _extractAmount(String body, String lower) {
    final matches = _amount.allMatches(body).toList();
    if (matches.isEmpty) return const _AmountResult(null);

    final nonBalance = matches
        .where((match) => !_precededByBalanceKeyword(lower, match.start))
        .toList();
    if (nonBalance.isEmpty) return const _AmountResult(null);
    if (nonBalance.length == 1) {
      return _AmountResult(
        MoneyParser.tryParseRupeesToPaise(nonBalance.single.group(0)!),
      );
    }

    // Multiple non-balance candidates: prefer the one adjacent to a transaction
    // verb. A single adjacency winner is used; otherwise the row is flagged
    // parser-uncertain (kept, but sent to review) instead of guessing.
    final verbAdjacent = nonBalance
        .where((match) => _verbAdjacent(lower, match))
        .toList();
    if (verbAdjacent.length == 1) {
      return _AmountResult(
        MoneyParser.tryParseRupeesToPaise(verbAdjacent.single.group(0)!),
      );
    }
    return _AmountResult(
      MoneyParser.tryParseRupeesToPaise(nonBalance.first.group(0)!),
      uncertain: true,
    );
  }

  bool _precededByBalanceKeyword(String lower, int amountStart) {
    final windowStart = amountStart < 32 ? 0 : amountStart - 32;
    return _balancePrefix.hasMatch(lower.substring(windowStart, amountStart));
  }

  bool _verbAdjacent(String lower, RegExpMatch match) {
    const window = 12;
    final beforeStart = match.start < window ? 0 : match.start - window;
    final afterEnd = match.end + window > lower.length
        ? lower.length
        : match.end + window;
    final before = lower.substring(beforeStart, match.start);
    final after = lower.substring(match.end, afterEnd);
    return _txnVerb.hasMatch(before) || _txnVerb.hasMatch(after);
  }

  int? _extractBalancePaise(String body, String lower) {
    if (RegExp(
      r'available credit|available limit|credit limit|card limit',
    ).hasMatch(lower)) {
      return null;
    }
    final balanceKeyword = RegExp(
      r'(?:avl bal|available balance|a/c bal|ac bal|updated balance)\s*(?:is|:)?\s*',
      caseSensitive: false,
    );
    final match = balanceKeyword.firstMatch(body);
    if (match == null) return null;
    final amountMatch = _amount.firstMatch(body.substring(match.end));
    if (amountMatch == null) return null;
    return MoneyParser.tryParseRupeesToPaise(amountMatch.group(0)!);
  }

  String? _extractUpiVpa(String body) {
    for (final match in _vpa.allMatches(body)) {
      final value = match.group(0)!.toLowerCase();
      final handle = value.split('@').last;
      if (_upiHandles.contains(handle)) return value;
    }
    return null;
  }

  TransactionDirection? _direction(String lower) {
    final hasDebit = _debitVerb.hasMatch(lower);
    final hasCredit = _creditVerb.hasMatch(lower);
    if (hasDebit && hasCredit) {
      // Both signals present: debit wins unless an explicit inflow verb
      // (refund/reversal/repayment) shows money returning to the holder.
      return _explicitInflow.hasMatch(lower)
          ? TransactionDirection.credit
          : TransactionDirection.debit;
    }
    if (hasCredit) return TransactionDirection.credit;
    if (hasDebit) return TransactionDirection.debit;
    return null;
  }

  PaymentInstrument _instrument(String lower) {
    return RegExp(
          r'\bcredit card\b|\bcard ending\b|\bavailable credit\b|\bcredit limit\b',
        ).hasMatch(lower)
        ? PaymentInstrument.card
        : PaymentInstrument.bank;
  }

  TxnType _type(String lower, String? upiVpa) {
    if (upiVpa != null || lower.contains('upi')) return TxnType.upi;
    if (lower.contains('atm')) return TxnType.atm;
    if (lower.contains('neft') ||
        lower.contains('imps') ||
        lower.contains('transfer')) {
      return TxnType.transfer;
    }
    if (lower.contains('pos') || lower.contains('card')) return TxnType.pos;
    return TxnType.other;
  }

  String? _merchant(
    String lower,
    String? upiVpa,
    PaymentInstrument instrument,
  ) {
    if (upiVpa != null) return upiVpa.split('@').first;
    final atMatch = RegExp(
      r'\bat\s+([a-z0-9 &._-]{2,40})(?:\.|,|$)',
    ).firstMatch(lower);
    if (atMatch != null) return atMatch.group(1)!.trim();
    return instrument == PaymentInstrument.card ? 'card purchase' : null;
  }

  PayeeType _payeeType(String? upiVpa) {
    if (upiVpa == null) return PayeeType.unknown;
    final payee = upiVpa.split('@').first;
    return RegExp(
          r'swiggy|zomato|amazon|uber|paytm|merchant|store',
        ).hasMatch(payee)
        ? PayeeType.merchant
        : PayeeType.p2pIndividual;
  }

  String _category(String lower, String? merchant) {
    final haystack = '$lower ${merchant ?? ''}';
    if (RegExp(
      r'swiggy|zomato|bigbasket|blinkit|grocery|restaurant',
    ).hasMatch(haystack)) {
      return 'groceries';
    }
    if (RegExp(r'uber|ola|fuel|petrol|metro|toll').hasMatch(haystack)) {
      return 'transport';
    }
    if (RegExp(r'netflix|spotify|subscription|prime').hasMatch(haystack)) {
      return 'subscriptions';
    }
    if (RegExp(r'electricity|broadband|utility|gas').hasMatch(haystack)) {
      return 'utilities';
    }
    if (RegExp(r'rent|housing|maintenance').hasMatch(haystack)) {
      return 'housing';
    }
    if (RegExp(r'insurance|premium|policy').hasMatch(haystack)) {
      return 'insurance';
    }
    return 'other';
  }

  double _confidence({
    required bool hasKnownBankSender,
    required bool hasUpi,
    required bool hasMerchant,
    required String body,
  }) {
    var confidence = 0.5;
    if (hasKnownBankSender) confidence += 0.3;
    confidence += 0.1;
    if (hasUpi) confidence += 0.05;
    if (hasMerchant) confidence += 0.1;
    if (body.length < 30) confidence -= 0.1;
    return confidence.clamp(0, 1);
  }
}

/// The chosen transaction amount plus whether the choice was ambiguous (two or
/// more equally plausible non-balance candidates), in which case the row is
/// kept but routed to review as [ReviewReason.parserUncertain].
class _AmountResult {
  const _AmountResult(this.paise, {this.uncertain = false});

  final int? paise;
  final bool uncertain;
}
