import '../data/sms_models.dart';
import 'payee_text.dart';

/// Normalizes an Indian DLT SMS sender into its bank header segment.
///
/// Senders arrive as `<operator>-<header>` or `<operator>-<header>-<category>`,
/// e.g. `VM-HDFCBK`, `AD-SBIINB-T`. The two-letter operator/access code and any
/// trailing single-letter category suffix (Transactional/Promotional/Service)
/// are removed, leaving the uppercased header (`HDFCBK`, `SBIINB`). A bare
/// header is returned uppercased and trimmed.
String normalizeSenderHeader(String sender) {
  final segments = sender
      .toUpperCase()
      .trim()
      .split('-')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.isEmpty) return '';
  // Drop a leading two-letter operator/access code (VM, AD, AX, ...).
  if (segments.length > 1 && segments.first.length <= 2) {
    segments.removeAt(0);
  }
  // Drop a trailing single-letter category suffix (T/P/S).
  if (segments.length > 1 && segments.last.length == 1) {
    segments.removeLast();
  }
  return segments.join('-');
}

/// A human-readable payee name plus a spending category for one transaction.
class TxnDisplay {
  const TxnDisplay({
    required this.name,
    required this.categoryKey,
    required this.categoryLabel,
    this.merchantResolved = false,
  });

  /// Finart-style payee name the user recognises (e.g. `Swiggy`, `Kandoi
  /// Bhogilal Mulcha`, `Cash withdrawal`).
  final String name;

  /// Stable lowercase category key (e.g. `food`, `groceries`, `cash`).
  final String categoryKey;

  /// Human label for [categoryKey] (e.g. `Food & Dining`).
  final String categoryLabel;

  /// True when [name] came from a genuine merchant/payee token in the body,
  /// the stored merchant, or a UPI handle — **not** the generic bank-name
  /// fallback. Only a resolved name is a safe recurring-grouping owner key;
  /// the bank fallback would merge unrelated debits into a false commitment.
  final bool merchantResolved;
}

/// Turns a stored/parsed [ParsedTxn] into a human-readable name and category.
///
/// The on-device parser often leaves `merchant` null and `categoryKey` as
/// `other`, so the raw activity list shows sender codes (`VM-HDFCBK-S`) and
/// opaque VPA hashes. This pure resolver recovers a readable name from the
/// (already-redacted) message body — the merchant token survives redaction —
/// and classifies it, working on both existing rows and freshly scanned ones.
class MerchantDisplay {
  const MerchantDisplay();

  TxnDisplay resolve(ParsedTxn t) {
    final resolved = _resolveName(t);
    final categoryKey = _category(t, resolved.name);
    return TxnDisplay(
      name: resolved.name,
      categoryKey: categoryKey,
      categoryLabel: labelForCategory(categoryKey),
      merchantResolved: resolved.resolved,
    );
  }

  // ---- name ----------------------------------------------------------------

  ({String name, bool resolved}) _resolveName(ParsedTxn t) {
    final body = t.rawBodyRedacted;

    // Cash: ATM withdrawals have no useful merchant — label them plainly.
    // Not a merchant owner key (and ATM is excluded from recurring anyway).
    if (t.type == TxnType.atm || _withdrawn.hasMatch(body)) {
      return (name: 'Cash withdrawal', resolved: false);
    }

    // 1) A merchant token embedded in the body ("... at MERCHANT on <date>",
    //    "UPI/P2M/<ref>/<NAME>", etc.) is the most reliable signal.
    final fromBody = _merchantFromBody(body);
    if (fromBody != null) {
      final cleaned = _clean(fromBody);
      if (cleaned != null) return (name: _canonical(cleaned), resolved: true);
    }

    // 2) The stored merchant field, when it is not an opaque token.
    final storedMerchant = _clean(t.merchant);
    if (storedMerchant != null && !_isOpaque(storedMerchant)) {
      return (name: _canonical(storedMerchant), resolved: true);
    }

    // 3) A readable UPI handle (the part before '@').
    final handle = _clean(t.upiVpaNorm?.split('@').first);
    if (handle != null && !_isOpaque(handle)) {
      return (name: _canonical(handle), resolved: true);
    }

    // 4) Nothing readable — fall back to the friendly bank name.
    return (name: _bankName(t.sender), resolved: false);
  }

  static final RegExp _withdrawn = RegExp(
    r'\bwithdrawn\b|\bwithdrawal\b|\batm\b',
    caseSensitive: false,
  );

