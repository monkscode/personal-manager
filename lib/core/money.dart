/// Decimal-safe conversion helpers for forecast/storage money boundaries.
///
/// All durable and forecast math uses integer paise. This parser intentionally
/// avoids summing or multiplying floating-point values.
class MoneyParser {
  const MoneyParser._();

  static final RegExp _amount = RegExp(
    r'^\s*(?:₹|rs\.?|inr)?\s*([0-9][0-9,]*)(?:\.([0-9]+))?\s*$',
    caseSensitive: false,
  );

  static int parseRupeesToPaise(String input) {
    final paise = tryParseRupeesToPaise(input);
    if (paise == null) {
      throw FormatException('Invalid rupee amount', input);
    }
    return paise;
  }

  /// Non-throwing variant: returns `null` for any input that is not a single,
  /// well-formed, in-range rupee amount (bad grouping, trailing text, or a
  /// value so large it would overflow int64 paise). Used on regex-extracted
  /// substrings — e.g. the SMS parser — which must never crash on junk input.
  static int? tryParseRupeesToPaise(String input) {
    final match = _amount.firstMatch(input);
    if (match == null) return null;

    final rupeeText = match.group(1)!;
    if (!_hasValidGrouping(rupeeText)) return null;

    final rupees = int.tryParse(rupeeText.replaceAll(',', ''));
    if (rupees == null) return null; // exceeds int64
    final paise = _parsePaise(match.group(2) ?? '');
    // Guard the rupees*100 multiply against int64 overflow.
    const maxInt = 9223372036854775807;
    if (rupees > (maxInt - paise) ~/ 100) return null;
    return rupees * 100 + paise;
  }

  static int paiseFromRupeeNumber(num value) {
    if (value.isNaN || value.isInfinite || value < 0) {
      throw FormatException('Invalid rupee amount', value);
    }
    return parseRupeesToPaise(value.toStringAsFixed(3));
  }

  static int _parsePaise(String decimals) {
    if (decimals.isEmpty) return 0;

    final padded = decimals.padRight(3, '0');
    final wholePaise = int.parse(padded.substring(0, 2));
    final roundUp = int.parse(padded[2]) >= 5;
    return wholePaise + (roundUp ? 1 : 0);
  }

  static bool _hasValidGrouping(String text) {
    if (!text.contains(',')) return true;
    final groups = text.split(',');
    if (groups.first.isEmpty || groups.first.length > 3) return false;
    if (groups.any((g) => g.isEmpty)) return false;
    if (groups.last.length != 3) return false;
    if (groups.length <= 2) return true;

    final middle = groups.sublist(1, groups.length - 1);
    final indian = middle.every((g) => g.length == 2);
    final western = middle.every((g) => g.length == 3);
    return indian || western;
  }
}
