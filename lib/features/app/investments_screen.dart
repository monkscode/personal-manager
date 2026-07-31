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
    final i = ref.watch(insightsProvider);

    if (i.investments.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        children: [
          Text(
            'Investments',
            style: jakarta(
              size: 21,
              weight: FontWeight.w800,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Your deposits and contribution plans',
            style: jakarta(
              size: 13,
              weight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            radius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(
                  Icons.trending_up_rounded,
                  size: 34,
                  color: p.textSecondary,
                ),
                const SizedBox(height: 12),
                Text(
                  'No investments added',
                  style: jakarta(
                    size: 16,
                    weight: FontWeight.w800,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                PrimaryButton(
                  label: 'Add investment',
                  onTap: () => showAddSheet(context, ref, type: 'investment'),
                  icon: const Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: AppColors.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text(
          'Investments',
          style: jakarta(
            size: 21,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'FDs, PPF & recurring deposits',
          style: jakarta(
            size: 13,
            weight: FontWeight.w500,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 20),
        // Total invested
        Surface(
          radius: 20,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Total invested',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w600,
                  color: p.textTertiary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                i.investTotal,
                style: mono(
                  size: 32,
                  weight: FontWeight.w800,
                  color: p.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              'All investments',
              style: jakarta(
                size: 15,
                weight: FontWeight.w700,
                color: p.textPrimary,
              ),
            ),
            GestureDetector(
              onTap: () => showAddSheet(context, ref, type: 'investment'),
              child: Text(
                '+ Add',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w600,
                  color: AppColors.teal,
                ),
              ),
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
                decoration: BoxDecoration(
                  color: inv.bgColor,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Text(
                  inv.type,
                  style: jakarta(
                    size: 11,
                    weight: FontWeight.w700,
                    color: inv.color,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      inv.institution,
                      style: jakarta(
                        size: 14,
                        weight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    Text(
                      '${inv.rate} · matures ${inv.maturity}',
                      style: jakarta(
                        size: 12,
                        weight: FontWeight.w500,
                        color: p.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: inv.statusBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  inv.status,
                  style: jakarta(
                    size: 10,
                    weight: FontWeight.w600,
                    color: inv.statusColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            inv.principal,
            style: mono(
              size: 18,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

}
