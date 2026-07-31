import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TransactionsNotifier.configuredPlansFor', () {
    test('includes enabled NPS/PPF/MF and every custom plan', () {
      final state = const AppState().copyWith(
        nps: const ContribPlan(enabled: true, amount: '5000', frequency: 'monthly', month: 'Feb'),
        ppf: const ContribPlan(enabled: false, amount: '0', frequency: 'lumpsum', month: 'Feb'),
        mf: const ContribPlan(enabled: true, amount: '10000', frequency: 'monthly', month: 'Feb'),
        customPlans: const [
          CustomPlan(id: 'c1', name: 'Chit fund', amount: 8000, frequency: 'monthly', month: 'Feb'),
        ],
      );

      final plans = TransactionsNotifier.configuredPlansFor(state);

      // PPF is disabled and dropped; NPS, MF and the custom plan remain.
      expect(plans, hasLength(3));
      expect(plans.every((p) => p.enabled), isTrue);
      expect(plans.any((p) => p.amountValue == 8000), isTrue);
    });

    test('drops disabled plans entirely', () {
      final state = const AppState().copyWith(
        nps: const ContribPlan(enabled: false, amount: '0', frequency: 'monthly', month: 'Feb'),
        ppf: const ContribPlan(enabled: false, amount: '0', frequency: 'lumpsum', month: 'Feb'),
        mf: const ContribPlan(enabled: false, amount: '0', frequency: 'monthly', month: 'Feb'),
      );

      expect(TransactionsNotifier.configuredPlansFor(state), isEmpty);
    });
  });
}
