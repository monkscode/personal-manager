import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'data/app_controller.dart';
import 'features/app/app_shell.dart';
import 'features/onboarding/connect_screen.dart';
import 'features/onboarding/income_screen.dart';
import 'features/onboarding/invest_plan_screen.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/onboarding/privacy_screen.dart';
import 'features/onboarding/review_screen.dart';
import 'features/onboarding/scanning_screen.dart';

class ExpenseInsightApp extends ConsumerWidget {
  const ExpenseInsightApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(appControllerProvider.select((s) => s.isDark));
    return MaterialApp(
      title: 'Expense Insight',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(isDark ? AppPalette.dark : AppPalette.light),
      home: const _Root(),
    );
  }
}

class _Root extends ConsumerWidget {
  const _Root();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = ref.watch(appControllerProvider.select((s) => s.stage));
    if (stage == 'app') return const AppShell();

    final Widget screen = switch (stage) {
      'privacy' => const PrivacyScreen(),
      'income' => const IncomeScreen(),
      'investPlan' => const InvestPlanScreen(),
      'connect' => const ConnectScreen(),
      'scanning' => const ScanningScreen(),
      'review' => const ReviewScreen(),
      _ => const OnboardingScreen(),
    };

    return Scaffold(
      backgroundColor: context.palette.bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: KeyedSubtree(key: ValueKey(stage), child: screen),
        ),
      ),
    );
  }
}
