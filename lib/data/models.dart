import 'package:flutter/material.dart';

/// A recurring contribution plan (NPS / PPF / Mutual Fund) configured during
/// onboarding. Mirrors the `npsEnabled/npsAmount/npsFrequency/npsMonth` group
/// of state fields in the design.
class ContribPlan {
  const ContribPlan({
    required this.enabled,
    required this.amount,
    required this.frequency, // 'monthly' | 'lumpsum'
    required this.month, // three-letter month, e.g. 'Feb'
  });

  final bool enabled;
  final String amount; // raw text-field value
  final String frequency;
  final String month;

  bool get isLumpsum => frequency == 'lumpsum';
  double get amountValue => double.tryParse(amount) ?? 0;

  /// The amount that lands in [targetMonth] given this plan's cadence.
  double contributionIn(String targetMonth) {
    if (!enabled) return 0;
    if (frequency == 'monthly') return amountValue;
    return month == targetMonth ? amountValue : 0;
  }

  ContribPlan copyWith({bool? enabled, String? amount, String? frequency, String? month}) {
    return ContribPlan(
      enabled: enabled ?? this.enabled,
      amount: amount ?? this.amount,
      frequency: frequency ?? this.frequency,
      month: month ?? this.month,
    );
  }

  Map<String, dynamic> toJson() =>
      {'enabled': enabled, 'amount': amount, 'frequency': frequency, 'month': month};

  factory ContribPlan.fromJson(Map<String, dynamic> j) => ContribPlan(
        enabled: j['enabled'] as bool? ?? false,
        amount: j['amount'] as String? ?? '',
        frequency: j['frequency'] as String? ?? 'monthly',
        month: j['month'] as String? ?? 'Feb',
      );
}

/// A user-added recurring/lump-sum investment plan ("Anything else?").
class CustomPlan {
  const CustomPlan({
    required this.id,
    required this.name,
    required this.amount,
    required this.frequency,
    required this.month,
  });

  final String id;
  final String name;
  final double amount;
  final String frequency; // 'monthly' | 'lumpsum'
  final String month;

  double contributionIn(String targetMonth) {
    if (frequency == 'monthly') return amount;
    return month == targetMonth ? amount : 0;
  }

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'amount': amount, 'frequency': frequency, 'month': month};

  factory CustomPlan.fromJson(Map<String, dynamic> j) => CustomPlan(
        id: j['id'] as String,
        name: j['name'] as String,
        amount: (j['amount'] as num).toDouble(),
        frequency: j['frequency'] as String? ?? 'monthly',
        month: j['month'] as String? ?? 'Feb',
      );
}

/// A confirmed bill/expense obligation (from Gmail or added manually). Carries
/// a due date and recurrence so the forecast can place it on the calendar.
class ExpenseEntry {
  const ExpenseEntry({
    required this.name,
    required this.category,
    required this.categoryKey,
    required this.amount,
    required this.initial,
    required this.color,
    this.recurrence = 'onetime', // onetime | monthly | quarterly | annual
    this.dueDate,
  });

  final String name;
  final String category;
  final String categoryKey;
  final double amount;
  final String initial;
  final Color color;
  final String recurrence;
  final DateTime? dueDate;

  bool get recurring => recurrence != 'onetime';
  Color get bgColor => color.withValues(alpha: 0.13);

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'categoryKey': categoryKey,
        'amount': amount,
        'initial': initial,
        'color': color.toARGB32(),
        'recurrence': recurrence,
        'dueDate': dueDate?.toIso8601String(),
      };

  factory ExpenseEntry.fromJson(Map<String, dynamic> j) => ExpenseEntry(
        name: j['name'] as String,
        category: j['category'] as String,
        categoryKey: j['categoryKey'] as String,
        amount: (j['amount'] as num).toDouble(),
        initial: j['initial'] as String,
        color: Color(j['color'] as int),
        // Back-compat: older payloads stored a `recurring` bool.
        recurrence: j['recurrence'] as String? ??
            ((j['recurring'] as bool? ?? false) ? 'monthly' : 'onetime'),
        dueDate: j['dueDate'] != null ? DateTime.tryParse(j['dueDate'] as String) : null,
      );
}

/// An investment holding (FD / PPF / RD / MF / Other).
class Investment {
  const Investment({
    required this.type,
    required this.institution,
    required this.principal,
    required this.maturityValue,
    required this.rate,
    required this.maturity,
    required this.status,
  });

  final String type;
  final String institution;
  final double principal;
  final double maturityValue;
  final String rate;
  final String maturity;
  final String status;

  Map<String, dynamic> toJson() => {
        'type': type,
        'institution': institution,
        'principal': principal,
        'maturityValue': maturityValue,
        'rate': rate,
        'maturity': maturity,
        'status': status,
      };

  factory Investment.fromJson(Map<String, dynamic> j) => Investment(
        type: j['type'] as String,
        institution: j['institution'] as String,
        principal: (j['principal'] as num).toDouble(),
        maturityValue: (j['maturityValue'] as num?)?.toDouble() ?? 0,
        rate: j['rate'] as String? ?? '—',
        maturity: j['maturity'] as String? ?? 'TBD',
        status: j['status'] as String? ?? 'Active',
      );
}
