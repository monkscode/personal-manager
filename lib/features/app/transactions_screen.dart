import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/seed_data.dart';
import '../../widgets/ui.dart';

class TransactionsScreen extends ConsumerWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = context.palette;
    final filter = ref.watch(appControllerProvider.select((s) => s.txFilter));
    final i = ref.watch(insightsProvider);
    final ctrl = ref.read(appControllerProvider.notifier);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text('Transactions', style: jakarta(size: 21, weight: FontWeight.w800, color: p.textPrimary)),
        const SizedBox(height: 4),
        Text(i.txCountLabel, style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary)),
        const SizedBox(height: 18),
        // Search (visual only)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.border)),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 18, color: p.textTertiary),
              const SizedBox(width: 10),
              Text('Search transactions', style: jakarta(size: 13, weight: FontWeight.w500, color: p.textTertiary)),
            ],
          ),
        ),
        const SizedBox(height: 18),
        // Filters
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in kFilterDefs) ...[
                SelectableChip(label: f.label, selected: filter == f.key, onTap: () => ctrl.setTxFilter(f.key)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        for (final grp in i.dateGroups) ...[
          Text(grp.date.toUpperCase(),
              style: jakarta(size: 12, weight: FontWeight.w700, letterSpacing: 0.6, color: p.textTertiary)),
          const SizedBox(height: 10),
          for (final tx in grp.items)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.border))),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: tx.bgColor, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: Text(tx.initial, style: jakarta(size: 13, weight: FontWeight.w700, color: tx.color)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tx.name, style: jakarta(size: 13, weight: FontWeight.w600, color: p.textPrimary)),
                        Text(tx.category, style: jakarta(size: 12, weight: FontWeight.w500, color: p.textTertiary)),
                      ],
                    ),
                  ),
                  Text(tx.amount, style: mono(size: 13, weight: FontWeight.w600, color: p.textPrimary)),
                ],
              ),
            ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}
