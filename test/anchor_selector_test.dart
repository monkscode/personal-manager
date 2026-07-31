import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/services/anchor_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 7, 10);

  BalanceAnchor smsAnchor({
    required DateTime asOf,
    int amountPaise = 100000,
    String? last4 = '1234',
  }) => BalanceAnchor(
    amountPaise: amountPaise,
    asOf: asOf,
    accountLast4: last4,
    source: BalanceAnchorSource.smsBankBalance,
  );

  BalanceAnchor manualAnchor({
    required DateTime asOf,
    int amountPaise = 200000,
  }) => BalanceAnchor(
    amountPaise: amountPaise,
    asOf: asOf,
    source: BalanceAnchorSource.manualUserEntry,
  );

  group('AnchorSelector.select', () {
    test('returns null when neither anchor is present', () {
      expect(AnchorSelector.select(now: now), isNull);
    });

    test('returns the only anchor that is present', () {
      final s = smsAnchor(asOf: DateTime(2026, 7, 8));
      final m = manualAnchor(asOf: DateTime(2026, 7, 8));

      expect(AnchorSelector.select(smsAnchor: s, now: now), same(s));
      expect(AnchorSelector.select(manualAnchor: m, now: now), same(m));
    });

    test('a manual entry from today beats an SMS balance from three days ago', () {
      final s = smsAnchor(asOf: DateTime(2026, 7, 7));
      final m = manualAnchor(asOf: DateTime(2026, 7, 10));

      final selected = AnchorSelector.select(smsAnchor: s, manualAnchor: m, now: now);

      expect(selected, same(m));
      expect(selected!.source, BalanceAnchorSource.manualUserEntry);
    });

    test('an SMS balance from today beats a manual entry from three days ago', () {
      final s = smsAnchor(asOf: DateTime(2026, 7, 10));
      final m = manualAnchor(asOf: DateTime(2026, 7, 7));

      final selected = AnchorSelector.select(smsAnchor: s, manualAnchor: m, now: now);

      expect(selected, same(s));
      expect(selected!.source, BalanceAnchorSource.smsBankBalance);
    });

    test('on an exact timestamp tie the SMS bank balance wins', () {
      final asOf = DateTime(2026, 7, 9, 12);
      final s = smsAnchor(asOf: asOf);
      final m = manualAnchor(asOf: asOf);

      final selected = AnchorSelector.select(smsAnchor: s, manualAnchor: m, now: now);

      expect(selected, same(s));
      expect(selected!.source, BalanceAnchorSource.smsBankBalance);
    });
  });
}
