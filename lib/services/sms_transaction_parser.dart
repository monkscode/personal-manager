import '../core/clamped_date.dart';
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
  // The optional `no` absorbs both SBI's `Refno 5012...` and the spaced
  // `Ref no. 5012...`; without it the digits are read as part of the keyword
  // and no reference is captured at all.
  static final RegExp _ref = RegExp(
    r'\b(?:upi\s*)?(?:ref(?:erence)?\s*(?:no\.?)?|rrn|txn(?:\s*id)?|transaction\s*id)\s*[:#-]?\s*([A-Za-z0-9]{6,})',
    caseSensitive: false,
  );
  static final RegExp _vpa = RegExp(
    r'\b[A-Za-z0-9._-]+@[A-Za-z][A-Za-z0-9._-]+\b',
  );
  // Lazy and terminator-aware, mirroring `merchant_display._merchantFromBody`.
  // A greedy class that admits `.`, `-` and space runs straight past the name
  // and swallows the date, the balance and the helpline number after it — and
  // that garbage then buys confidence and masquerades as a distinguishing
  // signal in the ingestion policy.
  static final RegExp _merchantAt = RegExp(
    r'\bat\s+(.{2,40}?)(?:\s+on\s+\d|\s+at\s|\s+to\s|\s+from\s|\s+ref\b|\s+avl\b|\s+available\b|\s+bal\b|\.(?:\s|$)|\n|$)',
  );
  // A bank account has no limit, so any available/credit-limit phrasing is by
  // itself card evidence. `bank card` and a bare `card <tail>` cover HDFC's
  // "on HDFC Bank Card XX9012", which never says "credit card" at all.
  static final RegExp _cardMarker = RegExp(
    r'\bcredit card\b|\bcard ending\b|\bbank card\b|\bcard\s+[*x]*\d{4}\b|\bavailable credit\b|\bavailable limit\b|\bavl lmt\b|\bcredit limit\b|\bcard limit\b',
  );

  // Direction verbs. `repayment` is a *debit*: in Indian bank SMS it is the
  // customer paying down a loan, so an EMI alert must not book as income.
  // Whole-message fallback precedence: when both a debit and a credit verb
  // appear, debit wins unless the credit verb is an explicit inflow
  // (refund/reversal) — money genuinely returning to the holder.
  // `sent` is bare rather than the literal `sent to`: HDFC's UPI debit alert
  // reads "Sent Rs.500.00 From ... To <vpa>", often across a line break, so the
  // two words are never adjacent. The lookahead keeps it off unrelated prose by
  // requiring a `to`/`from` to follow within the same clause.
  static final RegExp _debitVerb = RegExp(
    r'\bdebited\b|\bdeducted\b|\bspent\b|\bpaid\b|\bcharged\b|\bpurchased\b|\bwithdrawn\b|\brepayment\b|\bsent\b(?=[\s\S]{0,40}?\b(?:to|from)\b)',
  );
  static final RegExp _creditVerb = RegExp(
    r'\bcredited\b|\bdeposited\b|\breceived\b|\brefund(?:ed)?\b|\breversed\b',
  );
  static final RegExp _explicitInflow = RegExp(
    r'\brefund(?:ed)?\b|\breversed\b',
  );
  // A balance/limit phrase immediately before an amount marks that amount as a
  // balance (not the transaction value). Anchored to the end of the preceding
  // window so only an adjacent phrase counts.
  // The separator after the keyword may be `is`, `:` or a dash — Axis writes
  // `Avl Bal- INR 41000.00`, and without the dash the balance stays in the
  // candidate pool and every Axis debit lands in review forever.
  static final RegExp _balancePrefix = RegExp(
    r'(?:avl\.?\s*bal|available\s+balance|a/c\s+bal|ac\s+bal|updated\s+balance|available\s+credit(?:\s+limit)?|available\s+limit|credit\s+limit|card\s+limit)\s*(?:is|[:\-–])?\s*$',
    caseSensitive: false,
  );
  // Verbs used to pick which of several amounts is the transaction amount.
  static final RegExp _txnVerb = RegExp(
    r'debited|credited|spent|paid|deducted|charged|purchased|deposited|received|withdrawn|sent',
  );
  // How far either side of an amount counts as "beside" it — used both to pick
  // which amount is the transaction value and to find the verb governing it.
  // Wide enough for `debited with ` (13) to reach the amount it governs; at 12
  // the transaction amount failed its own adjacency test.
  static const int _adjacencyWindow = 24;
  // SBI's UPI alert carries no ₹/Rs/INR token at all ("debited by 1250.0"). A
  // bare number is read as money only when a transaction verb anchors it *and*
  // it carries decimals — that keeps dates (05Jan25), reference numbers and
  // years out of the candidate pool.
  static final RegExp _verbAnchoredAmount = RegExp(
    r'\b(?:debited|credited|deducted|withdrawn|deposited|spent|paid|charged|sent|received)\b\s*(?:by|for|with|of|amount|amt)?\s*([0-9][0-9,]*\.[0-9]{1,2})\b',
  );

  // Marketing vocabulary. A *strong* marker only ever appears in an offer, so
  // the message is not a transaction at all. A *weak* marker also shows up in
  // the promotional tail banks append to genuine alerts, so it is additive
  // rather than vetoed: it never cancels the promo signal, it forces the row to
  // review. Weak copy carrying no debit or credit verb is marketing on its own
  // and is rejected too.
  static final RegExp _strongPromoMarker = RegExp(
    r'\bpre[- ]?approved\b|\bapply now\b|\blimited period\b|\bloan offer\b|\bcongratulations\b',
  );
  static final RegExp _weakPromoMarker = RegExp(
    r'\boffer\b|\bdiscount\b|\bsale\b|\bexclusive\b|\bclick\b|\bt&c apply\b|\bknow more\b|\beligible for\b',
  );
  // A failed, declined or error-reversed notice describes money that never
  // moved. The optional "be" covers both "was not processed" and "could not be
  // processed"; "has been declined" is covered by the bare verb.
  static final RegExp _failureMarker = RegExp(
    r'\bfailed\b|\bdeclined\b|\bunsuccessful\b|\bnot (?:be )?processed\b|\breversed due to\b',
  );
  // A pre-notice announces money that has not moved yet. It is kept — an
  // AutoPay mandate is real obligation signal — but it may never become a dated
  // actual, or it double-counts when the real debit alert lands days later.
  // Vocabulary matches `_kFutureDebitNoticeMarkers` in `real_insights.dart`.
  static final RegExp _futureNoticeMarker = RegExp(
    r'\bwill be (?:debited|credited|deducted)\b|\bis due on\b|\bdue for payment\b|\bscheduled for\b|\bupcoming mandate\b|\bmandate set for\b',
  );
  // The date a pre-notice names for the debit: `on 05-Jul-25`, `on 11/08/26`,
  // `on 05 Jul 2025`.
  static final RegExp _statedDatePhrase = RegExp(
    r'\b(?:on|by|for)\s+(\d{1,2})[-/ ]([a-z]{3,9}|\d{1,2})[-/ ](\d{2}|\d{4})\b',
  );
  static const _monthByName = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  ParsedTxn? parseOne(
    RawSms sms, {
    required String scanBatchId,
    required String bodyHashSalt,
  }) {
    final body = sms.body;
    final lower = body.toLowerCase();
    if (!_isStrictBankSms(sms.sender, lower)) return null;
    if (_isOtp(lower)) return null;
    if (_failureMarker.hasMatch(lower)) return null;
    final promo = _promoSignal(lower);
    if (promo == _PromoSignal.reject) return null;

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

    final direction = _direction(lower, amount.start, amount.end);
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

    // A pre-notice is dated the day it announces, not the day it arrived, so
    // the row lines up with the real debit alert instead of landing days early.
    final isFutureNotice = _futureNoticeMarker.hasMatch(lower);
    final txnDate = isFutureNotice
        ? (_statedDate(lower) ?? sms.receivedAt)
        : sms.receivedAt;

    // A parser-uncertain row is kept but always routed to review, even at high
    // confidence, so an ambiguous amount, a promotional tail or money that has
    // not moved yet is never silently auto-added. The ingestion policy honours
    // this reason on every later scan, so the row can never be auto-added.
    final uncertain =
        amount.uncertain || isFutureNotice || promo == _PromoSignal.review;
    final needsReview = confidence < kAutoAddConfidenceThreshold || uncertain;
    final reviewReason = uncertain
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
      txnDate: txnDate,
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

  bool _isOtp(String lower) =>
      RegExp(r'\botp\b|\bone\s*time\s*password\b').hasMatch(lower);

  _PromoSignal _promoSignal(String lower) {
    if (_strongPromoMarker.hasMatch(lower)) return _PromoSignal.reject;
    if (!_weakPromoMarker.hasMatch(lower)) return _PromoSignal.none;
    final hasVerb = _debitVerb.hasMatch(lower) || _creditVerb.hasMatch(lower);
    return hasVerb ? _PromoSignal.review : _PromoSignal.reject;
  }

  /// The calendar date a future-tense notice names, or null when the body
  /// carries no readable one (the caller then falls back to the received date).
  DateTime? _statedDate(String lower) {
    final match = _statedDatePhrase.firstMatch(lower);
    if (match == null) return null;
    final monthText = match.group(2)!;
    final month =
        int.tryParse(monthText) ?? _monthByName[monthText.substring(0, 3)];
    if (month == null || month < 1 || month > 12) return null;
    final yearText = match.group(3)!;
    final year = yearText.length == 2
        ? 2000 + int.parse(yearText)
        : int.parse(yearText);
    if (year < 2000 || year > 2100) return null;
    return clampedDate(year, month, int.parse(match.group(1)!));
  }

  _AmountResult _extractAmount(String body, String lower) {
    final matches = _amount.allMatches(body).toList();
    // Only when the body names no currency at all is the bare-number fallback
    // tried; a body that *has* an ₹/Rs/INR amount but hides it behind a balance
    // keyword is still a no-amount body, not an invitation to guess.
    if (matches.isEmpty) return _bareAmount(lower);

    final nonBalance = matches
        .where((match) => !_precededByBalanceKeyword(lower, match.start))
        .toList();
    if (nonBalance.isEmpty) return const _AmountResult(null);
    if (nonBalance.length == 1) {
      return _AmountResult(
        MoneyParser.tryParseRupeesToPaise(nonBalance.single.group(0)!),
        start: nonBalance.single.start,
        end: nonBalance.single.end,
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
        start: verbAdjacent.single.start,
        end: verbAdjacent.single.end,
      );
    }
    return _AmountResult(
      MoneyParser.tryParseRupeesToPaise(nonBalance.first.group(0)!),
      start: nonBalance.first.start,
      end: nonBalance.first.end,
      uncertain: true,
    );
  }

  /// Amount for bodies that name no currency, taken only from a number a
  /// transaction verb is speaking about.
  _AmountResult _bareAmount(String lower) {
    final match = _verbAnchoredAmount.firstMatch(lower);
    if (match == null) return const _AmountResult(null);
    final text = match.group(1)!;
    final start = match.start + match.group(0)!.lastIndexOf(text);
    if (_precededByBalanceKeyword(lower, start)) return const _AmountResult(null);
    return _AmountResult(
      MoneyParser.tryParseRupeesToPaise(text),
      start: start,
      end: start + text.length,
    );
  }

  bool _precededByBalanceKeyword(String lower, int amountStart) {
    final windowStart = amountStart < 32 ? 0 : amountStart - 32;
    return _balancePrefix.hasMatch(lower.substring(windowStart, amountStart));
  }

  bool _verbAdjacent(String lower, RegExpMatch match) =>
      _txnVerb.hasMatch(_beforeAmount(lower, match.start)) ||
      _txnVerb.hasMatch(_afterAmount(lower, match.end));

  String _beforeAmount(String lower, int amountStart) {
    final from = amountStart < _adjacencyWindow
        ? 0
        : amountStart - _adjacencyWindow;
    return lower.substring(from, amountStart);
  }

  String _afterAmount(String lower, int amountEnd) {
    final to = amountEnd + _adjacencyWindow > lower.length
        ? lower.length
        : amountEnd + _adjacencyWindow;
    return lower.substring(amountEnd, to);
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

  /// Direction of the chosen amount, in preference order:
  ///
  /// 1. the debit/credit verb sitting beside that amount — the verb that
  ///    actually governs it. "Rs.100 credited ... for your bill paid" is a
  ///    credit, because `paid` describes the *original* bill, not this amount.
  /// 2. the whole-message rule, used when no verb is adjacent, or when both
  ///    kinds are.
  TransactionDirection? _direction(String lower, int? start, int? end) {
    if (start != null && end != null) {
      final before = _beforeAmount(lower, start);
      final after = _afterAmount(lower, end);
      final hasDebit =
          _debitVerb.hasMatch(before) || _debitVerb.hasMatch(after);
      final hasCredit =
          _creditVerb.hasMatch(before) || _creditVerb.hasMatch(after);
      if (hasDebit != hasCredit) {
        return hasDebit ? TransactionDirection.debit : TransactionDirection.credit;
      }
    }
    return _wholeMessageDirection(lower);
  }

  TransactionDirection? _wholeMessageDirection(String lower) {
    final hasDebit = _debitVerb.hasMatch(lower);
    final hasCredit = _creditVerb.hasMatch(lower);
    if (hasDebit && hasCredit) {
      // Both signals present: debit wins unless an explicit inflow verb
      // (refund/reversal) shows money returning to the holder.
      return _explicitInflow.hasMatch(lower)
          ? TransactionDirection.credit
          : TransactionDirection.debit;
    }
    if (hasCredit) return TransactionDirection.credit;
    if (hasDebit) return TransactionDirection.debit;
    return null;
  }

  PaymentInstrument _instrument(String lower) =>
      _cardMarker.hasMatch(lower)
      ? PaymentInstrument.card
      : PaymentInstrument.bank;

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
    final merchant = _merchantAt.firstMatch(lower)?.group(1)?.trim();
    if (merchant != null && merchant.length >= 2) return merchant;
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

/// What the marketing vocabulary in a body implies: nothing, keep the row but
/// force review, or the body is an offer and not a transaction at all.
enum _PromoSignal { none, review, reject }

/// The chosen transaction amount plus whether the choice was ambiguous (two or
/// more equally plausible non-balance candidates), in which case the row is
/// kept but routed to review as [ReviewReason.parserUncertain].
class _AmountResult {
  const _AmountResult(
    this.paise, {
    this.start,
    this.end,
    this.uncertain = false,
  });

  final int? paise;

  /// Where the chosen amount sits in the body, so direction can be read from
  /// the verb beside it rather than from a scan of the whole message.
  final int? start;
  final int? end;
  final bool uncertain;
}
