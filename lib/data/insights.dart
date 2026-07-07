import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/theme.dart';
import 'app_state.dart';
import 'models.dart';
import 'real_insights.dart';
import 'seed_data.dart';

// ---- View-model types rendered by the screens -------------------------------

class BarSpec {
  const BarSpec({required this.label, required this.height, required this.color, this.tag = ''});
  final String label;
  final double height;
  final Color color;
  final String tag;
}

class CategoryRow {
  const CategoryRow({required this.name, required this.color, required this.amount, required this.pct});
  final String name;
  final Color color;
  final String amount;
  final double pct;
}

class BillRow {
  const BillRow({required this.name, required this.due, required this.amount, required this.initial, required this.color, required this.bgColor});
  final String name;
  final String due;
  final String amount;
  final String initial;
  final Color color;
  final Color bgColor;
}

class TxRow {
  const TxRow({required this.name, required this.category, required this.amount, required this.initial, required this.color, required this.bgColor});
  final String name;
  final String category;
  final String amount;
  final String initial;
  final Color color;
  final Color bgColor;
}

class TxGroupView {
  const TxGroupView({required this.date, required this.items});
  final String date;
  final List<TxRow> items;
}

class InvestmentRow {
  const InvestmentRow({
    required this.type,
    required this.institution,
    required this.principal,
    required this.rate,
    required this.maturity,
    required this.status,
    required this.color,
    required this.bgColor,
    required this.statusColor,
    required this.statusBg,
  });
  final String type;
  final String institution;
  final String principal;
  final String rate;
  final String maturity;
  final String status;
  final Color color;
  final Color bgColor;
  final Color statusColor;
  final Color statusBg;
}

class AlertCard {
  const AlertCard({required this.text, required this.bg, required this.border, required this.isPositive, required this.isAlert, required this.iconColor});
  final String text;
  final Color bg;
  final Color border;
  final bool isPositive;
  final bool isAlert;
  final Color iconColor;
}

/// The full derived model for the app, computed purely from an [AppState].
/// This is a faithful Dart port of the prototype's `renderVals()`.
class Insights {
  const Insights({
    required this.febRequired,
    required this.janRemaining,
    required this.heroLabel,
    required this.heroAmount,
    required this.heroSubText,
    required this.heroSubColor,
    required this.heroTrendBars,
    required this.balanceCheckLabel,
    required this.balanceAvailable,
    required this.balanceRequired,
    required this.balanceResultLabel,
    required this.balanceResultColor,
    required this.balanceResultAmount,
    required this.categoriesTop,
    required this.categoriesFull,
    required this.chartBars,
    required this.yearForecast,
    required this.yearTotalLabel,
    required this.peakMonthLabel,
    required this.driverAmount,
    required this.driverText,
    required this.alerts,
    required this.upcomingBills,
    required this.dateGroups,
    required this.txCountLabel,
    required this.investments,
    required this.investTotal,
    required this.fdMaturityDate,
    required this.fdMaturityValue,
    required this.fdRenewTarget,
    required this.fdTopUpAmount,
    required this.fdMonthlyPlanAmount,
    required this.fdTopUpMonths,
    required this.roundoffDoneText,
    required this.breakdownMonthLabel,
    required this.driverTitle,
  });

  final double febRequired;
  final double janRemaining;
  final String heroLabel;
  final String heroAmount;
  final String heroSubText;
  final Color heroSubColor;
  final List<BarSpec> heroTrendBars;
  final String balanceCheckLabel;
  final String balanceAvailable;
  final String balanceRequired;
  final String balanceResultLabel;
  final Color balanceResultColor;
  final String balanceResultAmount;
  final List<CategoryRow> categoriesTop;
  final List<CategoryRow> categoriesFull;
  final List<BarSpec> chartBars;
  final List<BarSpec> yearForecast;
  final String yearTotalLabel;
  final String peakMonthLabel;
  final String driverAmount;
  final String driverText;
  final List<AlertCard> alerts;
  final List<BillRow> upcomingBills;
  final List<TxGroupView> dateGroups;
  final String txCountLabel;
  final List<InvestmentRow> investments;
  final String investTotal;
  final String fdMaturityDate;
  final String fdMaturityValue;
  final String fdRenewTarget;
  final String fdTopUpAmount;
  final String fdMonthlyPlanAmount;
  final int fdTopUpMonths;
  final String roundoffDoneText;
  final String breakdownMonthLabel; // e.g. "February" / "August"
  final String driverTitle; // e.g. "Why February is higher"

