import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/features/app/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpProfile(WidgetTester tester, AppState state) async {
  SharedPreferences.setMockInitialValues({
    'expense_insight_state_v1': state.encode(),
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: buildTheme(AppPalette.dark),
        home: const Scaffold(body: ProfileScreen()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('disconnected Profile offers connect without sample identity', (
    tester,
  ) async {
    await _pumpProfile(tester, const AppState(stage: 'app', tab: 'profile'));

    expect(find.text('Your profile'), findsOneWidget);
    expect(find.text('Connect Gmail'), findsOneWidget);
    expect(find.text('Disconnect'), findsNothing);
    expect(find.textContaining('Sample'), findsNothing);
  });

  testWidgets('connected Profile offers Sync again and explicit Disconnect', (
    tester,
  ) async {
    await _pumpProfile(
      tester,
      AppState(
        stage: 'app',
        tab: 'profile',
        gmailEmail: 'person@example.com',
        gmailName: 'Person',
        gmailLastSyncedAt: DateTime.utc(2026, 7, 21, 12, 30),
        gmailLastFetchedCount: 87,
      ),
    );

    expect(find.text('Person'), findsOneWidget);
    expect(find.text('person@example.com'), findsOneWidget);
    expect(find.text('Sync again'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.textContaining('87 fetched'), findsOneWidget);
  });
}
