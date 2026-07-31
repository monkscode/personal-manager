import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/insights.dart';
import '../../widgets/ui.dart';

class InsightsScreen extends ConsumerWidget {
  const InsightsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final i = ref.watch(insightsProvider);
    final hasFinancialData = ref.watch(
      appControllerProvider.select((state) => state.hasFinancialData),
    );

    if (!hasFinancialData && i.forecastHeadline.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
        children: [
          Text(
            'Forecast & insights',
            style: jakarta(
              size: 21,
              weight: FontWeight.w800,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 20),
          Surface(
            radius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.bar_chart_rounded, size: 34, color: p.textSecondary),
                const SizedBox(height: 12),
                Text(
                  'No insights yet',
                  style: jakarta(
                    size: 16,
                    weight: FontWeight.w800,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Insights will use your income, bills, investments, and transaction history.',
                  textAlign: TextAlign.center,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w500,
                    height: 1.5,
                    color: p.textSecondary,
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
          'Forecast & insights',
          style: jakarta(
            size: 21,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 20),
        if (i.needPlan != null) ...[
          _needPlanCard(context, i.needPlan!),
          const SizedBox(height: 20),
        ],
        // 6-month trend + forecast
        Surface(
          radius: 20,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Monthly total, last 6 months + forecast',
                style: jakarta(
                  size: 13,
                  weight: FontWeight.w700,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 188,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 8,
                  children: [
                    for (final bar in i.chartBars)
                      ChartBar(
                        height: bar.height,
                        color: bar.color,
                        label: bar.label,
                        tag: bar.tag,
                        radius: 4,
                      ),
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
                  Text(
                    '12-month outlook',
                    style: jakarta(
                      size: 13,
                      weight: FontWeight.w700,
                      color: p.textPrimary,
                    ),
                  ),
                  Flexible(
                    child: Text(
                      'Peak: ${i.peakMonthLabel}',
                      textAlign: TextAlign.right,
                      style: jakarta(
                        size: 11,
                        weight: FontWeight.w600,
                        color: p.textTertiary,
                      ),
                    ),
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
                      ChartBar(
                        height: bar.height,
                        color: bar.color,
                        label: bar.label,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(height: 1, color: p.border),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Projected total this year',
                    style: jakarta(
                      size: 12,
                      weight: FontWeight.w600,
                      color: p.textSecondary,
                    ),
                  ),
                  Text(
                    i.yearTotalLabel,
                    style: mono(
                      size: 15,
                      weight: FontWeight.w700,
                      color: p.textPrimary,
                    ),
                  ),
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
              Text(
                i.driverTitle,
                style: jakarta(
                  size: 13,
                  weight: FontWeight.w700,
                  color: AppColors.amber,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                i.driverAmount,
                style: mono(
                  size: 26,
                  weight: FontWeight.w800,
                  color: p.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                i.driverText,
                style: jakarta(
                  size: 13,
                  weight: FontWeight.w500,
                  height: 1.6,
                  color: p.textPrimary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Full breakdown
        Text(
          '${i.breakdownMonthLabel} breakdown — full',
          style: jakarta(
            size: 15,
            weight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        for (final c in i.categoriesFull) ...[
          CategoryProgress(
            name: c.name,
            color: c.color,
            amount: '${c.amount} · ${c.pct.round()}%',
            pct: c.pct,
          ),
          const SizedBox(height: 14),
        ],
        const SizedBox(height: 6),
        // Expected-vs-actual for the current month (live SMS forecast only).
        if (i.expectedVsActual.isNotEmpty) ...[
          Text(
            'Expected vs actual · this month',
            style: jakarta(
              size: 15,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'What we projected against what has posted so far',
            style: jakarta(
              size: 12,
              weight: FontWeight.w500,
              color: p.textTertiary,
            ),
          ),
          const SizedBox(height: 14),
          for (final r in i.expectedVsActual) ...[
            _compareRow(
              context,
              r,
              leftLabel: 'Expected',
              rightLabel: 'Actual',
            ),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 6),
        ],
        // Same-month-last-year-vs-now (live SMS forecast only).
        if (i.yearOverYear.isNotEmpty) ...[
          Text(
            'vs last year · same month',
            style: jakarta(
              size: 15,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          for (final r in i.yearOverYear) ...[
            _compareRow(
              context,
              r,
              leftLabel: 'Last year',
              rightLabel: 'Now',
              showDelta: true,
            ),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 6),
        ],
        // Alerts
        Text(
          'Alerts',
          style: jakarta(
            size: 15,
            weight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        for (final al in i.alerts) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: al.bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: al.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    al.isPositive
                        ? Icons.check_rounded
                        : Icons.warning_amber_rounded,
                    size: 20,
                    color: al.isPositive ? AppColors.green : al.iconColor,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    al.text,
                    style: jakarta(
                      size: 13,
                      weight: FontWeight.w500,
                      height: 1.5,
                      color: p.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
      ],
    );
  }

  Widget _needPlanCard(BuildContext context, NeedPlan plan) {
    final p = context.palette;
    final resultColor = plan.isShort ? AppColors.pink : AppColors.green;

    Widget planRow(NeedPlanRow row) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(color: row.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.label,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
                if (row.note.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    row.note,
                    style: jakarta(
                      size: 11,
                      weight: FontWeight.w500,
                      color: p.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          Text(
            row.amount,
            style: mono(
              size: 13,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
        ],
      ),
    );

    Widget totalRow(String label, String amount, Color color) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: jakarta(
            size: 13,
            weight: FontWeight.w700,
            color: p.textPrimary,
          ),
        ),
        Text(
          amount,
          style: mono(size: 15, weight: FontWeight.w800, color: color),
        ),
      ],
    );

    return Surface(
      radius: 22,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.savings_outlined, size: 16, color: AppColors.teal),
              const SizedBox(width: 8),
              Text(
                'Need for ${plan.monthLabel}',
                style: jakarta(
                  size: 12,
                  weight: FontWeight.w600,
                  color: p.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            "What you'll need",
            style: jakarta(
              size: 13,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          for (final row in plan.requiredRows) planRow(row),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          totalRow('Total needed', plan.requiredTotalLabel, p.textPrimary),
          const SizedBox(height: 20),
          Text(
            "What you'll receive",
            style: jakarta(
              size: 13,
              weight: FontWeight.w700,
              color: p.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          for (final row in plan.receiveRows) planRow(row),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          totalRow(
            'Total incoming',
            plan.receiveTotalLabel,
            AppColors.green,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: resultColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: resultColor.withValues(alpha: 0.28)),
            ),
            child: Row(
              children: [
                Icon(
                  plan.isShort
                      ? Icons.trending_down_rounded
                      : Icons.check_circle_outline_rounded,
                  size: 20,
                  color: resultColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        plan.isShort
                            ? 'Gather more before ${plan.monthLabel}'
                            : "You're ahead for ${plan.monthLabel}",
                        style: jakarta(
                          size: 13,
                          weight: FontWeight.w700,
                          color: resultColor,
                        ),
                      ),
                      if (plan.salaryMissing) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Add your income for a complete picture',
                          style: jakarta(
                            size: 11,
                            weight: FontWeight.w500,
                            color: p.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Text(
                  '${plan.isShort ? '' : '+'}${plan.gapAmountLabel}',
                  style: mono(
                    size: 20,
                    weight: FontWeight.w800,
                    color: resultColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _compareRow(
    BuildContext context,
    CompareRow r, {
    required String leftLabel,
    required String rightLabel,
    bool showDelta = false,
  }) {
    final p = context.palette;
    Widget bar(double pct, Color color) => ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        value: (pct / 100).clamp(0, 1),
        minHeight: 6,
        backgroundColor: p.surfaceAlt,
        valueColor: AlwaysStoppedAnimation(color),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: r.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  r.name,
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w600,
                    color: p.textPrimary,
                  ),
                ),
              ],
            ),
            if (showDelta && r.deltaLabel.isNotEmpty)
              Text(
                r.deltaLabel,
                style: mono(
                  size: 12,
                  weight: FontWeight.w700,
                  color: r.deltaUp ? AppColors.pink : AppColors.green,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 62,
              child: Text(
                leftLabel,
                style: jakarta(
                  size: 11,
                  weight: FontWeight.w500,
                  color: p.textTertiary,
                ),
              ),
            ),
            Expanded(child: bar(r.leftPct, r.color.withValues(alpha: 0.45))),
            const SizedBox(width: 10),
            Text(
              r.leftAmount,
              style: mono(
                size: 12,
                weight: FontWeight.w600,
                color: p.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            SizedBox(
              width: 62,
              child: Text(
                rightLabel,
                style: jakarta(
                  size: 11,
                  weight: FontWeight.w500,
                  color: p.textTertiary,
                ),
              ),
            ),
            Expanded(child: bar(r.rightPct, r.color)),
            const SizedBox(width: 10),
            Text(
              r.rightAmount,
              style: mono(
                size: 12,
                weight: FontWeight.w700,
                color: p.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
