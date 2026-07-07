import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/format.dart';
import '../core/theme.dart';
import 'app_state.dart';
import 'insights.dart';
import 'models.dart';
import 'seed_data.dart';

/// Builds the forecast from the user's **real** confirmed obligations (Gmail /
/// manual) plus their configured NPS/PPF/MF/custom contributions, placed on the
/// real calendar. Returns the same [Insights] shape the screens already render.
///
/// [nowOverride] makes it deterministic in tests.
Insights computeRealInsights(AppState s, {DateTime? nowOverride}) {
  final now = nowOverride ?? DateTime.now();
  final isDark = s.isDark;
  const amber = AppColors.amber;
  const teal = AppColors.teal;
  final muted = isDark ? const Color(0xFF96A0B2) : const Color(0xFF5B6472);
  final tealHalf = teal.withValues(alpha: 0.5);
  final barNeutral = isDark ? const Color(0xFF3A4150) : const Color(0xFF9AA3B2);

  final curYm = now.year * 12 + (now.month - 1);
  String abbrevOf(int ym) => kMonths[ym % 12];
  String fullOf(int ym) => DateFormat('MMMM').format(DateTime(ym ~/ 12, (ym % 12) + 1));

  // Amount an obligation contributes to a given absolute year-month.
  double obliInYm(ExpenseEntry o, int ym) {
    final due = o.dueDate;
    switch (o.recurrence) {
      case 'monthly':
        return o.amount;
      case 'quarterly':
        final anchor = due == null ? curYm : due.year * 12 + (due.month - 1);
        return (ym >= math.min(anchor, curYm) && (ym - anchor) % 3 == 0) ? o.amount : 0;
      case 'annual':
        final anchorMonth = (due?.month ?? now.month) - 1; // 0..11
        return ym % 12 == anchorMonth ? o.amount : 0;
      default: // one-time
        if (due == null) return ym == curYm + 1 ? o.amount : 0; // undated → next month
        final dueYm = due.year * 12 + (due.month - 1);
        return ym == dueYm ? o.amount : 0;
    }
  }

  double contribInAbbr(String a) =>
      s.nps.contributionIn(a) +
      s.ppf.contributionIn(a) +
      s.mf.contributionIn(a) +
      s.customPlans.fold<double>(0, (x, c) => x + c.contributionIn(a));

  // 12-month rolling totals from the current month.
  final totals = List.generate(12, (i) {
    final ym = curYm + i;
    final oblis = s.manualTx.fold<double>(0, (x, o) => x + obliInYm(o, ym));
    return oblis + contribInAbbr(abbrevOf(ym));
  });

  final isCurrent = s.monthView == 'current';
  final selIdx = isCurrent ? 0 : 1;
  final thisTotal = totals[0];
  final nextTotal = totals[1];
  final selTotal = totals[selIdx];
  final selYm = curYm + selIdx;
  final selAbbr = abbrevOf(selYm);

  // ---- Category breakdown for the selected month ----------------------------
  final catMap = <String, ({Color color, double amount})>{};
  void addCat(String name, Color color, double amount) {
    if (amount <= 0) return;
    final e = catMap[name];
    catMap[name] = (color: color, amount: (e?.amount ?? 0) + amount);
  }

  for (final o in s.manualTx) {
    addCat(o.category, o.color, obliInYm(o, selYm));
  }
  addCat('PPF', AppColors.violet, s.ppf.contributionIn(selAbbr));
  addCat('NPS', AppColors.lime, s.nps.contributionIn(selAbbr));
  addCat('Mutual Fund', AppColors.orange, s.mf.contributionIn(selAbbr));
  for (var i = 0; i < s.customPlans.length; i++) {
    addCat(s.customPlans[i].name, kCustomColors[i % kCustomColors.length], s.customPlans[i].contributionIn(selAbbr));
  }
  final catList = catMap.entries
      .map((e) => (name: e.key, color: e.value.color, amount: e.value.amount))
      .toList()
    ..sort((a, b) => b.amount.compareTo(a.amount));
  final maxCat = catList.isEmpty ? 1.0 : catList.map((c) => c.amount).reduce(math.max);
  CategoryRow toRow(({String name, Color color, double amount}) c) => CategoryRow(
        name: c.name,
        color: c.color,
        amount: inr(c.amount),
        pct: (c.amount / maxCat * 100).round().toDouble(),
      );
  final categoriesFull = catList.map(toRow).toList();
  final categoriesTop = catList.take(5).map(toRow).toList();

  // ---- Charts ---------------------------------------------------------------
  final trend7 = totals.take(7).toList();
  final maxTrend = trend7.fold<double>(1, (m, v) => math.max(m, v));
  final heroTrendBars = List.generate(7, (i) {
    return BarSpec(
      label: abbrevOf(curYm + i),
      height: math.max(4, (totals[i] / maxTrend * 56).round()).toDouble(),
      color: i == selIdx ? amber : tealHalf,
    );
  });
  final chartBars = List.generate(7, (i) {
    return BarSpec(
      label: abbrevOf(curYm + i),
      tag: i == selIdx ? 'proj' : '',
      height: math.max(6, (totals[i] / maxTrend * 140).round()).toDouble(),
      color: i == selIdx ? amber : const Color(0xFF3A4150),
    );
  });

  final yearMax = totals.fold<double>(1, (m, v) => math.max(m, v));
  final yearTotal = totals.fold<double>(0, (a, v) => a + v);
  var peakIdx = 0;
  for (var i = 1; i < 12; i++) {
    if (totals[i] > totals[peakIdx]) peakIdx = i;
  }
  final yearForecast = List.generate(12, (i) {
    return BarSpec(
      label: abbrevOf(curYm + i),
      height: math.max(6, (totals[i] / yearMax * 120).round()).toDouble(),
      color: i == 0 ? tealHalf : (i == peakIdx ? amber : barNeutral),
    );
  });

  // ---- Balance check --------------------------------------------------------
  double numOr(String v, double d) => double.tryParse(v) ?? d;
  final salary = numOr(s.salary, 0);
  final balance = numOr(s.currentBalance, 0);
  final available = isCurrent ? balance : (balance + salary - thisTotal);
  final result = available - selTotal;
  final resultColor = result >= 0 ? AppColors.green : AppColors.pink;

  // ---- Drivers (what makes the selected month what it is) -------------------
  final drivers = <({String name, double amount})>[];
  for (final o in s.manualTx) {
    final a = obliInYm(o, selYm);
    if (a > 0) drivers.add((name: o.name, amount: a));
  }
  if (s.ppf.contributionIn(selAbbr) > 0) drivers.add((name: 'PPF', amount: s.ppf.contributionIn(selAbbr)));
  if (s.nps.contributionIn(selAbbr) > 0) drivers.add((name: 'NPS', amount: s.nps.contributionIn(selAbbr)));
  if (s.mf.contributionIn(selAbbr) > 0) drivers.add((name: 'Mutual Fund SIP', amount: s.mf.contributionIn(selAbbr)));
  drivers.sort((a, b) => b.amount.compareTo(a.amount));
  final topNames = drivers.take(3).map((d) => d.name).toList();

  final selMonthName = fullOf(selYm);
  final thisMonthName = fullOf(curYm);
  final delta = nextTotal - thisTotal;
  final heroSubText = isCurrent
      ? 'Total due in $selMonthName'
      : (delta >= 0
          ? '▲ ${inr(delta)} more than $thisMonthName${topNames.isEmpty ? '' : ' — mainly ${topNames.join(' & ')}'}'
          : '▼ ${inr(delta.abs())} less than $thisMonthName');

  final driverText = drivers.isEmpty
      ? 'Nothing scheduled for $selMonthName yet — add bills or connect Gmail to fill in your forecast.'
      : 'Driven by ${drivers.take(3).map((d) => '${d.name} (${inr(d.amount)})').join(', ')}'
          '${drivers.length > 3 ? ', plus ${drivers.length - 3} more' : ''}.';

  // ---- Upcoming bills (sorted by next occurrence) ---------------------------
  DateTime clampDay(int year, int month, int day) => DateTime(year, month, math.min(day, 28));
  DateTime nextDue(ExpenseEntry o) {
    final due = o.dueDate;
    final today = DateTime(now.year, now.month, now.day);
    switch (o.recurrence) {
      case 'monthly':
        final day = due?.day ?? 1;
        var d = clampDay(now.year, now.month, day);
        if (d.isBefore(today)) d = clampDay(now.year, now.month + 1, day);
        return d;
      case 'annual':
        var d = clampDay(now.year, due?.month ?? now.month, due?.day ?? 1);
        if (d.isBefore(today)) d = clampDay(now.year + 1, due?.month ?? now.month, due?.day ?? 1);
        return d;
      case 'quarterly':
        var d = due ?? clampDay(now.year, now.month, 1);
        while (d.isBefore(today)) {
          d = clampDay(d.year, d.month + 3, due?.day ?? 1);
        }
        return d;
      default:
        return due ?? clampDay(now.year, now.month + 1, 1);
    }
  }

  String recurLabel(String r) => switch (r) {
        'monthly' => 'Recurring',
        'quarterly' => 'Quarterly',
        'annual' => 'Annual',
        _ => 'One-time',
      };

  final sortedBills = [...s.manualTx]..sort((a, b) => nextDue(a).compareTo(nextDue(b)));
  final upcomingBills = sortedBills
      .map((o) => BillRow(
            name: o.name,
            due: 'Due ${DateFormat('d MMM').format(nextDue(o))} · ${recurLabel(o.recurrence)}',
            amount: inr(o.amount),
            initial: o.initial,
            color: o.color,
            bgColor: o.bgColor,
          ))
      .toList();

  // ---- Activity list (the confirmed bills, filtered) ------------------------
  final f = s.txFilter;
  final txItems = sortedBills
      .where((o) => f == 'all' || o.categoryKey == f)
      .map((o) => TxRow(
            name: o.name,
            category: o.category,
            amount: '-${inr(o.amount)}',
            initial: o.initial,
            color: o.color,
            bgColor: o.bgColor,
          ))
      .toList();
  final dateGroups = txItems.isEmpty ? <TxGroupView>[] : [TxGroupView(date: 'Your bills', items: txItems)];

  // ---- Alerts ---------------------------------------------------------------
  final alerts = <AlertCard>[
    AlertCard(
      text: result >= 0
          ? "You're projected to have a ${inr(result)} surplus in $selMonthName."
          : "You'll be short by ${inr(result.abs())} in $selMonthName — set money aside ahead of time.",
      bg: (result >= 0 ? AppColors.green : AppColors.pink).withValues(alpha: 0.08),
      border: (result >= 0 ? AppColors.green : AppColors.pink).withValues(alpha: result >= 0 ? 0.25 : 0.30),
      isAlert: result < 0,
      isPositive: result >= 0,
      iconColor: AppColors.pink,
    ),
    if (drivers.isNotEmpty)
      AlertCard(
        text: '${drivers.first.name} is your biggest item in $selMonthName at ${inr(drivers.first.amount)}.',
        bg: amber.withValues(alpha: 0.08),
        border: amber.withValues(alpha: 0.25),
        isAlert: true,
        isPositive: false,
        iconColor: amber,
      ),
  ];

  // ---- Investments (same as the demo view) ----------------------------------
  final mfEntry = s.mf.enabled
      ? [
          Investment(
            type: 'MF',
            institution: s.mf.frequency == 'monthly' ? 'Index Fund SIP' : 'Index Fund (lump sum)',
            principal: s.mf.amountValue,
            maturityValue: 0,
            rate: '~12% avg',
            maturity: s.mf.frequency == 'monthly' ? 'Ongoing SIP' : 'Planned ${s.mf.month}',
            status: 'Active',
          )
        ]
      : <Investment>[];
  final customInvest = [
    for (final p in s.customPlans)
      Investment(
        type: 'Other',
        institution: p.name,
        principal: p.amount,
        maturityValue: 0,
        rate: '—',
        maturity: p.frequency == 'monthly' ? 'Ongoing' : 'Planned ${p.month}',
        status: 'Active',
      )
  ];
  final allInvest = [...kInvestments, ...mfEntry, ...customInvest, ...s.manualInvestments];
  final investments = allInvest.map((inv) {
    final c = kTypeColors[inv.type] ?? kTypeColors['Other']!;
    final soon = inv.status == 'Maturing soon';
    return InvestmentRow(
      type: inv.type,
      institution: inv.institution,
      principal: inr(inv.principal),
      rate: inv.rate,
      maturity: inv.maturity,
      status: inv.status,
      color: c,
      bgColor: c.withValues(alpha: 0.13),
      statusColor: soon ? amber : AppColors.green,
      statusBg: soon ? amber.withValues(alpha: 0.15) : AppColors.green.withValues(alpha: 0.12),
    );
  }).toList();
  final investTotal = inr(allInvest.fold<double>(0, (a, b) => a + b.principal));

  return Insights(
    febRequired: nextTotal,
    janRemaining: thisTotal,
    heroLabel: 'Projected total · $selMonthName',
    heroAmount: inr(selTotal),
    heroSubText: heroSubText,
    heroSubColor: isCurrent ? muted : (delta >= 0 ? amber : AppColors.green),
    heroTrendBars: heroTrendBars,
    balanceCheckLabel: isCurrent ? 'this month' : 'next month',
    balanceAvailable: inr(available),
    balanceRequired: inr(selTotal),
    balanceResultLabel: result >= 0 ? 'Projected surplus' : 'Projected shortfall',
    balanceResultColor: resultColor,
    balanceResultAmount: '${result >= 0 ? '+' : '-'}${inr(result.abs())}',
    categoriesTop: categoriesTop,
    categoriesFull: categoriesFull,
    chartBars: chartBars,
    yearForecast: yearForecast,
    yearTotalLabel: inr(yearTotal),
    peakMonthLabel: '${abbrevOf(curYm + peakIdx)} · ${inr(totals[peakIdx])}',
    driverAmount: '${delta >= 0 ? '+' : '-'}${inr(delta.abs())}',
    driverText: driverText,
    alerts: alerts,
    upcomingBills: upcomingBills,
    dateGroups: dateGroups,
    txCountLabel: f == 'all' ? '${s.manualTx.length} tracked' : 'Filtered view',
    investments: investments,
    investTotal: investTotal,
    fdMaturityDate: 'Apr 18',
    fdMaturityValue: inr(182000),
    fdRenewTarget: inr(200000),
    fdTopUpAmount: inr(18000),
    fdMonthlyPlanAmount: inr(6000),
    fdTopUpMonths: 3,
    roundoffDoneText: s.fdRoundoffChoice == 'yes'
        ? 'Savings plan active — ${inr(6000)}/month for 3 months. Added to your forecast.'
        : "Skipped — you'll take the ${inr(182000)} payout as-is at maturity.",
    breakdownMonthLabel: selMonthName,
    driverTitle: 'Why $selMonthName looks like this',
  );
}
