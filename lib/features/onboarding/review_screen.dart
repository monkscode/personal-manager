import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/parsed_bill.dart';
import '../../data/seed_data.dart';
import '../../widgets/ui.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final _selected = <String>{};
  final _amounts = <String, double>{}; // user-entered amounts for bills detected without one
  bool _seeded = false;

  Color _categoryColor(String key) =>
      kCatsNext.firstWhere((c) => c.key == key, orElse: () => kCatsNext.last).color;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final candidates = ref.watch(appControllerProvider.select((s) => s.candidates));
    final aiFallbackNote = ref.watch(appControllerProvider.select((s) => s.aiFallbackNote));
    final ctrl = ref.read(appControllerProvider.notifier);

    // Pre-select only the confident detections the first time we see them;
    // weaker guesses stay visible but unchecked, so only solid data flows in.
    if (!_seeded) {
      _seeded = true;
      _selected.addAll(candidates.where((c) => c.confidence >= 0.6).map((c) => c.sourceId));
    }

    if (candidates.isEmpty) {
      return Column(
        children: [
          if (aiFallbackNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: _aiFallbackBanner(context, aiFallbackNote),
            ),
          Expanded(child: _empty(context, ctrl)),
        ],
      );
    }

    final chosen = candidates
        .where((c) => _selected.contains(c.sourceId))
        .map((c) => _amounts.containsKey(c.sourceId) ? c.copyWith(amount: _amounts[c.sourceId]) : c)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (aiFallbackNote.isNotEmpty) ...[
            _aiFallbackBanner(context, aiFallbackNote),
            const SizedBox(height: 14),
          ],
          Text('Found ${candidates.length} in your inbox',
              style: jakarta(size: 22, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
          const SizedBox(height: 8),
          Text('Tap to include or exclude each one. Nothing is added until you confirm.',
              style: jakarta(size: 13, weight: FontWeight.w500, height: 1.5, color: p.textSecondary)),
          const SizedBox(height: 18),
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: candidates.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _card(context, candidates[i]),
            ),
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: chosen.isEmpty ? 'Select at least one' : 'Add ${chosen.length} to my plan',
            onTap: chosen.isEmpty ? () {} : () => ctrl.confirmCandidates(chosen),
          ),
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: ctrl.skipReview,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Not now', style: jakarta(size: 13, weight: FontWeight.w600, color: p.textTertiary)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The amount cell on a review card. When the detectors couldn't find an
  /// amount (common for bill *reminder* emails that omit the figure), show a
  /// tappable "Set amount" chip instead of a misleading ₹0.
  Widget _amountWidget(BuildContext context, ParsedBill bill) {
    final p = context.palette;
    final amount = _amounts[bill.sourceId] ?? bill.amount;
    if (amount >= 1) {
      return GestureDetector(
        onTap: () => _promptAmount(bill),
        child: Text(inr(amount), style: mono(size: 14, weight: FontWeight.w700, color: p.textPrimary)),
      );
    }
    return GestureDetector(
      onTap: () => _promptAmount(bill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.amber.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.add_rounded, size: 13, color: AppColors.amber),
            const SizedBox(width: 4),
            Text('Set amount', style: jakarta(size: 11, weight: FontWeight.w700, color: AppColors.amber)),
          ],
        ),
      ),
    );
  }

  Future<void> _promptAmount(ParsedBill bill) async {
    final p = context.palette;
    final controller = TextEditingController(
      text: (_amounts[bill.sourceId] ?? (bill.amount >= 1 ? bill.amount : 0)) >= 1
          ? (_amounts[bill.sourceId] ?? bill.amount).round().toString()
          : '',
    );
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.surface,
        title: Text(bill.merchant, style: jakarta(size: 15, weight: FontWeight.w800, color: p.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: jakarta(size: 15, weight: FontWeight.w600, color: p.textPrimary),
          decoration: InputDecoration(
            prefixText: '₹ ',
            hintText: 'Enter amount',
            hintStyle: jakarta(size: 15, weight: FontWeight.w500, color: p.textTertiary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: jakarta(size: 13, weight: FontWeight.w600, color: p.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(controller.text.replaceAll(',', '').trim())),
            child: Text('Save', style: jakarta(size: 13, weight: FontWeight.w700, color: AppColors.teal)),
          ),
        ],
      ),
    );
    if (value != null && value >= 1) {
      setState(() {
        _amounts[bill.sourceId] = value;
        _selected.add(bill.sourceId); // setting an amount implies you want it in
      });
    }
  }

  Widget _aiFallbackBanner(BuildContext context, String message) {
    final p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.amber.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded, size: 16, color: AppColors.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: jakarta(size: 12, weight: FontWeight.w500, height: 1.4, color: p.textSecondary)),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, ParsedBill bill) {
    final p = context.palette;
    final selected = _selected.contains(bill.sourceId);
    final color = _categoryColor(bill.categoryKey);
    final due = bill.dueDate == null ? null : DateFormat('d MMM yyyy').format(bill.dueDate!);
    final recur = switch (bill.recurrence) {
      'monthly' => 'Monthly',
      'quarterly' => 'Quarterly',
      'annual' => 'Annual',
      _ => 'One-time',
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() {
        selected ? _selected.remove(bill.sourceId) : _selected.add(bill.sourceId);
      }),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? AppColors.teal.withValues(alpha: 0.6) : p.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                color: selected ? AppColors.teal : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: selected ? AppColors.teal : p.borderStrong, width: 1.5),
              ),
              child: selected ? const Icon(Icons.check_rounded, size: 14, color: AppColors.ink) : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(bill.merchant,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: jakarta(size: 14, weight: FontWeight.w700, color: p.textPrimary)),
                      ),
                      _amountWidget(context, bill),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _tag(bill.categoryKey.isEmpty ? 'other' : bill.categoryKey, color),
                      _plainTag(recur, p),
                      if (due != null) _plainTag('Due $due', p),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(bill.sourceSubject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: jakarta(size: 11, weight: FontWeight.w500, color: p.textTertiary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label[0].toUpperCase() + label.substring(1),
                style: jakarta(size: 11, weight: FontWeight.w600, color: color)),
          ],
        ),
      );

  Widget _plainTag(String label, AppPalette p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: jakarta(size: 11, weight: FontWeight.w600, color: p.textSecondary)),
      );

  Widget _empty(BuildContext context, AppController ctrl) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(color: AppColors.teal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(26)),
            child: const Icon(Icons.inbox_outlined, size: 40, color: AppColors.teal),
          ),
          const SizedBox(height: 24),
          Text('No bills detected yet',
              textAlign: TextAlign.center,
              style: jakarta(size: 20, weight: FontWeight.w800, color: p.textPrimary)),
          const SizedBox(height: 10),
          Text("We couldn't confidently spot upcoming bills in your recent mail. You can always add them manually with the + button.",
              textAlign: TextAlign.center,
              style: jakarta(size: 14, weight: FontWeight.w500, height: 1.6, color: p.textSecondary)),
          const SizedBox(height: 24),
          PrimaryButton(label: 'Continue', onTap: ctrl.skipReview),
        ],
      ),
    );
  }
}
