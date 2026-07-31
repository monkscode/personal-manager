import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';

class IncomeScreen extends ConsumerStatefulWidget {
  const IncomeScreen({super.key});

  @override
  ConsumerState<IncomeScreen> createState() => _IncomeScreenState();
}

class _IncomeScreenState extends ConsumerState<IncomeScreen> {
  late final TextEditingController _salary;
  late final TextEditingController _balance;

  @override
  void initState() {
    super.initState();
    final s = ref.read(appControllerProvider);
    _salary = TextEditingController(text: s.salary);
    _balance = TextEditingController(text: s.currentBalance);
  }

  @override
  void dispose() {
    _salary.dispose();
    _balance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final ctrl = ref.read(appControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: ctrl.skipToApp,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Skip',
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textTertiary,
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.teal.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.currency_rupee_rounded,
              size: 30,
              color: AppColors.teal,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Your income & balance',
            style: jakarta(
              size: 24,
              weight: FontWeight.w800,
              height: 1.3,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "So we can tell you exactly if you'll be short, or have room to spare.",
            style: jakarta(
              size: 14,
              weight: FontWeight.w500,
              height: 1.6,
              color: p.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          const FieldLabel('Monthly take-home salary (₹)'),
          AppTextField(
            controller: _salary,
            hint: 'Enter monthly income',
            mono: true,
            number: true,
            onChanged: ctrl.setSalary,
          ),
          const SizedBox(height: 16),
          const FieldLabel('Current bank balance (₹)'),
          AppTextField(
            controller: _balance,
            hint: 'Enter current balance',
            mono: true,
            number: true,
            onChanged: ctrl.setCurrentBalance,
          ),
          const Spacer(),
          PrimaryButton(label: 'Continue', onTap: ctrl.goInvestPlan),
        ],
      ),
    );
  }
}
