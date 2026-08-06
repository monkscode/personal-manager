import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/insights.dart';
import '../../data/seed_data.dart';
import '../../widgets/ui.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Applies the active category filter and free-text search to the computed
  /// day groups, dropping any group left empty.
  List<TxGroupView> _filtered(List<TxGroupView> groups, String filter) {
    final q = _query.trim().toLowerCase();
    final result = <TxGroupView>[];
    for (final grp in groups) {
      final items = [
        for (final tx in grp.items)
          if ((filter == 'all' || tx.categoryKey == filter) &&
              (q.isEmpty ||
                  tx.name.toLowerCase().contains(q) ||
                  tx.category.toLowerCase().contains(q)))
            tx,
      ];
      if (items.isNotEmpty) {
        result.add(TxGroupView(date: grp.date, items: items));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final filter = ref.watch(appControllerProvider.select((s) => s.txFilter));
    final i = ref.watch(insightsProvider);
    final ctrl = ref.read(appControllerProvider.notifier);
    final groups = _filtered(i.dateGroups, filter);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
      children: [
        Text(
          'Transactions',
          style: jakarta(
            size: 21,
            weight: FontWeight.w800,
            color: p.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          i.txCountLabel,
          style: jakarta(
            size: 13,
            weight: FontWeight.w500,
            color: p.textTertiary,
          ),
        ),
        const SizedBox(height: 18),
        // Search
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.border),
          ),
          child: Row(
            children: [
              Icon(Icons.search_rounded, size: 18, color: p.textTertiary),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v),
                  style: jakarta(
                    size: 13,
                    weight: FontWeight.w500,
                    color: p.textPrimary,
                  ),
                  cursorColor: AppColors.teal,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: 'Search transactions',
                    hintStyle: jakarta(
                      size: 13,
                      weight: FontWeight.w500,
                      color: p.textTertiary,
                    ),
                  ),
                ),
              ),
              if (_query.isNotEmpty)
                GestureDetector(
                  onTap: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                  child: Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: p.textTertiary,
                  ),
                ),
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
                SelectableChip(
                  label: f.label,
                  selected: filter == f.key,
                  onTap: () => ctrl.setTxFilter(f.key),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        if (groups.isEmpty)
          Surface(
            radius: 18,
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  size: 32,
                  color: p.textSecondary,
                ),
                const SizedBox(height: 12),
                Text(
                  (_query.isNotEmpty || filter != 'all')
                      ? 'No matching transactions'
                      : 'No transactions yet',
                  style: jakarta(
                    size: 16,
                    weight: FontWeight.w800,
                    color: p.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  (_query.isNotEmpty || filter != 'all')
                      ? 'Try a different search or filter.'
                      : 'Add an expense or scan messages to see activity here.',
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
        for (final grp in groups) ...[
          Text(
            grp.date.toUpperCase(),
            style: jakarta(
              size: 12,
              weight: FontWeight.w700,
              letterSpacing: 0.6,
              color: p.textTertiary,
            ),
          ),
          const SizedBox(height: 10),
          for (final tx in grp.items)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: tx.bgColor,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      tx.initial,
                      style: jakarta(
                        size: 13,
                        weight: FontWeight.w700,
                        color: tx.color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tx.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: jakarta(
                            size: 13,
                            weight: FontWeight.w600,
                            color: p.textPrimary,
                          ),
                        ),
                        Text(
                          tx.category,
                          style: jakarta(
                            size: 12,
                            weight: FontWeight.w500,
                            color: p.textTertiary,
                          ),
                        ),
                        if (tx.subtitle.isNotEmpty)
                          Text(
                            tx.subtitle,
                            maxLines: 2,
                            style: jakarta(
                              size: 11,
                              weight: FontWeight.w500,
                              color: p.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    tx.amount,
                    style: mono(
                      size: 13,
                      weight: FontWeight.w600,
                      color: tx.amountColor ?? p.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}
