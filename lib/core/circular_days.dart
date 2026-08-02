/// Day-of-month arithmetic on a circle.
///
/// A month boundary is a wrap, not a gap: a payment that normally lands on the
/// 1st but occasionally on the 31st of the prior month has drifted by a day,
/// not by thirty. Measured linearly it looks like a month of instability, which
/// is enough to make a salary date — and the minimum-balance planning built on
/// it — meaningless.
library;

/// Smallest arc (in day units) covering all [values] on a circle of [modulus]
/// days. Returns 0 for fewer than two values.
int circularDaySpread(List<int> values, int modulus) {
  final sorted = [...values]..sort();
  if (sorted.length <= 1) return 0;
  var maxGap = modulus - (sorted.last - sorted.first);
  for (var i = 1; i < sorted.length; i++) {
    final gap = sorted[i] - sorted[i - 1];
    if (gap > maxGap) maxGap = gap;
  }
  return modulus - maxGap;
}
