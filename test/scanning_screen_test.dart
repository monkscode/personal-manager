import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/features/onboarding/scanning_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final class _ScanningAppController extends AppController {
  @override
  AppState build() =>
      const AppState(stage: 'scanning', scanProgress: 7, scanCount: 176);
}

void main() {
  testWidgets('Gmail progress labels fetched messages as emails', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appControllerProvider.overrideWith(_ScanningAppController.new),
        ],
        child: MaterialApp(
          theme: buildTheme(AppPalette.dark),
          home: const Scaffold(body: ScanningScreen()),
        ),
      ),
    );

    expect(find.text('176'), findsOneWidget);
    expect(find.text(' emails scanned so far'), findsOneWidget);
    expect(find.textContaining('transactions found'), findsNothing);
  });
}
