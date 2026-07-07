import 'package:expense_insight/app.dart';
import 'package:expense_insight/data/app_controller.dart';
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

    // Skipping jumps straight into the home dashboard.
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Balance check · next month'), findsOneWidget);
  });
}
