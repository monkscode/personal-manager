import '../data/sms_models.dart';
import 'merchant_display.dart';

/// Cleans the **live** SMS transaction history just before it is reduced into
/// the analysis snapshot. Two jobs, both pure and both no-ops on already-clean
/// data (so unit-test fixtures are unaffected):
///
///  1. **Dedup** identical bank events that were delivered more than once —
///     the classic Indian-bank case where the same alert arrives under several
///     DLT sender headers (`VM-HDFCBK-S`, `AD-HDFCBK-S`, …). Rows collapse only
///     when their redacted message *content* is byte-identical, so genuine
///     same-day repeats survive: mutual-fund SIPs (different UPI ref/payee in
///     the body) and sequential ATM withdrawals (different balance/timestamp).
///
///  2. **Enrich** the merchant + category the on-device parser left blank or
///     opaque, using [MerchantDisplay]. A *genuine* payee token is written
///     (never the bank-name fallback), giving recurring-detection a stable
///     owner key instead of the volatile DLT sender — the fix that lets monthly
///     commitments actually lock and populate the forecast.
class SmsLiveNormalizer {
  const SmsLiveNormalizer({this.display = const MerchantDisplay()});

  final MerchantDisplay display;

  /// Dedup, then enrich. Order matters: dedup first so enrichment does not run
  /// on rows that are about to be dropped.
  List<ParsedTxn> normalize(List<ParsedTxn> txns) {
    final deduped = dedup(txns);
    return [for (final t in deduped) enrich(t)];
  }

  /// Collapse rows that are the same event re-delivered. The signature is the
  /// amount, direction, calendar day and the normalised message content with
  /// the leading `[SENDER] <dir> <amount>p :: ` label stripped, so the same
  /// message under different DLT headers keys identically while a distinct SIP
  /// or a later ATM withdrawal (different body) does not.
  List<ParsedTxn> dedup(List<ParsedTxn> txns) {
    final sorted = [...txns]..sort((a, b) {
      final byDate = a.txnDate.compareTo(b.txnDate);
      if (byDate != 0) return byDate;
      return a.smsId.compareTo(b.smsId);
    });
    final seen = <String>{};
    final out = <ParsedTxn>[];
    for (final t in sorted) {
      if (seen.add(_dupKey(t))) out.add(t);
    }
    return out;
  }

  String _dupKey(ParsedTxn t) => [
    t.amountPaise,
    t.direction.storageValue,
    t.txnLocalDate,
    _content(t.rawBodyRedacted),
  ].join('\u00a7');

  static final RegExp _label = RegExp(r'^\s*\[[^\]]*\]\s*\w+\s+\d+p\s*::\s*');
  static final RegExp _ws = RegExp(r'\s+');

  String _content(String raw) =>
      raw.replaceFirst(_label, '').toLowerCase().trim().replaceAll(_ws, ' ');

  /// Fill a readable merchant/category for rows the parser left blank or
  /// opaque. Only writes a genuinely-resolved merchant (never the bank-name
  /// fallback) so unrelated bank debits are not merged into a false recurring
  /// group.
  ParsedTxn enrich(ParsedTxn t) {
    final display = this.display.resolve(t);
    final hasGoodMerchant = t.merchant != null &&
        t.merchant!.trim().isNotEmpty &&
        !_opaque(t.merchant!.trim());
    final merchant = (!hasGoodMerchant && display.merchantResolved)
        ? display.name.toLowerCase()
        : null;
    final category = (t.categoryKey.isEmpty || t.categoryKey == 'other') &&
            display.categoryKey != 'other'
        ? display.categoryKey
        : null;
    if (merchant == null && category == null) return t;
    return t.copyWith(merchant: merchant, categoryKey: category);
  }

  bool _opaque(String s) {
    final compact = s.replaceAll(' ', '');
    if (compact.length >= 12 &&
        RegExp(r'^[0-9a-f]+$', caseSensitive: false).hasMatch(compact)) {
      return true;
    }
    return RegExp(r'^\d{6,}$').hasMatch(compact);
  }
}