  static Insights compute(AppState s) {
    // Once the user has real data (confirmed obligations, or a connected Gmail
    // account), drive the whole forecast from it on the real calendar. The demo
    // scenario is shown only in pure "sample data" mode.
    if (s.manualTx.isNotEmpty || s.gmailEmail.isNotEmpty) return computeRealInsights(s);

    final isDark = s.isDark;
    const amber = AppColors.amber;
    const teal = AppColors.teal;
    final muted = isDark ? const Color(0xFF96A0B2) : const Color(0xFF5B6472);
    final tealHalf = teal.withValues(alpha: 0.5);
    const barNeutralDark = Color(0xFF3A4150);
    const barNeutralLight = Color(0xFF9AA3B2);

    // Contributions that land in February.
    final npsFeb = s.nps.contributionIn('Feb');
    final ppfFeb = s.ppf.contributionIn('Feb');
    final mfFeb = s.mf.contributionIn('Feb');

    const fdTopUpMonths = 3;
    final fdMonthlyPlan = ((200000 - 182000) / fdTopUpMonths).ceil().toDouble(); // 6000
    final fdTopupFeb = s.fdRoundoffChoice == 'yes' ? fdMonthlyPlan : 0.0;

    // Custom recurring plans, each assigned a palette color.
    final customColors = [
      for (var i = 0; i < s.customPlans.length; i++) kCustomColors[i % kCustomColors.length]
    ];
    final customFebTotal =
        s.customPlans.fold<double>(0, (a, p) => a + p.contributionIn('Feb'));

    final febBaseTotal = kCatsNext.fold<double>(0, (a, c) => a + c.amount); // 94800
    final febRequired =
        febBaseTotal + npsFeb + ppfFeb + mfFeb + fdTopupFeb + customFebTotal;
    const janRequired = kJanRequired; // 46700
    final janRemaining = kJanRequired - kJanSpentSoFar; // 14250

    // Hero trend bars (max 56px); the Feb bar reflects the live total.
    final trend = kTrend
        .map((t) => t.label == 'Feb' ? (label: 'Feb', v: febRequired) : t)
        .toList();
    final maxTrend = trend.map((t) => t.v).reduce(math.max);
    final heroTrendBars = trend
        .map((t) => BarSpec(
              label: t.label,
              height: math.max(4, (t.v / maxTrend * 56).round()).toDouble(),
              color: t.label == 'Feb' ? amber : tealHalf,
            ))
        .toList();

    // 12-month rolling forecast, driven by every setup choice.
    final yearRaw = kMonths.map((m) {
      if (m == 'Jan') return (month: m, total: janRequired.toDouble(), isActual: true);
      var total = kRecurringBaseline;
      if (m == 'Feb') total += 47000;
      total += s.nps.contributionIn(m);
      total += s.ppf.contributionIn(m);
      total += s.mf.contributionIn(m);
      if (s.fdRoundoffChoice == 'yes' && (m == 'Feb' || m == 'Mar' || m == 'Apr')) {
        total += fdMonthlyPlan;
      }
      for (final p in s.customPlans) {
        total += p.contributionIn(m);
      }
      return (month: m, total: total, isActual: false);
    }).toList();
    final yearMax = yearRaw.map((y) => y.total).reduce(math.max);
    final yearTotal = yearRaw.fold<double>(0, (a, y) => a + y.total);
    final peak = yearRaw.reduce((a, b) => b.total > a.total ? b : a);
    final yearForecast = yearRaw
        .map((y) => BarSpec(
              label: y.month,
              height: math.max(6, (y.total / yearMax * 120).round()).toDouble(),
              color: y.isActual
                  ? tealHalf
                  : (y.month == peak.month
                      ? amber
                      : (isDark ? barNeutralDark : barNeutralLight)),
            ))
        .toList();

    // Insights chart bars (max 140px).
    final chartBars = trend
        .map((t) => BarSpec(
              label: t.label,
              tag: t.label == 'Feb' ? 'proj' : '',
              height: math.max(6, (t.v / maxTrend * 140).round()).toDouble(),
              color: t.label == 'Feb' ? amber : barNeutralDark,
            ))
        .toList();

    // Category breakdown (contributions appended when they land in Feb).
    final cats = <({String name, Color color, double amount})>[
      for (final c in kCatsNext) (name: c.name, color: c.color, amount: c.amount),
    ];
    if (ppfFeb > 0) cats.add((name: 'PPF', color: AppColors.violet, amount: ppfFeb));
    if (npsFeb > 0) cats.add((name: 'NPS', color: AppColors.lime, amount: npsFeb));
    if (mfFeb > 0) cats.add((name: 'Mutual Fund', color: AppColors.orange, amount: mfFeb));
    if (fdTopupFeb > 0) {
      cats.add((name: 'FD top-up savings', color: AppColors.tealLight, amount: fdTopupFeb));
    }
    for (var i = 0; i < s.customPlans.length; i++) {
      final feb = s.customPlans[i].contributionIn('Feb');
      if (feb > 0) cats.add((name: s.customPlans[i].name, color: customColors[i], amount: feb));
    }
    final maxCat = cats.map((c) => c.amount).reduce(math.max);
    final sortedCats = [...cats]..sort((a, b) => b.amount.compareTo(a.amount));
    CategoryRow toCatRow(({String name, Color color, double amount}) c) => CategoryRow(
          name: c.name,
          color: c.color,
          amount: inr(c.amount),
          pct: (c.amount / maxCat * 100).round().toDouble(),
        );
    final categoriesFull = sortedCats.map(toCatRow).toList();
    final categoriesTop = sortedCats.take(5).map(toCatRow).toList();

    // Balance check.
    double numOr(String v, double d) {
      final n = double.tryParse(v);
      return (n == null || n == 0) ? d : n;
    }

    final salaryNum = numOr(s.salary, 85000);
    final balanceNum = numOr(s.currentBalance, 38000);
    final janAvailable = balanceNum;
    final janResult = janAvailable - janRemaining;
    final febAvailable = balanceNum + salaryNum - janRemaining;
    final febResult = febAvailable - febRequired;
    final isCurrent = s.monthView == 'current';
    final resultVal = isCurrent ? janResult : febResult;
    final balanceResultColor = resultVal >= 0 ? AppColors.green : AppColors.pink;

    // Hero.
    final febDelta = febRequired - janRequired;
    final deltaParts = <String>['insurance'];
    if (ppfFeb > 0) deltaParts.add('PPF');
    if (npsFeb > 0) deltaParts.add('NPS');
    if (mfFeb > 0) deltaParts.add('mutual fund SIP');
    if (fdTopupFeb > 0) deltaParts.add('FD top-up plan');
    for (var i = 0; i < s.customPlans.length; i++) {
      if (s.customPlans[i].contributionIn('Feb') > 0) deltaParts.add(s.customPlans[i].name);
    }
    final heroSubText = isCurrent
        ? 'On pace for ${inr(46700)} by month end'
        : '▲ ${inr(febDelta)} more than January — mainly ${deltaParts.join(' & ')}';

    // "Why February is higher" driver text.
    final namedDrivers = <String>['your annual life insurance premium (${inr(47000)})'];
    if (ppfFeb > 0) namedDrivers.add('your PPF contribution (${inr(ppfFeb)})');
    if (npsFeb > 0) namedDrivers.add('your NPS contribution (${inr(npsFeb)})');
    if (mfFeb > 0) namedDrivers.add('your Mutual Fund SIP (${inr(mfFeb)})');
    if (fdTopupFeb > 0) namedDrivers.add('your FD top-up savings plan (${inr(fdTopupFeb)})');
    for (var i = 0; i < s.customPlans.length; i++) {
      final feb = s.customPlans[i].contributionIn('Feb');
      if (feb > 0) namedDrivers.add('${s.customPlans[i].name} (${inr(feb)})');
    }
    final namedTotal = 47000 + ppfFeb + npsFeb + mfFeb + fdTopupFeb + customFebTotal;
    final residual = febDelta - namedTotal;
    final driverText = namedDrivers.length > 1
        ? 'Driven by ${namedDrivers.sublist(0, namedDrivers.length - 1).join(', ')} and ${namedDrivers.last}. Everything else is up only ~${inr(math.max(residual, 0))} combined.'
        : 'Driven almost entirely by ${namedDrivers[0]}, due Feb 14. Everything else is up only ~${inr(math.max(residual, 0))} combined.';

    // Alerts.
    final alerts = <AlertCard>[
      AlertCard(
        text: febResult >= 0
            ? "Even after insurance, NPS & PPF, you're projected to have a ${inr(febResult)} surplus in February."
            : "You'll be short by ${inr(febResult.abs())} in February once insurance, NPS & PPF land — move money in ahead of time.",
        bg: (febResult >= 0 ? AppColors.green : AppColors.pink).withValues(alpha: 0.08),
        border: (febResult >= 0 ? AppColors.green : AppColors.pink).withValues(alpha: febResult >= 0 ? 0.25 : 0.30),
        isAlert: febResult < 0,
        isPositive: febResult >= 0,
        iconColor: AppColors.pink,
      ),
      AlertCard(
        text: 'Insurance premium due Feb 14 — this single charge is ~46× your average category spend.',
        bg: amber.withValues(alpha: 0.08),
        border: amber.withValues(alpha: 0.25),
        isAlert: true,
        isPositive: false,
        iconColor: amber,
      ),
      AlertCard(
        text: "Groceries trending 3% below last month's average — nice work.",
        bg: AppColors.green.withValues(alpha: 0.08),
        border: AppColors.green.withValues(alpha: 0.25),
        isAlert: false,
        isPositive: true,
        iconColor: AppColors.green,
      ),
    ];

    // Upcoming bills (manually-added recurring ones surface first).
    final manualBills = s.manualTx
        .where((e) => e.recurring)
        .map((e) => BillRow(
              name: e.name,
              due: 'Monthly · added manually',
              amount: inr(e.amount),
              initial: e.initial,
              color: e.color,
              bgColor: e.bgColor,
            ));
    final upcomingBills = [
      ...manualBills,
      ...kBills.map((b) => BillRow(
            name: b.name,
            due: b.due,
            amount: inr(b.amount),
            initial: b.initial,
            color: b.color,
            bgColor: b.bgColor,
          )),
    ];

    // Investments.
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
      final withdrawn = inv.status == 'Withdrawn';
      return InvestmentRow(
        type: inv.type,
        institution: inv.institution,
        principal: inr(inv.principal),
        rate: inv.rate,
        maturity: inv.maturity,
        status: inv.status,
        color: c,
        bgColor: c.withValues(alpha: 0.13),
        statusColor: soon ? amber : (withdrawn ? const Color(0xFF5C6579) : AppColors.green),
        statusBg: soon
            ? amber.withValues(alpha: 0.15)
            : (withdrawn ? const Color(0xFF5C6579).withValues(alpha: 0.18) : AppColors.green.withValues(alpha: 0.12)),
      );
    }).toList();
    final investTotal = inr(allInvest.fold<double>(0, (a, b) => a + b.principal));

    // Transactions, grouped by date, filtered.
    final f = s.txFilter;
    final manualGroup = s.manualTx.isNotEmpty
        ? [
            TxGroupView(
              date: 'Added manually',
              items: s.manualTx
                  .where((it) => f == 'all' || it.categoryKey == f)
                  .map((it) => TxRow(
                        name: it.name,
                        category: it.category,
                        amount: '-${inr(it.amount)}',
                        initial: it.initial,
                        color: it.color,
                        bgColor: it.bgColor,
                      ))
                  .toList(),
            )
          ]
        : <TxGroupView>[];
    final seedGroups = kTransactions
        .map((g) => TxGroupView(
              date: g.date,
              items: g.items
                  .where((it) => f == 'all' || it.key == f)
                  .map((it) => TxRow(
                        name: it.name,
                        category: it.category,
                        amount: '-${inr(it.amount)}',
                        initial: it.initial,
                        color: it.color,
                        bgColor: it.bgColor,
                      ))
                  .toList(),
            ))
        .toList();
    final dateGroups =
        [...manualGroup, ...seedGroups].where((g) => g.items.isNotEmpty).toList();

    final roundoffDoneText = s.fdRoundoffChoice == 'yes'
        ? 'Savings plan active — ${inr(fdMonthlyPlan)}/month for $fdTopUpMonths months gets you to ${inr(200000)} by maturity. Added to your forecast.'
        : "Skipped — you'll take the ${inr(182000)} payout as-is at maturity.";

    return Insights(
      febRequired: febRequired,
      janRemaining: janRemaining,
      heroLabel: isCurrent ? 'Spent so far · January' : 'Projected total · February',
      heroAmount: isCurrent ? inr(kJanSpentSoFar) : inr(febRequired),
      heroSubText: heroSubText,
      heroSubColor: isCurrent ? muted : amber,
      heroTrendBars: heroTrendBars,
      balanceCheckLabel: isCurrent ? 'this month' : 'next month',
      balanceAvailable: inr(isCurrent ? janAvailable : febAvailable),
      balanceRequired: inr(isCurrent ? janRemaining : febRequired),
      balanceResultLabel: resultVal >= 0 ? 'Projected surplus' : 'Projected shortfall',
      balanceResultColor: balanceResultColor,
      balanceResultAmount: '${resultVal >= 0 ? '+' : '-'}${inr(resultVal.abs())}',
      categoriesTop: categoriesTop,
      categoriesFull: categoriesFull,
      chartBars: chartBars,
      yearForecast: yearForecast,
      yearTotalLabel: inr(yearTotal),
      peakMonthLabel: '${peak.month} · ${inr(peak.total)}',
      driverAmount: '+${inr(febDelta)}',
      driverText: driverText,
      alerts: alerts,
      upcomingBills: upcomingBills,
      dateGroups: dateGroups,
      txCountLabel: f == 'all' ? '247 scanned from Gmail' : 'Filtered view',
      investments: investments,
      investTotal: investTotal,
      fdMaturityDate: 'Apr 18',
      fdMaturityValue: inr(182000),
      fdRenewTarget: inr(200000),
      fdTopUpAmount: inr(200000 - 182000),
      fdMonthlyPlanAmount: inr(fdMonthlyPlan),
      fdTopUpMonths: fdTopUpMonths,
      roundoffDoneText: roundoffDoneText,
      breakdownMonthLabel: 'February',
      driverTitle: 'Why February is higher',
    );
  }
}
