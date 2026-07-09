import 'dart:math' as math;

import '../data/parsed_bill.dart';

/// A rule for a known biller, keyed by a substring of the sender domain.
class _SenderRule {
  const _SenderRule(this.match, this.merchant, this.category, this.recurrence);
  final String match;
  final String merchant;
  final String category;
  final String recurrence;
}

/// On-device email parser. Pure Dart, no network, no AI — extracts a bill
/// candidate from a transactional email using sender rules + heuristics.
///
/// Designed for high *recall* (cast a wide net); precision is handled by the
/// user confirming candidates. An optional AI resolver can be layered on later
/// for messy emails the rules miss, without changing this contract.
class EmailParser {
  const EmailParser();

  static const _senderRules = <_SenderRule>[
    _SenderRule('licindia', 'LIC of India', 'insurance', 'annual'),
    _SenderRule('hdfclife', 'HDFC Life', 'insurance', 'annual'),
    _SenderRule('iciciprulife', 'ICICI Pru Life', 'insurance', 'annual'),
    _SenderRule('sbilife', 'SBI Life', 'insurance', 'annual'),
    _SenderRule('maxlife', 'Max Life', 'insurance', 'annual'),
    _SenderRule('bajajallianz', 'Bajaj Allianz', 'insurance', 'annual'),
    _SenderRule('tataaia', 'Tata AIA', 'insurance', 'annual'),
    _SenderRule('policybazaar', 'Policybazaar', 'insurance', 'annual'),
    _SenderRule('netflix', 'Netflix', 'subscriptions', 'monthly'),
    _SenderRule('spotify', 'Spotify', 'subscriptions', 'monthly'),
    _SenderRule('primevideo', 'Prime Video', 'subscriptions', 'monthly'),
    _SenderRule('hotstar', 'Disney+ Hotstar', 'subscriptions', 'monthly'),
    _SenderRule('disney', 'Disney+ Hotstar', 'subscriptions', 'monthly'),
    _SenderRule('icloud', 'Apple iCloud', 'subscriptions', 'monthly'),
    _SenderRule('apple', 'Apple', 'subscriptions', 'monthly'),
    _SenderRule('youtube', 'YouTube Premium', 'subscriptions', 'monthly'),
    _SenderRule('airtel', 'Airtel', 'utilities', 'monthly'),
    _SenderRule('jio', 'Jio', 'utilities', 'monthly'),
    _SenderRule('actcorp', 'ACT Fibernet', 'utilities', 'monthly'),
    _SenderRule('tatapower', 'Tata Power', 'utilities', 'monthly'),
    _SenderRule('adanielectricity', 'Adani Electricity', 'utilities', 'monthly'),
    _SenderRule('bescom', 'BESCOM', 'utilities', 'monthly'),
    _SenderRule('mahadiscom', 'MSEB', 'utilities', 'monthly'),
  ];

  // Category inference keywords (checked when no sender rule matches).
  static const _categoryKeywords = <String, List<String>>{
    'insurance': ['insurance', 'premium', 'policy', 'life cover', 'term plan', 'mediclaim'],
    'housing': ['rent', 'lease', 'maintenance', 'society', 'landlord', 'housing'],
    'utilities': [
      'electricity', 'power bill', 'energy bill', 'water bill', 'gas bill', 'lpg',
      'broadband', 'wifi', 'internet', 'fiber', 'fibernet', 'dth', 'postpaid', 'recharge', 'utility'
    ],
    'subscriptions': ['subscription', 'membership', 'gym', 'prime', 'renewal of your'],
    'transport': ['fuel', 'petrol', 'diesel', 'fastag', 'metro card', 'parking', 'toll'],
    'groceries': ['grocery', 'groceries', 'supermarket', 'bigbasket', 'blinkit', 'instamart'],
  };

  static const _strongBillKeywords = [
    'due', 'premium', 'payable', 'invoice', 'bill', 'emi', 'statement',
    'e-mandate', 'autopay', 'auto-debit', 'renew', 'renewal', 'payment reminder', 'amount due'
  ];
  static const _billKeywords = [
    ..._strongBillKeywords,
    'payment', 'pay', 'reminder', 'recharge', 'subscription', 'receipt', 'total amount'
  ];
  static const _promoKeywords = [
    '% off', 'sale', 'discount', 'flat ', 'coupon', 'deal of', 'cashback offer', 'lucky', 'you won',
    'offer', 'off on', 'win ', 'free gift', 'flash sale', 'limited time', 'best deal', 'top deals',
    'grab now', 'shop now', 'buy now', 'new arrivals', 'refer and earn', 'exclusive', 'just for you',
    'recommended for you', 'order confirm', 'order placed', 'order delivered', 'has shipped', 'out for delivery',
  ];

