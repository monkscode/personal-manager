import 'package:intl/intl.dart';

final NumberFormat _inrGrouping = NumberFormat.decimalPattern('en_IN');

/// Formats a number as Indian Rupees with lakh-style grouping, e.g. `₹1,50,000`.
/// Mirrors the design's `INR = n => '₹' + Math.round(n).toLocaleString('en-IN')`.
String inr(num n) => '₹${_inrGrouping.format(n.round())}';

/// Formats a plain count with the same lakh-style grouping, without a currency
/// mark — e.g. `1,500`. For things that are counted rather than owed.
String grouped(int n) => _inrGrouping.format(n);

/// Up to two-letter avatar initials from a display name, e.g. "Dhruvil Vyas" → "DV".
String initials(String name) {
  final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '';
  if (words.length == 1) return words[0].substring(0, words[0].length >= 2 ? 2 : 1).toUpperCase();
  return (words[0][0] + words[1][0]).toUpperCase();
}
