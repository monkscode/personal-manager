import 'package:expense_insight/core/clamped_date.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampedDate', () {
    test('day 31 returns each month\'s real last day in a non-leap year', () {
      const lastDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
      for (var month = 1; month <= 12; month++) {
        final date = clampedDate(2026, month, 31);
        expect(date.year, 2026, reason: 'month $month rolled into another year');
        expect(date.month, month, reason: 'month $month rolled over');
        expect(date.day, lastDays[month - 1], reason: 'month $month last day');
      }
    });

    test('February 29 clamps to the 28th in a non-leap year', () {
      expect(clampedDate(2026, 2, 29), DateTime(2026, 2, 28));
    });

    test('February 29 is kept in a leap year', () {
      expect(clampedDate(2028, 2, 29), DateTime(2028, 2, 29));
    });

    test('day 0 and negative days clamp to the first of the month', () {
      expect(clampedDate(2026, 3, 0), DateTime(2026, 3, 1));
      expect(clampedDate(2026, 3, -5), DateTime(2026, 3, 1));
    });

    test('an in-range day is returned unchanged', () {
      expect(clampedDate(2026, 8, 20), DateTime(2026, 8, 20));
    });

    test('a month past December rolls the year but still clamps the day', () {
      // Callers advance a cadence with `month + n`; Dart normalises the month,
      // and the day must be clamped against the normalised month.
      expect(clampedDate(2026, 13, 31), DateTime(2027, 1, 31));
      expect(clampedDate(2026, 14, 31), DateTime(2027, 2, 28));
    });
  });
}
