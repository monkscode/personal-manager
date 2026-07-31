/// An immutable, per-bank refinement layer for [SmsTransactionParser].
///
/// The parser's primary path is bank-agnostic (normalize → tokenize, spec §6).
/// These patterns are an *optional refinement* layered on top: when a message's
/// sender resolves to a known bank via [bankPatternForSender], the bank-specific
/// [debit]/[credit]/[balance] regexes can disambiguate direction and balance
/// phrasing that the generic path finds ambiguous.
///
/// The registry is deliberately immutable — unlike the reference parser's
/// global mutable `addCustomPattern` list (spec §6). DB-backed user patterns are
/// a clean future addition and would not mutate this built-in library.
class BankSmsPattern {
  const BankSmsPattern({
    required this.bankKey,
    required this.senderIds,
    this.debit,
    this.credit,
    this.balance,
  });

  /// Stable lowercase identifier for the bank (e.g. `hdfc`).
  final String bankKey;

  /// Normalized DLT sender headers (uppercase, operator prefix stripped) that
  /// belong to this bank — e.g. `HDFCBK`, `SBIINB`. Matched against
  /// [normalizeSenderHeader] of an incoming sender.
  final List<String> senderIds;

  /// Matches debit/outflow phrasing in this bank's messages, if defined.
  final RegExp? debit;

  /// Matches credit/inflow phrasing in this bank's messages, if defined.
  final RegExp? credit;

  /// Matches the available-balance phrase in this bank's messages, if defined.
  final RegExp? balance;

  /// Whether [sender] resolves to this bank after header normalization.
  bool matchesSender(String sender) =>
      senderIds.contains(normalizeSenderHeader(sender));
}

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

/// Returns the [BankSmsPattern] whose sender ids include [sender]'s normalized
/// header, or `null` when the sender is not a recognized bank.
BankSmsPattern? bankPatternForSender(String sender) {
  final header = normalizeSenderHeader(sender);
  for (final pattern in kBankPatterns) {
    if (pattern.senderIds.contains(header)) return pattern;
  }
  return null;
}

RegExp _ci(String source) => RegExp(source, caseSensitive: false);

// Shared vocabulary building blocks. Each bank compiles its own RegExp instance
// so the registry stays per-bank and independently tunable.
const String _debitVerbs = r'debited|withdrawn|spent|paid|deducted|purchased';
const String _creditVerbs = r'credited|deposited|received';
const String _balancePhrase =
    r'(?:avl\.?\s*bal|available\s+balance|a/c\s+bal|updated\s+balance)\b';

/// Immutable built-in library of per-bank SMS patterns.
///
/// Not declared `const` because [RegExp] has no const constructor; it is instead
/// an unmodifiable list of instances built once at load time.
final List<BankSmsPattern> kBankPatterns = List.unmodifiable(<BankSmsPattern>[
  BankSmsPattern(
    bankKey: 'sbi',
    senderIds: List.unmodifiable(const <String>[
      'SBIINB',
      'SBIBNK',
      'SBIPSG',
      'CBSSBI',
      'ATMSBI',
      'SBICRD',
      'SBIUPI',
    ]),
    debit: _ci(_debitVerbs),
    credit: _ci(_creditVerbs),
    balance: _ci(_balancePhrase),
  ),
  BankSmsPattern(
    bankKey: 'hdfc',
    senderIds: List.unmodifiable(const <String>['HDFCBK', 'HDFCBN']),
    debit: _ci(_debitVerbs),
    credit: _ci(_creditVerbs),
    balance: _ci(_balancePhrase),
  ),
  BankSmsPattern(
    bankKey: 'icici',
    senderIds: List.unmodifiable(const <String>['ICICIB', 'ICICIT', 'ICICIC']),
    debit: _ci(_debitVerbs),
    credit: _ci(_creditVerbs),
    balance: _ci(_balancePhrase),
  ),
  BankSmsPattern(
    bankKey: 'axis',
    senderIds: List.unmodifiable(const <String>['AXISBK', 'AXISB']),
    debit: _ci(_debitVerbs),
    credit: _ci(_creditVerbs),
    balance: _ci(_balancePhrase),
  ),
  BankSmsPattern(
    bankKey: 'kotak',
    senderIds: List.unmodifiable(const <String>['KOTAKB', 'KMBL', 'KOTAK']),
    debit: _ci(_debitVerbs),
    credit: _ci(_creditVerbs),
    balance: _ci(_balancePhrase),
  ),
]);
