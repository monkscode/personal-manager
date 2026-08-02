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

  group('AnchorSelector.select — future-dated anchors (M1)', () {
    test('a future-dated SMS anchor loses to a real manual entry', () {
      // One bad SMS timestamp. `freshnessAsOf` reads a negative age as
      // `current`, so without a `now` check this anchor is permanently fresh
      // and permanently newest — it would pin the opening balance to a reading
      // that never happened.
      final s = smsAnchor(asOf: DateTime(2026, 7, 24), amountPaise: 999900);
      final m = manualAnchor(asOf: DateTime(2026, 7, 8));

      final selected = AnchorSelector.select(
        smsAnchor: s,
        manualAnchor: m,
        now: now,
      );

      expect(selected, same(m));
      expect(selected!.amountPaise, 200000);
    });

    test('a future-dated manual entry loses to an older SMS balance', () {
      final s = smsAnchor(asOf: DateTime(2026, 7, 2));
      final m = manualAnchor(asOf: DateTime(2026, 7, 11));

      expect(
        AnchorSelector.select(smsAnchor: s, manualAnchor: m, now: now),
        same(s),
      );
    });

    test('when both anchors are future-dated there is no anchor at all', () {
      expect(
        AnchorSelector.select(
          smsAnchor: smsAnchor(asOf: DateTime(2026, 7, 11)),
          manualAnchor: manualAnchor(asOf: DateTime(2026, 8, 1)),
          now: now,
        ),
        isNull,
      );
    });

    test('an anchor stamped exactly at now is kept', () {
      final s = smsAnchor(asOf: now);

      expect(AnchorSelector.select(smsAnchor: s, now: now), same(s));
    });
  });
}
