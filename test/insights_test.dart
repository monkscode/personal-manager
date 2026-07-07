import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('inr formatting', () {
    test('uses Indian lakh grouping with a rupee symbol', () {
      expect(inr(47000), '₹47,000');
      expect(inr(209800), '₹2,09,800');
      expect(inr(1500000), '₹15,00,000');
    });

    test('rounds to the nearest whole rupee', () {
      expect(inr(46999.6), '₹47,000');
    });
  });

  group('Insights.compute — required balance', () {
    test('default setup: February required = base + NPS + PPF + MF', () {
      // 94800 base + 5000 NPS (monthly) + 100000 PPF (lump, Feb) + 10000 MF (monthly)
      final i = Insights.compute(const AppState());
      expect(i.febRequired, 209800);
      expect(i.heroAmount, '₹2,09,800');
    });

    test('January remaining is required minus spent-so-far', () {
      final i = Insights.compute(const AppState());
      expect(i.janRemaining, 14250); // 46700 - 32450
    });

    test('a lump-sum landing outside February does not count toward Feb', () {
      final s = const AppState().copyWith(
        ppf: const ContribPlan(enabled: true, amount: '100000', frequency: 'lumpsum', month: 'Apr'),
      );
      final i = Insights.compute(s);
      // PPF now lands in April, so February drops by 100000.
      expect(i.febRequired, 109800);
    });

    test('disabling a plan removes its contribution', () {
      final s = const AppState().copyWith(
        mf: const ContribPlan(enabled: false, amount: '10000', frequency: 'monthly', month: 'Feb'),
      );
      final i = Insights.compute(s);
      expect(i.febRequired, 199800); // 209800 - 10000
    });

    test('FD round-off plan adds its monthly top-up to February', () {
      final base = Insights.compute(const AppState());
      final withPlan = Insights.compute(const AppState().copyWith(fdRoundoffChoice: 'yes'));
      // ceil((200000-182000)/3) = 6000
      expect(withPlan.febRequired - base.febRequired, 6000);
    });

    test('a custom monthly plan increases the February total', () {
      final s = const AppState().copyWith(customPlans: [
        const CustomPlan(id: 'c1', name: 'Sukanya', amount: 2000, frequency: 'monthly', month: 'Feb'),
      ]);
      final i = Insights.compute(s);
      expect(i.febRequired, 211800); // 209800 + 2000
    });
  });

  group('Insights.compute — balance check & forecast', () {
    test('projects a February shortfall for the default salary/balance', () {
      final i = Insights.compute(const AppState());
      // febAvailable = 38000 + 85000 - 14250 = 108750; result = 108750 - 209800
      expect(i.balanceResultLabel, 'Projected shortfall');
      expect(i.balanceResultColor, isNot(null));
      expect(i.balanceResultAmount, '-₹1,01,050');
    });

    test('12-month forecast has an actual January and a February peak', () {
      final i = Insights.compute(const AppState());
      expect(i.yearForecast.length, 12);
      expect(i.peakMonthLabel.startsWith('Feb'), isTrue);
    });

    test('the top-category list is capped at five, full list is not', () {
      final i = Insights.compute(const AppState());
      expect(i.categoriesTop.length, 5);
      expect(i.categoriesFull.length, greaterThan(5));
      // With the default PPF lump sum (₹1,00,000) landing in Feb, it is the
      // single largest category, ahead of the ₹47,000 insurance premium.
      expect(i.categoriesFull.first.name, 'PPF');
      expect(i.categoriesFull.map((c) => c.name), contains('Insurance'));
    });
  });
}
