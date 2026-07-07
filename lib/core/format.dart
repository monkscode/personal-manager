import 'package:intl/intl.dart';

final NumberFormat _inrGrouping = NumberFormat.decimalPattern('en_IN');

/// Formats a number as Indian Rupees with lakh-style grouping, e.g. `₹1,50,000`.
/// Mirrors the design's `INR = n => '₹' + Math.round(n).toLocaleString('en-IN')`.
String inr(num n) => '₹${_inrGrouping.format(n.round())}';
