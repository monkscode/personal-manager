import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppState persistence', () {
    test('fresh state has no prototype financial values', () {
      const state = AppState();

      expect(state.salary, isEmpty);
      expect(state.currentBalance, isEmpty);
      for (final plan in [state.nps, state.ppf, state.mf]) {
        expect(plan.enabled, isFalse);
        expect(plan.amount, '0');
      }
    });

    test('Gmail identity round-trips', () {
      final state = const AppState().copyWith(
        gmailEmail: 'person@example.com',
        gmailName: 'Person',
      );

      final restored = AppState.decode(state.encode());

      expect(restored.gmailEmail, 'person@example.com');
      expect(restored.gmailName, 'Person');
    });

    test('Gmail sync metadata round-trips', () {
      final restored = AppState.fromJson({
        'gmailLastSyncedAt': '2026-07-21T12:30:00.000Z',
        'gmailLastFetchedCount': 87,
      });

      expect(
        restored.toJson()['gmailLastSyncedAt'],
        '2026-07-21T12:30:00.000Z',
      );
      expect(restored.toJson()['gmailLastFetchedCount'], 87);
    });

    test(
      'legacy payload preserves saved financial data without Gmail keys',
      () {
        final restored = AppState.fromJson({
          'stage': 'app',
          'salary': '123456',
          'currentBalance': '654321',
          'manualTx': const [],
          'manualInvestments': const [],
          'nps': const ContribPlan(
            enabled: false,
            amount: '0',
            frequency: 'monthly',
            month: 'Feb',
          ).toJson(),
        });

        expect(restored.salary, '123456');
        expect(restored.currentBalance, '654321');
        expect(restored.gmailEmail, isEmpty);
        expect(restored.gmailName, isEmpty);
      },
    );
  });
}
