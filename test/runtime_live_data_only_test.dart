import 'dart:io';

import 'package:expense_insight/app.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('production sources contain no former prototype records', () {
    final source = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    for (final forbidden in [
      'Use sample data instead',
      '247 scanned from Gmail',
      'Life Insurance Premium',
      "institution: 'HDFC Bank'",
      "name: 'Swiggy'",
      'kTransactions',
      'kInvestments',
      'kBills',
      'AI extraction failed',
    ]) {
      expect(source, isNot(contains(forbidden)), reason: forbidden);
    }
  });

  testWidgets('fresh production app contains only live empty states', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'expense_insight_state_v1': const AppState(
        stage: 'app',
        tab: 'home',
      ).encode(),
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const ExpenseInsightApp(),
      ),
    );
    await tester.pumpAndSettle();

    const forbidden = [
      'Aarav Mehta',
      'Sample user',
      'Sample data',
      'Using sample data',
      '247 scanned from Gmail',
      'Life Insurance Premium',
      'HDFC Bank',
      'Swiggy',
    ];
    void expectNoPrototypeContent() {
      for (final text in forbidden) {
        expect(find.textContaining(text), findsNothing, reason: text);
      }
    }

    expectNoPrototypeContent();
    expect(find.text('No financial data yet'), findsOneWidget);

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expectNoPrototypeContent();
    expect(find.text('No transactions yet'), findsOneWidget);

    await tester.tap(find.text('Insights'));
    await tester.pumpAndSettle();
    expectNoPrototypeContent();
    expect(find.text('No insights yet'), findsOneWidget);

    await tester.tap(find.text('Invest'));
    await tester.pumpAndSettle();
    expectNoPrototypeContent();
    expect(find.text('No investments added'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expectNoPrototypeContent();
    expect(find.text('Connect Gmail'), findsOneWidget);
  });
}
