import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../data/app_controller.dart';
import '../../data/models.dart';
import '../../data/seed_data.dart';
import '../../widgets/ui.dart';
import 'sheet_scaffold.dart';

Future<void> showAddSheet(BuildContext context, WidgetRef ref, {required String type}) {
  return showAppSheet(context, (_) => _AddSheet(initialType: type));
}

class _AddSheet extends ConsumerStatefulWidget {
  const _AddSheet({required this.initialType});
  final String initialType;

  @override
  ConsumerState<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends ConsumerState<_AddSheet> {
  late String _type; // 'expense' | 'investment'
  // Expense form
  final _name = TextEditingController();
  final _amount = TextEditingController();
  final _date = TextEditingController();
  String _category = 'groceries';
  String _recurrence = 'onetime';
  // Investment form
  final _institution = TextEditingController();
  final _principal = TextEditingController();
  final _rate = TextEditingController();
  final _maturity = TextEditingController();
  String _invType = 'FD';

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
  }

  @override
  void dispose() {
    for (final c in [_name, _amount, _date, _institution, _principal, _rate, _maturity]) {
      c.dispose();
    }
    super.dispose();
  }

  void _saveExpense() {
    final cat = kCatsNext.firstWhere((c) => c.key == _category, orElse: () => kCatsNext.first);
    final name = _name.text.trim();
    ref.read(appControllerProvider.notifier).addExpense(ExpenseEntry(
          name: name.isEmpty ? 'New expense' : name,
          category: cat.name,
          categoryKey: cat.key,
          amount: double.tryParse(_amount.text.trim()) ?? 0,
          initial: (name.isEmpty ? 'NE' : name).substring(0, name.length >= 2 ? 2 : name.length).toUpperCase(),
          color: cat.color,
          recurring: _recurrence == 'monthly',
        ));
    Navigator.of(context).pop();
  }

  void _saveInvestment() {
    ref.read(appControllerProvider.notifier).addInvestment(Investment(
          type: _invType,
          institution: _institution.text.trim().isEmpty ? 'New institution' : _institution.text.trim(),
          principal: double.tryParse(_principal.text.trim()) ?? 0,
          maturityValue: 0,
          rate: _rate.text.trim().isEmpty ? '—' : _rate.text.trim(),
          maturity: _maturity.text.trim().isEmpty ? 'TBD' : _maturity.text.trim(),
          status: 'Active',
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Add manually', style: jakarta(size: 17, weight: FontWeight.w800, color: p.textPrimary)),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: p.surfaceAlt, shape: BoxShape.circle),
                  child: Icon(Icons.close_rounded, size: 14, color: p.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text("Didn't catch something in your inbox? Add it here so your forecast stays accurate.",
              style: jakarta(size: 12, weight: FontWeight.w500, height: 1.5, color: p.textTertiary)),
          const SizedBox(height: 18),
          SegmentedToggle(
            labels: const ['Expense / Bill', 'Investment'],
            selectedIndex: _type == 'expense' ? 0 : 1,
            onChanged: (i) => setState(() => _type = i == 0 ? 'expense' : 'investment'),
          ),
          const SizedBox(height: 18),
          if (_type == 'expense') ..._expenseForm(context) else ..._investmentForm(context),
        ],
      ),
    );
  }

  List<Widget> _expenseForm(BuildContext context) {
    return [
      const FieldLabel('Name'),
      AppTextField(controller: _name, hint: 'e.g. Car insurance', height: 46, fillAlt: true),
      const SizedBox(height: 14),
      const FieldLabel('Amount (₹)'),
      AppTextField(controller: _amount, hint: '0', mono: true, number: true, height: 46, fillAlt: true),
      const SizedBox(height: 14),
      const FieldLabel('Category'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final c in kCatsNext)
            SelectableChip(label: c.name, selected: _category == c.key, selectedColor: c.color, onTap: () => setState(() => _category = c.key)),
        ],
      ),
      const SizedBox(height: 14),
      const FieldLabel('Recurrence'),
      SegmentedToggle(
        labels: const ['One-time', 'Monthly recurring'],
        selectedIndex: _recurrence == 'monthly' ? 1 : 0,
        fontSize: 12,
        onChanged: (i) => setState(() => _recurrence = i == 0 ? 'onetime' : 'monthly'),
      ),
      const SizedBox(height: 14),
      FieldLabel(_recurrence == 'monthly' ? 'Day of month' : 'Date'),
      AppTextField(controller: _date, hint: _recurrence == 'monthly' ? 'e.g. 5th' : 'e.g. Aug 5', height: 46, fillAlt: true),
      const SizedBox(height: 18),
      PrimaryButton(label: 'Save', onTap: _saveExpense, height: 52, radius: 16),
    ];
  }

  List<Widget> _investmentForm(BuildContext context) {
    return [
      const FieldLabel('Type'),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in const ['FD', 'PPF', 'RD', 'Other'])
            SelectableChip(
              label: t,
              selected: _invType == t,
              selectedColor: kTypeColors[t] ?? AppColors.slate,
              onTap: () => setState(() => _invType = t),
            ),
        ],
      ),
      const SizedBox(height: 14),
      const FieldLabel('Institution'),
      AppTextField(controller: _institution, hint: 'e.g. HDFC Bank', height: 46, fillAlt: true),
      const SizedBox(height: 14),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FieldLabel('Principal (₹)'),
                AppTextField(controller: _principal, hint: '0', mono: true, number: true, height: 46, fillAlt: true),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FieldLabel('Rate'),
                AppTextField(controller: _rate, hint: 'e.g. 7.1%', mono: true, height: 46, fillAlt: true),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      const FieldLabel('Maturity date'),
      AppTextField(controller: _maturity, hint: 'e.g. Mar 2027', height: 46, fillAlt: true),
      const SizedBox(height: 18),
      PrimaryButton(label: 'Save', onTap: _saveInvestment, height: 52, radius: 16),
    ];
  }
}
