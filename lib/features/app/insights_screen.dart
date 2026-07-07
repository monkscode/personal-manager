import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../widgets/ui.dart';

class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final i = ref.watch(insightsProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text('Forecast & insights', style: jakarta(size: 21, weight: FontWeight.w800, color: p.textPrimary)),
        const SizedBox(height: 20),
        // 6-month trend + forecast
        Surface(
          radius: 20,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Monthly total, last 6 months + forecast',
                  style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
              const SizedBox(height: 16),
              SizedBox(
                height: 188,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 8,
                  children: [
                    for (final bar in i.chartBars)
                      ChartBar(height: bar.height, color: bar.color, label: bar.label, tag: bar.tag, radius: 4),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // 12-month outlook
        Surface(
          radius: 20,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('12-month outlook', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
                  Flexible(
                    child: Text('Peak: ${i.peakMonthLabel}',
                        textAlign: TextAlign.right,
                        style: jakarta(size: 11, weight: FontWeight.w600, color: p.textTertiary)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 146,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 4,
                  children: [
                    for (final bar in i.yearForecast)
                      ChartBar(height: bar.height, color: bar.color, label: bar.label),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: p.border),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Projected total this year', style: jakarta(size: 12, weight: FontWeight.w600, color: p.textSecondary)),
                  Text(i.yearTotalLabel, style: mono(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Why February is higher
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppColors.amber.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Why February is higher', style: jakarta(size: 13, weight: FontWeight.w700, color: AppColors.amber)),
              const SizedBox(height: 8),
              Text(i.driverAmount, style: mono(size: 26, weight: FontWeight.w800, color: p.textPrimary)),
              const SizedBox(height: 8),
              Text(i.driverText, style: jakarta(size: 13, weight: FontWeight.w500, height: 1.6, color: p.textPrimary)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Full breakdown
        Text('February breakdown — full', style: jakarta(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
        const SizedBox(height: 12),
        for (final c in i.categoriesFull) ...[
          CategoryProgress(name: c.name, color: c.color, amount: '${c.amount} · ${c.pct.round()}%', pct: c.pct),
          const SizedBox(height: 14),
        ],
        const SizedBox(height: 6),
        // Alerts
        Text('Alerts', style: jakarta(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
        const SizedBox(height: 12),
        for (final al in i.alerts) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: al.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: al.border)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    al.isPositive ? Icons.check_rounded : Icons.warning_amber_rounded,
                    size: 20,
                    color: al.isPositive ? AppColors.green : al.iconColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(al.text, style: jakarta(size: 13, weight: FontWeight.w500, height: 1.5, color: p.textPrimary)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}
