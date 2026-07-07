import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'sheet_scaffold.dart';

Future<void> showAboutSheet(BuildContext context) {
  return showAppSheet(context, (context) => const _AboutSheet());
}

class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  static const _features = [
    (Icons.mark_email_read_outlined, AppColors.teal, 'Automatic detection',
        'Scans Gmail for receipts & bills — no manual entry needed, though you can always add what it misses.'),
    (Icons.currency_rupee_rounded, AppColors.amber, '12-month forecast',
        'Projects every month ahead, not just the next one, so lumpy costs like premiums or lump-sum investments show up early.'),
    (Icons.trending_up_rounded, AppColors.violet, 'Investment planning',
        'Tracks NPS, PPF, Mutual Funds, FDs & anything else you add, and folds contributions into the forecast.'),
    (Icons.check_rounded, AppColors.green, 'Balance check',
        "Compares your salary & balance against what's due, so you always know if you'll be short."),
  ];

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SheetScaffold(
      title: 'About this app',
      children: [
        Text(
          'This app reads the transaction emails already in your Gmail, then uses that history to tell you what\'s coming — so a bill like an annual insurance premium never catches your bank balance off guard.',
          style: jakarta(size: 14, weight: FontWeight.w500, height: 1.6, color: p.textSecondary),
        ),
        const SizedBox(height: 18),
        for (final (icon, color, title, body) in _features) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(14)),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 20, color: color)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
                      const SizedBox(height: 2),
                      Text(body, style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textSecondary)),
                    ],
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
}
