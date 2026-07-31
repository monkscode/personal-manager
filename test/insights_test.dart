import 'package:expense_insight/core/format.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

final _now = DateTime(2026, 1, 15);

AppState _plannedState({
  bool mfEnabled = true,
  String ppfMonth = 'Feb',
  List<CustomPlan> customPlans = const [],
  String salary = '',
  String balance = '',
}) => AppState(
  salary: salary,
  currentBalance: balance,
  nps: const ContribPlan(
    enabled: true,
    amount: '5000',
    frequency: 'monthly',
    month: 'Feb',
  ),
  ppf: ContribPlan(
    enabled: true,
    amount: '100000',
    frequency: 'lumpsum',
    month: ppfMonth,
  ),
  mf: ContribPlan(
    enabled: mfEnabled,
    amount: '10000',
    frequency: 'monthly',
    month: 'Feb',
  ),
  customPlans: customPlans,
);

void main() {
  group('INR formatting', () {
    test('uses Indian lakh grouping and rounds to a whole rupee', () {
      expect(inr(47000), '₹47,000');
      expect(inr(1500000), '₹15,00,000');
      expect(inr(46999.6), '₹47,000');
    });
  });

  group('Insights.compute live values', () {
    test('fresh state contains zero values and no user records', () {
      final insights = Insights.compute(const AppState(), now: _now);

      expect(insights.febRequired, 0);
      expect(insights.janRemaining, 0);
      expect(insights.heroAmount, '₹0');
      expect(insights.categoriesFull, isEmpty);
      expect(insights.upcomingBills, isEmpty);
      expect(insights.dateGroups, isEmpty);
      expect(insights.investments, isEmpty);
    });

    test('next month includes only configured user contributions', () {
      final insights = Insights.compute(_plannedState(), now: _now);

      expect(insights.febRequired, 115000);
      expect(insights.heroAmount, '₹1,15,000');
      expect(insights.categoriesFull.map((row) => row.name), {
        'PPF',
        'Mutual Fund',
        'NPS',
      });
    });

    test('lump sum outside next month is excluded', () {
      final insights = Insights.compute(
        _plannedState(ppfMonth: 'Apr'),
        now: _now,
      );

      expect(insights.febRequired, 15000);
    });

    test('disabled plan is excluded', () {
      final insights = Insights.compute(
        _plannedState(mfEnabled: false),
        now: _now,
      );

      expect(insights.febRequired, 105000);
    });

    test('custom monthly plan increases next-month total', () {
      final insights = Insights.compute(
        _plannedState(
          customPlans: const [
            CustomPlan(
              id: 'c1',
              name: 'Education fund',
              amount: 2000,
              frequency: 'monthly',
              month: 'Feb',
            ),
          ],
        ),
        now: _now,
      );

      expect(insights.febRequired, 117000);
    });

    test('balance result uses entered salary and balance', () {
      final insights = Insights.compute(
        _plannedState(salary: '50000', balance: '0'),
        now: _now,
      );

      expect(insights.balanceResultLabel, 'Projected shortfall');
      expect(insights.balanceResultAmount, '-₹80,000');
    });

    test('forecast covers 12 real calendar months', () {
      final insights = Insights.compute(_plannedState(), now: _now);

      expect(insights.yearForecast, hasLength(12));
      expect(insights.peakMonthLabel, startsWith('Feb'));
    });
  });
}
