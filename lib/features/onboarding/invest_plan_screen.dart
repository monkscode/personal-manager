import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/models.dart';
import '../../data/seed_data.dart';
import '../../widgets/ui.dart';

class InvestPlanScreen extends ConsumerStatefulWidget {
  const InvestPlanScreen({super.key});

  @override
  ConsumerState<InvestPlanScreen> createState() => _InvestPlanScreenState();
}

class _InvestPlanScreenState extends ConsumerState<InvestPlanScreen> {
  late final TextEditingController _nps;
  late final TextEditingController _ppf;
  late final TextEditingController _mf;
  final _customName = TextEditingController();
  final _customAmount = TextEditingController();

  bool _draftOpen = false;
  String _draftFreq = 'monthly';
  String _draftMonth = 'Feb';

  @override
  void initState() {
    super.initState();
    final s = ref.read(appControllerProvider);
    _nps = TextEditingController(text: s.nps.amount);
    _ppf = TextEditingController(text: s.ppf.amount);
    _mf = TextEditingController(text: s.mf.amount);
  }

  @override
  void dispose() {
    for (final c in [_nps, _ppf, _mf, _customName, _customAmount]) {
      c.dispose();
    }
    super.dispose();
  }

  void _addCustom() {
    final name = _customName.text.trim();
    final amount = double.tryParse(_customAmount.text.trim()) ?? 0;
    if (name.isEmpty || amount == 0) return;
    ref.read(appControllerProvider.notifier).addCustomPlan(CustomPlan(
          id: 'cp-${DateTime.now().millisecondsSinceEpoch}',
          name: name,
          amount: amount,
          frequency: _draftFreq,
          month: _draftMonth,
        ));
    _customName.clear();
    _customAmount.clear();
    setState(() {
      _draftOpen = false;
      _draftFreq = 'monthly';
      _draftMonth = 'Feb';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = ref.watch(appControllerProvider);
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
                child: Text('Skip', style: jakarta(size: 13, weight: FontWeight.w600, color: p.textTertiary)),
              ),
            ),
          ),
          Text('Plan your investments', style: jakarta(size: 24, weight: FontWeight.w800, height: 1.3, color: p.textPrimary)),
          const SizedBox(height: 8),
          Text("Tell us how you contribute to NPS & PPF, so we can flag the exact month you'll need extra cash.",
              style: jakarta(size: 14, weight: FontWeight.w500, height: 1.6, color: p.textSecondary)),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _contribCard('NPS', s.nps, _nps, 'Monthly', 'All in one month', ctrl.setNps),
                const SizedBox(height: 16),
                _contribCard('PPF', s.ppf, _ppf, 'Monthly', 'All in one month', ctrl.setPpf),
                const SizedBox(height: 16),
                _contribCard('Mutual Fund', s.mf, _mf, 'Monthly SIP', 'All in one month', ctrl.setMf),
                const SizedBox(height: 16),
                _anythingElse(s.customPlans),
              ],
            ),
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Continue', onTap: ctrl.goConnect),
        ],
      ),
    );
  }

  Widget _contribCard(
    String title,
    ContribPlan plan,
    TextEditingController amountCtrl,
    String monthlyLabel,
    String lumpsumLabel,
    void Function(ContribPlan) onChanged,
  ) {
    final p = context.palette;
    return Surface(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: jakarta(size: 14, weight: FontWeight.w700, color: p.textPrimary)),
              SwitchToggle(value: plan.enabled, onTap: () => onChanged(plan.copyWith(enabled: !plan.enabled))),
            ],
          ),
          if (plan.enabled) ...[
            const SizedBox(height: 14),
            const FieldLabel('Contribution amount (₹)'),
            AppTextField(
              controller: amountCtrl,
              hint: '5000',
              mono: true,
              number: true,
              height: 44,
              fillAlt: true,
              onChanged: (v) => onChanged(plan.copyWith(amount: v)),
            ),
            const SizedBox(height: 12),
            SegmentedToggle(
              labels: [monthlyLabel, lumpsumLabel],
              selectedIndex: plan.isLumpsum ? 1 : 0,
              fontSize: 12,
              radius: 12,
              onChanged: (i) => onChanged(plan.copyWith(frequency: i == 0 ? 'monthly' : 'lumpsum')),
            ),
            if (plan.isLumpsum) ...[
              const SizedBox(height: 12),
              _monthChips(plan.month, (m) => onChanged(plan.copyWith(month: m))),
            ],
          ],
        ],
      ),
    );
  }

  Widget _monthChips(String selected, ValueChanged<String> onSelect) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final m in kMonths)
          SelectableChip(label: m, selected: selected == m, fontSize: 11, onTap: () => onSelect(m)),
      ],
    );
  }

  Widget _anythingElse(List<CustomPlan> plans) {
    final p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Anything else?', style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
        const SizedBox(height: 10),
        Text('Add any other recurring investment or contribution — Sukanya Samriddhi, ELSS, crypto SIP, anything — and we\'ll plan around it too.',
            style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textTertiary)),
        const SizedBox(height: 12),
        for (var i = 0; i < plans.length; i++) ...[
          _customRow(plans[i], kCustomColors[i % kCustomColors.length]),
          const SizedBox(height: 10),
        ],
        if (!_draftOpen)
          GestureDetector(
            onTap: () => setState(() => _draftOpen = true),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.borderStrong, style: BorderStyle.solid),
              ),
              child: Center(
                child: Text('+ Add another', style: jakarta(size: 13, weight: FontWeight.w700, color: AppColors.teal)),
              ),
            ),
          )
        else
          _draftForm(),
      ],
    );
  }

  Widget _customRow(CustomPlan plan, Color color) {
    final p = context.palette;
    final freqLabel = plan.frequency == 'monthly' ? 'Monthly' : 'Lump sum · ${plan.month}';
    final amountLabel = inr(plan.amount) + (plan.frequency == 'monthly' ? '/mo' : '');
    return Surface(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(plan.name, style: jakarta(size: 13, weight: FontWeight.w700, color: p.textPrimary)),
                Text(freqLabel, style: jakarta(size: 11, weight: FontWeight.w500, color: p.textTertiary)),
              ],
            ),
          ),
          Text(amountLabel, style: mono(size: 13, weight: FontWeight.w600, color: p.textSecondary)),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () => ref.read(appControllerProvider.notifier).removeCustomPlan(plan.id),
            child: Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(color: p.surfaceAlt, shape: BoxShape.circle),
              child: Icon(Icons.close_rounded, size: 12, color: p.textTertiary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _draftForm() {
    final p = context.palette;
    return Surface(
      radius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const FieldLabel('Name'),
          AppTextField(controller: _customName, hint: 'e.g. Sukanya Samriddhi', height: 44, fillAlt: true),
          const SizedBox(height: 12),
          const FieldLabel('Amount (₹)'),
          AppTextField(controller: _customAmount, hint: '2000', mono: true, number: true, height: 44, fillAlt: true),
          const SizedBox(height: 12),
          SegmentedToggle(
            labels: const ['Monthly', 'All in one month'],
            selectedIndex: _draftFreq == 'lumpsum' ? 1 : 0,
            fontSize: 12,
            radius: 12,
            onChanged: (i) => setState(() => _draftFreq = i == 0 ? 'monthly' : 'lumpsum'),
          ),
          if (_draftFreq == 'lumpsum') ...[
            const SizedBox(height: 12),
            _monthChips(_draftMonth, (m) => setState(() => _draftMonth = m)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() {
                    _draftOpen = false;
                    _customName.clear();
                    _customAmount.clear();
                  }),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(color: p.borderStrong),
                    ),
                    child: Center(
                      child: Text('Cancel', style: jakarta(size: 12, weight: FontWeight.w700, color: p.textSecondary)),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: _addCustom,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(color: AppColors.teal, borderRadius: BorderRadius.circular(11)),
                    child: Center(
                      child: Text('Add', style: jakarta(size: 12, weight: FontWeight.w700, color: AppColors.ink)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
