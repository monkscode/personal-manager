import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/real_insights.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed "today" so month math is deterministic: 7 Jul 2026 → next month = August.
final _now = DateTime(2026, 7, 7);

AppState _stateWith(List<ExpenseEntry> bills, {String monthView = 'next'}) {
  return const AppState().copyWith(
    manualTx: bills,
    monthView: monthView,
    // Isolate the bills from the onboarding contribution defaults.
    nps: const ContribPlan(enabled: false, amount: '0', frequency: 'monthly', month: 'Feb'),
    ppf: const ContribPlan(enabled: false, amount: '0', frequency: 'lumpsum', month: 'Feb'),
    mf: const ContribPlan(enabled: false, amount: '0', frequency: 'monthly', month: 'Feb'),
    salary: '85000',
    currentBalance: '38000',
  );
}

final _lic = ExpenseEntry(
  name: 'LIC',
  category: 'Insurance',
  categoryKey: 'insurance',
  amount: 47000,
  initial: 'LI',
  color: AppColors.amber,
  recurrence: 'annual',
  dueDate: DateTime(2026, 8, 14),
);
const _rent = ExpenseEntry(
  name: 'Rent',
  category: 'Housing',
  categoryKey: 'housing',
  amount: 18000,
  initial: 'HR',
  color: AppColors.blue,
  recurrence: 'monthly',
);

void main() {
  group('real forecast', () {
    test('next month = August includes the annual premium + monthly rent', () {
      final i = computeRealInsights(_stateWith([_lic, _rent]), nowOverride: _now);
      expect(i.febRequired, 65000); // 47000 (Aug annual) + 18000 (monthly)
      expect(i.heroAmount, '₹65,000');
      expect(i.breakdownMonthLabel, 'August');
      expect(i.janRemaining, 18000); // this month (July): only rent
    });

    test('the annual premium only lands in its due month', () {
      final i = computeRealInsights(_stateWith([_lic, _rent]), nowOverride: _now);
      // 12-month outlook: August is the peak; a plain month is just the rent.
      expect(i.yearForecast.length, 12);
      expect(i.peakMonthLabel.startsWith('Aug'), isTrue);
    });

    test('current-month view shows only what is due this month', () {
      final i = computeRealInsights(_stateWith([_lic, _rent], monthView: 'current'), nowOverride: _now);
      expect(i.heroAmount, '₹18,000');
      expect(i.breakdownMonthLabel, 'July');
    });

    test('balance check projects a surplus from salary + balance', () {
      final i = computeRealInsights(_stateWith([_lic, _rent]), nowOverride: _now);
      // available = 38000 + 85000 - 18000 (this month) = 105000; result = 105000 - 65000
      expect(i.balanceResultLabel, 'Projected surplus');
      expect(i.balanceResultAmount, '+₹40,000');
    });

    test('category breakdown ranks the biggest obligation first', () {
      final i = computeRealInsights(_stateWith([_lic, _rent]), nowOverride: _now);
      expect(i.categoriesFull.first.name, 'Insurance');
      expect(i.categoriesFull.map((c) => c.name), contains('Housing'));
    });

    test('upcoming bills are ordered by their next due date', () {
      final i = computeRealInsights(_stateWith([_lic, _rent]), nowOverride: _now);
      // Rent recurs on the 1st (Aug 1) before the LIC premium (Aug 14).
      expect(i.upcomingBills.first.name, 'Rent');
      expect(i.upcomingBills.length, 2);
    });
  });
}