  /// Extracts a merchant token from common Indian bank/UPI SMS shapes.
  String? _merchantFromBody(String body) {
    // UPI/P2M/<ref>/<NAME> or UPI/P2A/<ref>/<NAME>.
    final upi = RegExp(
      r'UPI/(?:P2M|P2A|P2P|CX)/[^/\n]*/([^/\n]+)',
      caseSensitive: false,
    ).firstMatch(body);
    if (upi != null) return upi.group(1);

    // Axis card purchase. The merchant is its own line, after the line holding
    // the time:
    //
    //     Spent / Card no. XX1234 / INR 100.00 / 07-07-25 21:16:01 /
    //     Disha Enter / Avl Lmt INR 5000
    //
    // The amount sits between the card line and the time, and the count of
    // lines between them is what varies across Axis templates — so the gap is
    // tolerated rather than assumed to be one line.
    final axisCard = RegExp(
      r'\bcard no\.[^\n]*\n(?:[^\n]*\n){0,3}?[^\n]*\d{1,2}:\d{2}:\d{2}[^\n]*\n'
      r'\s*([^\n]{2,40})',
      caseSensitive: false,
    ).firstMatch(body);
    if (axisCard != null) return axisCard.group(1);

    // ICICI card purchase, single line, merchant after the *second* "on":
    // "<amt> spent using ICICI Bank Card XX12 on 27-Dec-25 on AMAZON INDIA CY.
    // Avl Limit: ...". Anchored on the trailing "Avl Limit" because the
    // merchant itself may contain a period ("IND*Amazon.in -").
    final iciciCard = RegExp(
      r'\bspent using\b[^\n]*?\bon\s+\d{1,2}-[a-z]{3}-\d{2,4}\s+on\s+'
      r'(.+?)\s*\.\s*avl\s+limit',
      caseSensitive: false,
    ).firstMatch(body);
    if (iciciCard != null) return iciciCard.group(1);

    // "... at MERCHANT on <date>" / "... at MERCHANT. " / "... at MERCHANT<EOL>".
    // Stop before a following " on <digit>" date, a period, "Avl"/"Bal", or EOL.
    final at = RegExp(
      r'\bat\s+(.+?)(?:\s+on\s+\d|\.|\s+avl\b|\s+bal\b|\n|$)',
      caseSensitive: false,
    ).firstMatch(body);
    if (at != null) return at.group(1);

    // "Sent <amt> From <own a/c> To PAYEE On <date>" — HDFC's UPI debit, which
    // names the payee with `To` and carries no VPA. Mirrors
    // `sms_transaction_parser._merchantTo`; the two must not drift. Only
    // reached when no `at` payee was found, so an `at` merchant still wins.
    final to = RegExp(
      r'\bto\s+(.+?)(?:\s+on\s+\d|\.|\s+avl\b|\s+bal\b|\n|$)',
      caseSensitive: false,
    ).firstMatch(body);
    if (to != null) return to.group(1);

    return null;
  }

