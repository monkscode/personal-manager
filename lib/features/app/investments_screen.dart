import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/insights.dart';
import '../../widgets/ui.dart';
import 'add_modal.dart';

class InvestmentsScreen extends ConsumerWidget {
  const InvestmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final choice = ref.watch(appControllerProvider.select((s) => s.fdRoundoffChoice));
    final i = ref.watch(insightsProvider);
    final ctrl = ref.read(appControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text('Investments', style: jakarta(size: 21, weight: FontWeight.w800, color: p.textPrimary)),
        const SizedBox(height: 4),
        Text('FDs, PPF & recurring deposits', style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary)),
        const SizedBox(height: 20),
        // Total invested
        Surface(
          radius: 20,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total invested', style: jakarta(size: 12, weight: FontWeight.w600, color: p.textTertiary)),
              const SizedBox(height: 6),
              Text(i.investTotal, style: mono(size: 32, weight: FontWeight.w800, color: p.textPrimary, letterSpacing: -0.5)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (choice.isEmpty) _roundoffPrompt(context, i, ctrl) else _roundoffDone(context, i, choice, ctrl),
        const SizedBox(height: 16),
        // PPF FY progress (illustrative)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: p.border)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('PPF · FY contribution', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
                  Text('₹90,000 / ₹1,50,000', style: mono(size: 12, weight: FontWeight.w600, color: p.textSecondary)),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: 0.6,
                  minHeight: 6,
                  backgroundColor: p.surfaceAlt,
                  valueColor: const AlwaysStoppedAnimation(AppColors.violet),
                ),
              ),
              const SizedBox(height: 10),
              Text('Contribute the remaining ₹60,000 before Mar 31 to maximize this year\'s 80C deduction.',
                  style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textSecondary)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('All investments', style: jakarta(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
            GestureDetector(
              onTap: () => showAddSheet(context, ref, type: 'investment'),
              child: Text('+ Add', style: jakarta(size: 12, weight: FontWeight.w600, color: AppColors.teal)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final inv in i.investments) ...[
          _investmentCard(context, inv),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _roundoffPrompt(BuildContext context, Insights i, AppController ctrl) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.teal.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.teal.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('HDFC FD matures ${i.fdMaturityDate}', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
          const SizedBox(height: 12),
          Text.rich(TextSpan(children: [
            _t(context, 'Payout will be '),
            _m(i.fdMaturityValue),
            _t(context, '. Round up to '),
            _m(i.fdRenewTarget),
            _t(context, ' by saving '),
            _m(i.fdTopUpAmount),
            _t(context, ' before then? We\'ll spread it as '),
            _m(i.fdMonthlyPlanAmount),
            _t(context, '/month for ${i.fdTopUpMonths} months and add it to your forecast.'),
          ])),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => ctrl.setFdRoundoff('yes'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(color: AppColors.teal, borderRadius: BorderRadius.circular(12)),
                    child: Center(child: Text('Yes, add the plan', style: jakarta(size: 13, weight: FontWeight.w700, color: AppColors.ink))),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => ctrl.setFdRoundoff('no'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: p.borderStrong)),
                    child: Center(child: Text('No, skip', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textSecondary))),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _roundoffDone(BuildContext context, Insights i, String choice, AppController ctrl) {
    final p = context.palette;
    final yes = choice == 'yes';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: yes ? AppColors.green.withValues(alpha: 0.08) : p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: yes ? AppColors.green.withValues(alpha: 0.25) : p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.check_rounded, size: 20, color: yes ? AppColors.green : p.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(i.roundoffDoneText, style: jakarta(size: 13, weight: FontWeight.w600, height: 1.5, color: p.textPrimary)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => ctrl.setFdRoundoff(''),
            child: Text('Change my mind', style: jakarta(size: 12, weight: FontWeight.w600, color: p.textTertiary)),
          ),
        ],
      ),
    );
  }

  Widget _investmentCard(BuildContext context, InvestmentRow inv) {
    final p = context.palette;
    return Surface(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: inv.bgColor, borderRadius: BorderRadius.circular(10)),
                alignment: Alignment.center,
                child: Text(inv.type, style: jakarta(size: 11, weight: FontWeight.w700, color: inv.color)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(inv.institution, style: jakarta(size: 14, weight: FontWeight.w700, color: p.textPrimary)),
                    Text('${inv.rate} · matures ${inv.maturity}',
                        style: jakarta(size: 12, weight: FontWeight.w500, color: p.textTertiary)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(color: inv.statusBg, borderRadius: BorderRadius.circular(8)),
                child: Text(inv.status, style: jakarta(size: 10, weight: FontWeight.w600, color: inv.statusColor)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(inv.principal, style: mono(size: 18, weight: FontWeight.w700, color: p.textPrimary)),
        ],
      ),
    );
  }

  InlineSpan _t(BuildContext context, String text) =>
      TextSpan(text: text, style: jakarta(size: 13, weight: FontWeight.w500, height: 1.6, color: context.palette.textPrimary));
  InlineSpan _m(String text) => TextSpan(text: text, style: mono(size: 13, weight: FontWeight.w600, color: AppColors.teal));
}
