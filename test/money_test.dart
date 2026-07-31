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
