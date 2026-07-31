import 'package:flutter/material.dart';

import '../core/theme.dart';

class ExpenseCategory {
  const ExpenseCategory(this.key, this.name, this.color);

  final String key;
  final String name;
  final Color color;
}

const List<String> kMonths = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

const List<ExpenseCategory> kExpenseCategories = [
  ExpenseCategory('insurance', 'Insurance', AppColors.amber),
  ExpenseCategory('housing', 'Housing', AppColors.blue),
  ExpenseCategory('other', 'Other', AppColors.slate),
  ExpenseCategory('groceries', 'Groceries', AppColors.green),
  ExpenseCategory('transport', 'Transport', AppColors.cyan),
  ExpenseCategory('subscriptions', 'Subscriptions', AppColors.purple),
  ExpenseCategory('utilities', 'Utilities', AppColors.pink),
];

const Map<String, Color> kTypeColors = {
  'FD': AppColors.blue,
  'PPF': AppColors.violet,
  'RD': AppColors.cyan,
  'MF': AppColors.orange,
  'Other': AppColors.slate,
};

const List<({String key, String label})> kFilterDefs = [
  (key: 'all', label: 'All'),
  (key: 'food', label: 'Food'),
  (key: 'groceries', label: 'Groceries'),
  (key: 'shopping', label: 'Shopping'),
  (key: 'transport', label: 'Transport'),
  (key: 'utilities', label: 'Utilities'),
  (key: 'cash', label: 'Cash'),
  (key: 'transfers', label: 'Transfers'),
  (key: 'income', label: 'Income'),
  (key: 'subscriptions', label: 'Subscriptions'),
  (key: 'insurance', label: 'Insurance'),
  (key: 'housing', label: 'Housing'),
];

const List<Color> kCustomColors = [
  Color(0xFFF472B6),
  Color(0xFFFDE047),
  Color(0xFF67E8F9),
  Color(0xFFFCA5A5),
  Color(0xFFA78BFA),
  Color(0xFFFDBA74),
];
