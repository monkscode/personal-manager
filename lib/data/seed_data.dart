import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'models.dart';

/// Static sample dataset ported from the design prototype. In the shipped app
/// this is what "Continue with Gmail" / "Use sample data" seeds; a later phase
/// replaces it with obligations parsed from the user's real inbox.

class CategorySeed {
  const CategorySeed(this.key, this.name, this.color, this.amount);
  final String key;
  final String name;
  final Color color;
  final double amount;
}

class BillSeed {
  const BillSeed({
    required this.name,
    required this.due,
    required this.amount,
    required this.initial,
    required this.color,
  });
  final String name;
  final String due;
  final double amount;
  final String initial;
  final Color color;
  Color get bgColor => color.withValues(alpha: 0.14);
}

class TxItem {
  const TxItem({
    required this.name,
    required this.category,
    required this.amount,
    required this.key,
    required this.initial,
    required this.color,
  });
  final String name;
  final String category;
  final double amount;
  final String key;
  final String initial;
  final Color color;
  Color get bgColor => color.withValues(alpha: 0.14);
}

class TxGroup {
  const TxGroup(this.date, this.items);
  final String date;
  final List<TxItem> items;
}

const List<String> kMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Trailing-7-month spend trend (the Feb value is recomputed dynamically).
const List<({String label, double v})> kTrend = [
  (label: 'Aug', v: 43200),
  (label: 'Sep', v: 47800),
  (label: 'Oct', v: 45100),
  (label: 'Nov', v: 48900),
  (label: 'Dec', v: 46200),
  (label: 'Jan', v: 46700),
  (label: 'Feb', v: 94800),
];

const List<CategorySeed> kCatsNext = [
  CategorySeed('insurance', 'Insurance', AppColors.amber, 47000),
  CategorySeed('housing', 'Housing', AppColors.blue, 18000),
  CategorySeed('other', 'Other', AppColors.slate, 9100),
  CategorySeed('groceries', 'Groceries', AppColors.green, 9500),
  CategorySeed('transport', 'Transport', AppColors.cyan, 3800),
  CategorySeed('subscriptions', 'Subscriptions', AppColors.purple, 3200),
  CategorySeed('utilities', 'Utilities', AppColors.pink, 4200),
];

const List<BillSeed> kBills = [
  BillSeed(name: 'Life Insurance Premium', due: 'Due Feb 14 · Annual', amount: 47000, initial: 'LI', color: AppColors.amber),
  BillSeed(name: 'House Rent', due: 'Due Feb 1 · Recurring', amount: 18000, initial: 'HR', color: AppColors.blue),
  BillSeed(name: 'Netflix + Spotify + iCloud', due: 'Due Feb 3–18 · Recurring', amount: 3200, initial: 'SU', color: AppColors.purple),
  BillSeed(name: 'Electricity Board', due: 'Due Feb 10 · Recurring', amount: 2100, initial: 'EB', color: AppColors.pink),
  BillSeed(name: 'Broadband', due: 'Due Feb 5 · Recurring', amount: 1100, initial: 'BB', color: AppColors.pink),
];

const List<TxGroup> kTransactions = [
  TxGroup('Today', [
    TxItem(name: 'Swiggy', category: 'Groceries', amount: 450, key: 'groceries', initial: 'SW', color: AppColors.green),
    TxItem(name: 'Uber', category: 'Transport', amount: 220, key: 'transport', initial: 'UB', color: AppColors.cyan),
  ]),
  TxGroup('Yesterday', [
    TxItem(name: 'Netflix', category: 'Subscriptions', amount: 649, key: 'subscriptions', initial: 'NF', color: AppColors.purple),
    TxItem(name: 'Big Bazaar', category: 'Groceries', amount: 1850, key: 'groceries', initial: 'BB', color: AppColors.green),
  ]),
  TxGroup('Jan 17', [
    TxItem(name: 'Electricity Board', category: 'Utilities', amount: 2100, key: 'utilities', initial: 'EB', color: AppColors.pink),
    TxItem(name: 'Amazon', category: 'Other', amount: 1299, key: 'other', initial: 'AM', color: AppColors.slate),
  ]),
  TxGroup('Jan 15', [
    TxItem(name: 'House Rent', category: 'Housing', amount: 18000, key: 'housing', initial: 'HR', color: AppColors.blue),
    TxItem(name: 'Spotify', category: 'Subscriptions', amount: 119, key: 'subscriptions', initial: 'SP', color: AppColors.purple),
  ]),
  TxGroup('Jan 12', [
    TxItem(name: 'Petrol Pump', category: 'Transport', amount: 1500, key: 'transport', initial: 'PP', color: AppColors.cyan),
    TxItem(name: 'Local Store', category: 'Other', amount: 680, key: 'other', initial: 'LS', color: AppColors.slate),
  ]),
  TxGroup('Jan 8', [
    TxItem(name: 'Zomato', category: 'Groceries', amount: 380, key: 'groceries', initial: 'ZM', color: AppColors.green),
    TxItem(name: 'Gym Membership', category: 'Subscriptions', amount: 1200, key: 'subscriptions', initial: 'GY', color: AppColors.purple),
  ]),
];

final List<Investment> kInvestments = [
  const Investment(type: 'FD', institution: 'HDFC Bank', principal: 165000, maturityValue: 182000, rate: '7.1%', maturity: 'Apr 18, 2026', status: 'Maturing soon'),
  const Investment(type: 'FD', institution: 'SBI', principal: 150000, maturityValue: 160200, rate: '6.8%', maturity: 'Dec 4, 2026', status: 'Active'),
  const Investment(type: 'PPF', institution: 'Post Office', principal: 485000, maturityValue: 485000, rate: '7.1%', maturity: 'Mar 2032', status: 'Active'),
  const Investment(type: 'RD', institution: 'ICICI Bank', principal: 60000, maturityValue: 60000, rate: '6.5%', maturity: 'Jan 2027', status: 'Active'),
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
  (key: 'insurance', label: 'Insurance'),
  (key: 'housing', label: 'Housing'),
  (key: 'subscriptions', label: 'Subscriptions'),
  (key: 'groceries', label: 'Groceries'),
  (key: 'utilities', label: 'Utilities'),
  (key: 'transport', label: 'Transport'),
];

const List<Color> kCustomColors = [
  Color(0xFFF472B6),
  Color(0xFFFDE047),
  Color(0xFF67E8F9),
  Color(0xFFFCA5A5),
  Color(0xFFA78BFA),
  Color(0xFFFDBA74),
];

/// housing + groceries + utilities + transport + subscriptions + other.
const double kRecurringBaseline = 47800;
const double kJanRequired = 46700;
const double kJanSpentSoFar = 32450;