  static final RegExp _currency =
      RegExp(r'(?:₹|rs\.?|inr)\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)', caseSensitive: false);
  static final RegExp _keywordAmount = RegExp(
      r'(?:amount|total|premium|due|payable|balance)[^0-9₹]{0,12}([0-9][0-9,]{2,}(?:\.[0-9]{1,2})?)',
      caseSensitive: false);

  static const _months = {
    'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
    'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
    'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9, 'oct': 10, 'october': 10,
    'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
  };

  /// Parse a batch, drop non-bills, de-duplicate (keep highest confidence),
  /// and sort by confidence then soonest due date.
  List<ParsedBill> parseAll(Iterable<RawEmail> emails) {
    final byKey = <String, ParsedBill>{};
    for (final e in emails) {
      final bill = parseOne(e);
      if (bill == null) continue;
      final existing = byKey[bill.dedupeKey];
      if (existing == null || bill.confidence > existing.confidence) {
        byKey[bill.dedupeKey] = bill;
      }
    }
    final list = byKey.values.toList();
    list.sort((a, b) {
      final c = b.confidence.compareTo(a.confidence);
      if (c != 0) return c;
      final ad = a.dueDate, bd = b.dueDate;
      if (ad == null && bd == null) return 0;
      if (ad == null) return 1;
      if (bd == null) return -1;
      return ad.compareTo(bd);
    });
    return list;
  }

  /// Extract a single bill candidate, or null if the email isn't bill-like or
  /// has no recognizable amount.
  ParsedBill? parseOne(RawEmail email) {
    final text = email.haystack;
    final lower = text.toLowerCase();

    final hasStrong = _strongBillKeywords.any(lower.contains);
    final hasBill = _billKeywords.any(lower.contains);
    if (!hasBill) return null;
    // Reject anything carrying marketing/receipt language, even if it also
    // contains a "strong" bill word — real bill reminders don't run offers.
    if (_promoKeywords.any(lower.contains)) return null;

    final amount = _extractAmount(text);
    if (amount == null) return null;

    final rule = _matchSender(email.fromDomain);
    final inferredCategory = _inferCategory(lower);
    final category = rule?.category ?? inferredCategory ?? 'other';
    final merchant = rule?.merchant ?? email.fromName;
    final recurrence = rule?.recurrence ?? _inferRecurrence(lower, category);
    final dueDate = _extractDueDate(text, email.date);

    var confidence = 0.35;
    if (dueDate != null) confidence += 0.25;
    if (rule != null) confidence += 0.25;
    if (inferredCategory != null || rule != null) confidence += 0.15;
    if (hasStrong) confidence += 0.1;
    confidence = math.min(1, confidence);

    // A bare weak-keyword hit ("payment"/"receipt"/"recharge"...) with no due
    // date, no known sender, no inferred category and no strong bill word is
    // almost always a receipt/notification, not a bill to plan for — drop it
    // instead of surfacing it as a low-confidence candidate.
    if (confidence < 0.45) return null;

    return ParsedBill(
      sourceId: email.id,
      merchant: merchant,
      amount: amount,
      dueDate: dueDate,
      categoryKey: category,
      recurrence: recurrence,
      confidence: confidence,
      sourceSubject: email.subject,
      sourceFrom: email.from,
    );
  }

  _SenderRule? _matchSender(String domain) {
    if (domain.isEmpty) return null;
    for (final r in _senderRules) {
      if (domain.contains(r.match)) return r;
    }
    return null;
  }

  String? _inferCategory(String lower) {
    for (final entry in _categoryKeywords.entries) {
      if (entry.value.any(lower.contains)) return entry.key;
    }
    return null;
  }

