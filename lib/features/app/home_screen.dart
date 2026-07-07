import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/insights.dart';
import '../../widgets/ui.dart';
import 'about_sheet.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final monthView = ref.watch(appControllerProvider.select((s) => s.monthView));
    final i = ref.watch(insightsProvider);
    final ctrl = ref.read(appControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        // Header
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Welcome back', style: jakarta(size: 12, weight: FontWeight.w600, color: p.textTertiary)),
                  const SizedBox(height: 4),
                  Text('Aarav Mehta', style: jakarta(size: 21, weight: FontWeight.w800, color: p.textPrimary)),
                ],
              ),
            ),
            GestureDetector(
              onTap: () => showAboutSheet(context),
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: p.surface, shape: BoxShape.circle, border: Border.all(color: p.border)),
                child: Icon(Icons.info_outline_rounded, size: 16, color: p.textSecondary),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: 0.14), shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text('AM', style: jakarta(size: 14, weight: FontWeight.w700, color: AppColors.teal)),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Sync chip
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 7, height: 7, decoration: const BoxDecoration(color: AppColors.green, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Text('Synced 2 min ago · Gmail', style: jakarta(size: 12, weight: FontWeight.w600, color: p.textSecondary)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Hero card
        Surface(
          radius: 22,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedToggle(
                labels: const ['This month', 'Next month'],
                selectedIndex: monthView == 'current' ? 0 : 1,
                onChanged: (idx) => ctrl.setMonthView(idx == 0 ? 'current' : 'next'),
              ),
              const SizedBox(height: 18),
              Text(i.heroLabel, style: jakarta(size: 12, weight: FontWeight.w600, color: p.textTertiary)),
              const SizedBox(height: 6),
              Text(i.heroAmount, style: mono(size: 38, weight: FontWeight.w800, color: p.textPrimary, letterSpacing: -0.5)),
              const SizedBox(height: 10),
              Text(i.heroSubText, style: jakarta(size: 13, weight: FontWeight.w600, color: i.heroSubColor)),
              const SizedBox(height: 18),
              SizedBox(
                height: 82,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  spacing: 6,
                  children: [
                    for (final bar in i.heroTrendBars)
                      ChartBar(height: bar.height, color: bar.color, label: bar.label),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Balance check
        _balanceCheck(context, i),
        const SizedBox(height: 20),
        // Insight card: insurance
        _insightCard(
          context,
          bg: AppColors.amber.withValues(alpha: 0.08),
          border: AppColors.amber.withValues(alpha: 0.25),
          icon: Icons.notifications_active_outlined,
          iconColor: AppColors.amber,
          onTap: ctrl.goInsights,
          spans: [
            _t(context, 'Insurance premium '),
            _mono(context, '₹47,000', AppColors.amber),
            _t(context, ' due Feb 14 — set aside '),
            _mono(context, '₹11,750', p.textPrimary),
            _t(context, '/week'),
          ],
        ),
        const SizedBox(height: 12),
        // Insight card: FD
        _insightCard(
          context,
          bg: AppColors.teal.withValues(alpha: 0.08),
          border: AppColors.teal.withValues(alpha: 0.25),
          icon: Icons.trending_up_rounded,
          iconColor: AppColors.teal,
          onTap: ctrl.goInvestments,
          spans: [
            _t(context, 'HDFC FD matures ${i.fdMaturityDate} — '),
            _mono(context, i.fdMaturityValue, AppColors.teal),
            _t(context, ' incoming, incl. interest'),
          ],
        ),
        const SizedBox(height: 20),
        // February breakdown (top categories)
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('February breakdown', style: jakarta(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
            GestureDetector(
              onTap: ctrl.goInsights,
              child: Text('View all', style: jakarta(size: 12, weight: FontWeight.w600, color: AppColors.teal)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final c in i.categoriesTop) ...[
          CategoryProgress(name: c.name, color: c.color, amount: c.amount, pct: c.pct),
          const SizedBox(height: 14),
        ],
        const SizedBox(height: 6),
        // Upcoming bills
        Text('Upcoming bills', style: jakarta(size: 15, weight: FontWeight.w700, color: p.textPrimary)),
        const SizedBox(height: 4),
        for (final b in i.upcomingBills)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.border))),
            child: Row(
              children: [
                _initialBadge(b.initial, b.color, b.bgColor, radius: 11),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.name, style: jakarta(size: 13, weight: FontWeight.w600, color: p.textPrimary)),
                      Text(b.due, style: jakarta(size: 12, weight: FontWeight.w500, color: p.textTertiary)),
                    ],
                  ),
                ),
                Text(b.amount, style: mono(size: 13, weight: FontWeight.w600, color: p.textPrimary)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _balanceCheck(BuildContext context, Insights i) {
    final p = context.palette;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: jakarta(size: 12, weight: FontWeight.w500, color: p.textSecondary)),
              Text(value, style: mono(size: 12, weight: FontWeight.w600, color: p.textPrimary)),
            ],
          ),
        );
    return Surface(
      radius: 20,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Balance check · ${i.balanceCheckLabel}',
              style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
          const SizedBox(height: 12),
          row('Available by then', i.balanceAvailable),
          row('Required spend', i.balanceRequired),
          const SizedBox(height: 4),
          Container(height: 1, color: p.border),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(i.balanceResultLabel, style: jakarta(size: 13, weight: FontWeight.w700, color: i.balanceResultColor)),
              Text(i.balanceResultAmount, style: mono(size: 20, weight: FontWeight.w800, color: i.balanceResultColor)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _insightCard(
    BuildContext context, {
    required Color bg,
    required Color border,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
    required List<InlineSpan> spans,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18), border: Border.all(color: border)),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor),
            const SizedBox(width: 12),
            Expanded(child: Text.rich(TextSpan(children: spans))),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right_rounded, size: 18, color: iconColor),
          ],
        ),
      ),
    );
  }

  InlineSpan _t(BuildContext context, String text) => TextSpan(
      text: text,
      style: jakarta(size: 13, weight: FontWeight.w600, height: 1.5, color: context.palette.textPrimary));

  InlineSpan _mono(BuildContext context, String text, Color color) =>
      TextSpan(text: text, style: mono(size: 13, weight: FontWeight.w600, color: color));

  Widget _initialBadge(String initial, Color color, Color bg, {double radius = 11}) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(radius)),
      alignment: Alignment.center,
      child: Text(initial, style: jakarta(size: 12, weight: FontWeight.w700, color: color)),
    );
  }
}
