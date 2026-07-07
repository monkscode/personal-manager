/// A raw email fetched from Gmail, reduced to the fields the parser needs.
class RawEmail {
  const RawEmail({
    required this.id,
    required this.from,
    required this.subject,
    required this.date,
    this.snippet = '',
    this.body = '',
  });

  final String id;
  final String from; // e.g. "LIC of India <no-reply@licindia.com>"
  final String subject;
  final DateTime date;
  final String snippet;
  final String body; // decoded plain text

  /// Lowercased sender domain, e.g. `licindia.com`.
  String get fromDomain {
    final match = RegExp(r'@([A-Za-z0-9._-]+)').firstMatch(from);
    return (match?.group(1) ?? '').toLowerCase();
  }

  /// Human-friendly sender name (the display name, or the domain's first label).
  String get fromName {
    final display = RegExp(r'^\s*"?([^"<]+?)"?\s*<').firstMatch(from)?.group(1)?.trim();
    if (display != null && display.isNotEmpty) return display;
    final domain = fromDomain;
    if (domain.isEmpty) return from.trim();
    return domain.split('.').first;
  }

  /// All text the parser scans, lowercased once for keyword matching.
  String get haystack => '$subject\n$snippet\n$body';
}

/// A bill/obligation the parser extracted from an email. Every parsed bill is a
/// *candidate* the user reviews and confirms — nothing is trusted blindly.
class ParsedBill {
  const ParsedBill({
    required this.sourceId,
    required this.merchant,
    required this.amount,
    required this.categoryKey,
    required this.recurrence,
    required this.confidence,
    required this.sourceSubject,
    required this.sourceFrom,
    this.dueDate,
  });

  final String sourceId;
  final String merchant;
  final double amount;
  final DateTime? dueDate;
  final String categoryKey; // one of the app's category keys
  final String recurrence; // 'onetime' | 'monthly' | 'quarterly' | 'annual'
  final double confidence; // 0..1
  final String sourceSubject;
  final String sourceFrom;

  bool get isRecurring => recurrence != 'onetime';

  ParsedBill copyWith({double? amount, DateTime? dueDate, String? categoryKey, String? recurrence}) {
    return ParsedBill(
      sourceId: sourceId,
      merchant: merchant,
      amount: amount ?? this.amount,
      dueDate: dueDate ?? this.dueDate,
      categoryKey: categoryKey ?? this.categoryKey,
      recurrence: recurrence ?? this.recurrence,
      confidence: confidence,
      sourceSubject: sourceSubject,
      sourceFrom: sourceFrom,
    );
  }

  /// Stable de-duplication key: same biller + amount + due month is one bill.
  String get dedupeKey {
    final month = dueDate == null ? 'na' : '${dueDate!.year}-${dueDate!.month}';
    return '${merchant.toLowerCase()}|${amount.round()}|$month';
  }
}