  String _inferRecurrence(String lower, String category) {
    if (RegExp(r'\bannual|yearly|per annum|per year\b').hasMatch(lower)) return 'annual';
    if (lower.contains('quarterly')) return 'quarterly';
    if (RegExp(r'\bmonthly|per month|/month|emi\b').hasMatch(lower)) return 'monthly';
    // Sensible category defaults.
    if (category == 'housing' || category == 'utilities' || category == 'subscriptions') return 'monthly';
    if (category == 'insurance') return 'annual';
    return 'onetime';
  }

  /// Public entry to the rule-based amount extractor — used as a backstop to
  /// recover an amount when the AI extractor returns none.
  double? extractAmount(String text) => _extractAmount(text);

  double? _extractAmount(String text) {
    final candidates = <({double value, int start})>[];
    for (final m in _currency.allMatches(text)) {
      final v = _toAmount(m.group(1));
      if (v != null) candidates.add((value: v, start: m.start));
    }
    if (candidates.isEmpty) {
      for (final m in _keywordAmount.allMatches(text)) {
        final v = _toAmount(m.group(1));
        if (v != null) candidates.add((value: v, start: m.start));
      }
    }
    if (candidates.isEmpty) return null;

    final lower = text.toLowerCase();
    final kw = RegExp(r'premium|amount|total|due|payable|pay|balance|bill|emi|price|charge');
    double best = -1;
    double bestScore = -1;
    for (final c in candidates) {
      final pre = lower.substring(math.max(0, c.start - 28), c.start);
      // A keyword-adjacent amount always beats a bare one; among those, larger wins.
      final score = (kw.hasMatch(pre) ? 1e9 : 0) + c.value;
      if (score > bestScore) {
        bestScore = score;
        best = c.value;
      }
    }
    return best;
  }

  double? _toAmount(String? raw) {
    if (raw == null) return null;
    final v = double.tryParse(raw.replaceAll(',', ''));
    if (v == null || v < 1 || v >= 100000000) return null;
    return v;
  }

  DateTime? _extractDueDate(String text, DateTime emailDate) {
    final found = <DateTime>[];

    // Numeric dd/mm/yyyy or dd-mm-yyyy (Indian day-first order).
    for (final m in RegExp(r'\b(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})\b').allMatches(text)) {
      final d = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      var y = int.parse(m.group(3)!);
      if (y < 100) y += 2000;
      final dt = _safeDate(y, mo, d);
      if (dt != null) found.add(dt);
    }
    // "14 Feb 2026" / "14th February".
    final dmy = RegExp(
        r'\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?\s*,?\s*(\d{4})?',
        caseSensitive: false);
    for (final m in dmy.allMatches(text)) {
      final mo = _months[m.group(2)!.toLowerCase()];
      if (mo == null) continue;
      final dt = _safeDate(m.group(3) != null ? int.parse(m.group(3)!) : emailDate.year, mo, int.parse(m.group(1)!), emailDate);
      if (dt != null) found.add(dt);
    }
    // "Feb 14, 2026" — the `(?!\d)` stops "Feb 2026" being read as day 20.
    final mdy = RegExp(
        r'\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?!\d)(?:st|nd|rd|th)?\s*,?\s*(\d{4})?',
        caseSensitive: false);
    for (final m in mdy.allMatches(text)) {
      final mo = _months[m.group(1)!.toLowerCase()];
      if (mo == null) continue;
      final dt = _safeDate(m.group(3) != null ? int.parse(m.group(3)!) : emailDate.year, mo, int.parse(m.group(2)!), emailDate);
      if (dt != null) found.add(dt);
    }

    if (found.isEmpty) return null;

    // Prefer the soonest date that is on/after the email's date (an upcoming
    // due date); otherwise fall back to the earliest found.
    found.sort();
    final cutoff = emailDate.subtract(const Duration(days: 2));
    for (final d in found) {
      if (!d.isBefore(cutoff)) return d;
    }
    return found.first;
  }

  /// Builds a valid date, rejecting impossible day/month combos. When [ref] is
  /// given and no explicit year was present, rolls to next year if the date has
  /// already clearly passed (so a "due 5 Jan" in a December email means next Jan).
  DateTime? _safeDate(int year, int month, int day, [DateTime? ref]) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    var dt = DateTime(year, month, day);
    if (dt.month != month || dt.day != day) return null; // e.g. Feb 30
    if (ref != null && dt.isBefore(ref.subtract(const Duration(days: 20)))) {
      dt = DateTime(year + 1, month, day);
    }
    return dt;
  }
}
