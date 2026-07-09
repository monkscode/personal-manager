import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/services/ai_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

RawEmail _e(String id, String from, String subject) =>
    RawEmail(id: id, from: from, subject: subject, date: DateTime(2026, 1, 20));

void main() {
  final emails = [
    _e('m0', 'LIC <no-reply@licindia.com>', 'Premium reminder'),
    _e('m1', 'Amazon <deals@amazon.in>', 'Sale'),
    _e('m2', 'Netflix <info@netflix.com>', 'Your bill'),
  ];

  group('GeminiResolver.mapItems', () {
    test('maps AI JSON to bills, mapping index back to the source email', () {
      const json = '''
      [
        {"index":0,"isBill":true,"merchant":"LIC of India","amount":47000,"dueDate":"2026-02-14","category":"insurance","recurrence":"annual"},
        {"index":2,"isBill":true,"merchant":"Netflix","amount":649,"dueDate":"","category":"subscriptions","recurrence":"monthly"}
      ]''';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.length, 2);
      expect(bills[0].sourceId, 'm0');
      expect(bills[0].merchant, 'LIC of India');
      expect(bills[0].amount, 47000);
      expect(bills[0].dueDate, DateTime(2026, 2, 14));
      expect(bills[0].categoryKey, 'insurance');
      expect(bills[0].recurrence, 'annual');
      expect(bills[1].sourceId, 'm2');
      expect(bills[1].dueDate, isNull);
      expect(bills.every((b) => b.confidence > 0.8), isTrue);
    });

    test('drops non-bills but keeps genuine bills that have no amount', () {
      const json = '''
      [
        {"index":1,"isBill":false,"amount":0},
        {"index":0,"isBill":true,"merchant":"X","amount":0,"category":"other","recurrence":"onetime"}
      ]''';
      // isBill:false is dropped; the amountless bill is kept with amount 0
      // ("not detected") so the rule-based backstop / review can supply the
      // figure — dropping it here is what made real reminder bills vanish.
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.merchant, 'X');
      expect(bills.single.amount, 0);
      expect(bills.single.sourceId, 'm0');
    });

    test('normalizes unknown category/recurrence to safe defaults', () {
      const json = '[{"index":0,"isBill":true,"merchant":"X","amount":100,"category":"weird","recurrence":"nonsense"}]';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.categoryKey, 'other');
      expect(bills.single.recurrence, 'onetime');
    });

    test('tolerates markdown code fences and stringified amounts', () {
      const json = '```json\n[{"index":2,"isBill":true,"merchant":"Netflix","amount":"₹649","category":"subscriptions","recurrence":"monthly"}]\n```';
      final bills = GeminiResolver.mapItems(json, emails);
      expect(bills.single.amount, 649);
      expect(bills.single.merchant, 'Netflix');
    });

    test('throws AiException on non-JSON output', () {
      expect(() => GeminiResolver.mapItems('sorry, I could not help', emails), throwsA(isA<AiException>()));
    });
  });
}
