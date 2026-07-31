import 'package:expense_insight/app.dart';
import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('boots into onboarding and skips into the app', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const ExpenseInsightApp(),
      ),
    );
    await tester.pump();

    // First onboarding slide is visible.
    expect(find.text('Your inbox already knows your expenses'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);

    // Skipping enters the app without inventing financial data.
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome'), findsOneWidget);
    expect(find.text('No financial data yet'), findsOneWidget);
    expect(find.text('Balance check · next month'), findsNothing);
  });

  testWidgets('renders the real forecast when confirmed obligations exist', (
    tester,
  ) async {
    // One monthly ₹18,000 rent, contributions disabled → next month is exactly
    // ₹18,000 regardless of the real calendar date (deterministic hero).
    final seeded = const AppState().copyWith(
      stage: 'app',
      tab: 'home',
      nps: const ContribPlan(
        enabled: false,
        amount: '0',
        frequency: 'monthly',
        month: 'Feb',
      ),
      ppf: const ContribPlan(
        enabled: false,
        amount: '0',
        frequency: 'lumpsum',
        month: 'Feb',
      ),
      mf: const ContribPlan(
        enabled: false,
        amount: '0',
        frequency: 'monthly',
        month: 'Feb',
      ),
      manualTx: const [
        ExpenseEntry(
          name: 'House Rent',
          category: 'Housing',
          categoryKey: 'housing',
          amount: 18000,
          initial: 'HR',
          color: AppColors.blue,
          recurrence: 'monthly',
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'expense_insight_state_v1': seeded.encode(),
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const ExpenseInsightApp(),
      ),
    );
    await tester.pumpAndSettle();

    // Boots straight into the app and the hero reflects the real obligation
    // (₹18,000), not the demo scenario (₹2,09,800).
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('₹18,000'), findsWidgets);
  });
}