  /// Trims noise, strips payment-aggregator prefixes, collapses whitespace and
  /// title-cases. Returns null for empty/placeholder tokens.
  String? _clean(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty) return null;
    // TASK-45. This read runs on the *redacted* body, so the same rule the
    // parser applies to raw digits applies here to the tokens standing where
    // those digits were. The previous check named three of the five
    // placeholders and matched only when one was the whole capture, so
    // `[number]` reached the user as a payee name on 95 device rows and an
    // embedded token on 253 more.
    final sanitized = PayeeText.sanitize(s);
    if (sanitized == null) return null;
    s = sanitized;
    // Strip a leading aggregator prefix like "RAZ*", "BBPS*", "PAYU*", "PYTM*".
    s = s.replaceFirst(
      RegExp(r'^[A-Za-z]{2,6}\*', caseSensitive: false),
      '',
    );
    // Drop trailing reference/id numbers and stray punctuation.
    s = s.replaceFirst(RegExp(r'[\s*_/,-]+\d[\d\s]*$'), '');
    s = s.replaceAll(RegExp(r'[*_]+'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return null;
    // Cap over-long tokens.
    if (s.length > 28) s = s.substring(0, 28).trim();
    return _titleCase(s);
  }

  /// Whether a token is an opaque machine id (long hex / all digits) that means
  /// nothing to the user.
  bool _isOpaque(String s) {
    final compact = s.replaceAll(' ', '');
    if (compact.length >= 12 && RegExp(r'^[0-9a-f]+$', caseSensitive: false).hasMatch(compact)) {
      return true;
    }
    if (RegExp(r'^\d{6,}$').hasMatch(compact)) return true;
    return false;
  }

  String _titleCase(String s) => s
      .split(' ')
      .where((w) => w.isNotEmpty)
      .map((w) => w.length == 1 ? w.toUpperCase() : w[0].toUpperCase() + w.substring(1).toLowerCase())
      .join(' ');

  /// Maps a cleaned token to a canonical brand name when it matches a known
  /// merchant; otherwise returns the cleaned token unchanged.
  String _canonical(String cleaned) {
    final lower = cleaned.toLowerCase();
    for (final entry in _knownMerchants) {
      if (lower.contains(entry.keyword)) return entry.brand;
    }
    return cleaned;
  }

  String _bankName(String sender) {
    final header = normalizeSenderHeader(sender);
    const banks = {
      'HDFCBK': 'HDFC Bank',
      'HDFCBN': 'HDFC Bank',
      'ICICIB': 'ICICI Bank',
      'ICICIT': 'ICICI Bank',
      'ICICIC': 'ICICI Bank',
      'AXISBK': 'Axis Bank',
      'AXISB': 'Axis Bank',
      'SBIINB': 'SBI',
      'SBICRD': 'SBI Card',
      'SBIUPI': 'SBI',
      'KOTAKB': 'Kotak Bank',
      'KMBL': 'Kotak Bank',
      'KOTAK': 'Kotak Bank',
    };
    final mapped = banks[header];
    if (mapped != null) return mapped;
    if (header.isEmpty) return 'Bank';
    // Older DLT senders carry no separators (`VMAXISBK`), so
    // `normalizeSenderHeader` has nothing to split on and the operator code
    // stays glued to the bank's. Retry without it — the same reading
    // `SmsLiveNormalizer._institution` already applies. TASK-45 made this
    // visible: refusing a junk payee routes far more rows to this fallback,
    // and `Vmaxisbk` is not a bank name.
    if (header.length > 2) {
      final withoutOperator = banks[header.substring(2)];
      if (withoutOperator != null) return withoutOperator;
    }
    return _titleCase(header);
  }

  // ---- category ------------------------------------------------------------

  String _category(ParsedTxn t, String name) {
    if (t.type == TxnType.atm || name == 'Cash withdrawal') return 'cash';

    if (t.direction == TransactionDirection.credit) {
      final body = t.rawBodyRedacted.toLowerCase();
      if (RegExp(r'refund|reversed|reversal|cashback').hasMatch(body)) {
        return 'refund';
      }
      return 'income';
    }

    // Known-merchant category from the resolved name or the body.
    final haystack = '${name.toLowerCase()} ${t.rawBodyRedacted.toLowerCase()}';
    for (final entry in _knownMerchants) {
      if (haystack.contains(entry.keyword)) return entry.category;
    }

    // Keep a meaningful category the parser already assigned.
    if (t.categoryKey.isNotEmpty && t.categoryKey != 'other') {
      return t.categoryKey;
    }

    if (t.type == TxnType.transfer) return 'transfers';
    return 'other';
  }

  /// Human labels for category keys used across the UI.
  static String labelForCategory(String key) => switch (key) {
    'food' => 'Food & Dining',
    'groceries' => 'Groceries',
    'shopping' => 'Shopping',
    'transport' => 'Transport',
    'travel' => 'Travel',
    'entertainment' => 'Entertainment',
    'subscriptions' => 'Subscriptions',
    'utilities' => 'Bills & Utilities',
    'housing' => 'Housing',
    'health' => 'Health',
    'insurance' => 'Insurance',
    'investments' => 'Investments',
    'cash' => 'Cash',
    'transfers' => 'Transfers',
    'income' => 'Income',
    'refund' => 'Refund',
    _ => 'Other',
  };
}

/// A known-merchant keyword → canonical brand name + category. Matched as a
/// case-insensitive substring against the resolved name and message body.
typedef _KnownMerchant = ({String keyword, String brand, String category});

const List<_KnownMerchant> _knownMerchants = [
  // Food & dining
  (keyword: 'swiggy', brand: 'Swiggy', category: 'food'),
  (keyword: 'zomato', brand: 'Zomato', category: 'food'),
  (keyword: 'dominos', brand: "Domino's", category: 'food'),
  (keyword: 'mcdonald', brand: "McDonald's", category: 'food'),
  (keyword: 'kfc', brand: 'KFC', category: 'food'),
  (keyword: 'faasos', brand: 'Faasos', category: 'food'),
  (keyword: 'starbucks', brand: 'Starbucks', category: 'food'),
  (keyword: 'chaayos', brand: 'Chaayos', category: 'food'),
  (keyword: 'haldiram', brand: 'Haldiram', category: 'food'),
  // Groceries
  (keyword: 'bigbasket', brand: 'BigBasket', category: 'groceries'),
  (keyword: 'blinkit', brand: 'Blinkit', category: 'groceries'),
  (keyword: 'zepto', brand: 'Zepto', category: 'groceries'),
  (keyword: 'dmart', brand: 'DMart', category: 'groceries'),
  (keyword: 'jiomart', brand: 'JioMart', category: 'groceries'),
  (keyword: 'instamart', brand: 'Instamart', category: 'groceries'),
  (keyword: 'grofers', brand: 'Grofers', category: 'groceries'),
  // Shopping
  (keyword: 'amazon', brand: 'Amazon', category: 'shopping'),
  (keyword: 'flipkart', brand: 'Flipkart', category: 'shopping'),
  (keyword: 'myntra', brand: 'Myntra', category: 'shopping'),
  (keyword: 'ajio', brand: 'Ajio', category: 'shopping'),
  (keyword: 'meesho', brand: 'Meesho', category: 'shopping'),
  (keyword: 'nykaa', brand: 'Nykaa', category: 'shopping'),
  (keyword: 'croma', brand: 'Croma', category: 'shopping'),
  (keyword: 'lenskart', brand: 'Lenskart', category: 'shopping'),
  (keyword: 'decathlon', brand: 'Decathlon', category: 'shopping'),
  // Transport
  (keyword: 'uber', brand: 'Uber', category: 'transport'),
  (keyword: 'ola', brand: 'Ola', category: 'transport'),
  (keyword: 'rapido', brand: 'Rapido', category: 'transport'),
  (keyword: 'redbus', brand: 'redBus', category: 'transport'),
  (keyword: 'fastag', brand: 'FASTag', category: 'transport'),
  (keyword: 'hpcl', brand: 'HP Petrol', category: 'transport'),
  (keyword: 'iocl', brand: 'Indian Oil', category: 'transport'),
  (keyword: 'bpcl', brand: 'Bharat Petroleum', category: 'transport'),
  // Travel
  (keyword: 'irctc', brand: 'IRCTC', category: 'travel'),
  (keyword: 'makemytrip', brand: 'MakeMyTrip', category: 'travel'),
  (keyword: 'goibibo', brand: 'Goibibo', category: 'travel'),
  (keyword: 'cleartrip', brand: 'Cleartrip', category: 'travel'),
  (keyword: 'indigo', brand: 'IndiGo', category: 'travel'),
  (keyword: 'oyo', brand: 'OYO', category: 'travel'),
  // Entertainment
  (keyword: 'netflix', brand: 'Netflix', category: 'entertainment'),
  (keyword: 'hotstar', brand: 'Disney+ Hotstar', category: 'entertainment'),
  (keyword: 'spotify', brand: 'Spotify', category: 'entertainment'),
  (keyword: 'bookmyshow', brand: 'BookMyShow', category: 'entertainment'),
  (keyword: 'sonyliv', brand: 'SonyLIV', category: 'entertainment'),
  (keyword: 'pvr', brand: 'PVR', category: 'entertainment'),
  // Bills & utilities
  (keyword: 'jio', brand: 'Jio', category: 'utilities'),
  (keyword: 'airtel', brand: 'Airtel', category: 'utilities'),
  (keyword: 'vodafone', brand: 'Vi', category: 'utilities'),
  (keyword: 'bsnl', brand: 'BSNL', category: 'utilities'),
  (keyword: 'tata power', brand: 'Tata Power', category: 'utilities'),
  (keyword: 'adani', brand: 'Adani', category: 'utilities'),
  (keyword: 'torrent power', brand: 'Torrent Power', category: 'utilities'),
  (keyword: 'act fibernet', brand: 'ACT Fibernet', category: 'utilities'),
  // Health
  (keyword: 'pharmeasy', brand: 'PharmEasy', category: 'health'),
  (keyword: '1mg', brand: 'Tata 1mg', category: 'health'),
  (keyword: 'netmeds', brand: 'Netmeds', category: 'health'),
  (keyword: 'apollo', brand: 'Apollo', category: 'health'),
  (keyword: 'medplus', brand: 'MedPlus', category: 'health'),
  (keyword: 'cultfit', brand: 'cult.fit', category: 'health'),
  // Investments
  (keyword: 'zerodha', brand: 'Zerodha', category: 'investments'),
  (keyword: 'groww', brand: 'Groww', category: 'investments'),
  (keyword: 'upstox', brand: 'Upstox', category: 'investments'),
  (keyword: 'indmoney', brand: 'INDmoney', category: 'investments'),
  // Insurance
  (keyword: 'policybazaar', brand: 'PolicyBazaar', category: 'insurance'),
  (keyword: 'lic ', brand: 'LIC', category: 'insurance'),
];
