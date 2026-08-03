import 'package:expense_insight/core/money.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MoneyParser.parseRupeesToPaise', () {
    test('parses Indian currency text into integer paise without floats', () {
      expect(MoneyParser.parseRupeesToPaise('₹1,23,456.78'), 12345678);
      expect(MoneyParser.parseRupeesToPaise('Rs. 10.5'), 1050);
      expect(MoneyParser.parseRupeesToPaise('INR 1,000'), 100000);
    });

    test('rounds only when a third decimal digit is present', () {
      expect(MoneyParser.parseRupeesToPaise('10.994'), 1099);
      expect(MoneyParser.parseRupeesToPaise('10.995'), 1100);
      expect(MoneyParser.parseRupeesToPaise('10.999'), 1100);
    });

    test('rejects negative or ambiguous amount text', () {
      expect(
        () => MoneyParser.parseRupeesToPaise('-10'),
        throwsFormatException,
      );
      expect(
        () => MoneyParser.parseRupeesToPaise('Rs. 10 and Rs. 20'),
        throwsFormatException,
      );
      expect(
        () => MoneyParser.parseRupeesToPaise('ten rupees'),
        throwsFormatException,
      );
    });
  });

  // TASK-22 guards. These pass against the parser as it already stands — they
  // exist so the grouping and overflow rules cannot regress once
  // `_manualAnchor` starts depending on them. They are not regression coverage
  // for a defect.
  group('MoneyParser.tryParseRupeesToPaise — grouping and range guards', () {
    test('rejects malformed grouping', () {
      expect(MoneyParser.tryParseRupeesToPaise('1,2345'), isNull);
      expect(MoneyParser.tryParseRupeesToPaise('1,23,4567'), isNull);
      expect(MoneyParser.tryParseRupeesToPaise('12,3,456'), isNull);
    });

    test('accepts Indian digit grouping', () {
      expect(MoneyParser.tryParseRupeesToPaise('12,34,567'), 123456700);
      expect(MoneyParser.tryParseRupeesToPaise('1,20,000'), 12000000);
    });

    test('accepts Western digit grouping', () {
      expect(MoneyParser.tryParseRupeesToPaise('1,234,567'), 123456700);
    });

    test('rejects a value that would overflow int64 paise rather than '
        'wrapping it', () {
      // 92233720368547758.07 rupees is the largest representable amount.
      expect(
        MoneyParser.tryParseRupeesToPaise('92233720368547758.07'),
        9223372036854775807,
      );
      expect(MoneyParser.tryParseRupeesToPaise('92233720368547758.08'), isNull);
      expect(MoneyParser.tryParseRupeesToPaise('92233720368547759'), isNull);
      // Wider than int64 can even parse.
      expect(
        MoneyParser.tryParseRupeesToPaise('99999999999999999999999'),
        isNull,
      );
    });

    test('rejects scientific notation', () {
      expect(MoneyParser.tryParseRupeesToPaise('1e9'), isNull);
    });
  });

  group('MoneyParser.paiseFromRupeeNumber', () {
    test(
      'converts legacy numeric boundary values through a fixed decimal string',
      () {
        expect(MoneyParser.paiseFromRupeeNumber(0.29), 29);
        expect(MoneyParser.paiseFromRupeeNumber(47000), 4700000);
        expect(MoneyParser.paiseFromRupeeNumber(10.995), 1100);
      },
    );
  });
}
