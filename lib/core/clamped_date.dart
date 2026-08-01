/// Builds a date in [year]/[month], clamping [day] to that month's last day.
///
/// Dart's `DateTime` constructor silently rolls an out-of-range day forward:
/// `DateTime(2026, 2, 30)` is 2026-03-02 and `DateTime(2026, 4, 31)` is
/// 2026-05-01, with no error. A rolled-over event date lands outside its target
/// month, so the reconciliation engine files it as a `futureEarmark` and drops
/// it from the dated ledger — a salary or a rent bill silently disappears.
/// Clamping keeps the event inside the month it belongs to.
///
/// [day] below 1 clamps to the 1st rather than rolling back into the previous
/// month. [month] outside 1-12 is normalised by `DateTime` first (so a caller
/// may advance a cadence with `month + n`), and [day] is clamped against the
/// normalised month.
DateTime clampedDate(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day.clamp(1, lastDay));
}
