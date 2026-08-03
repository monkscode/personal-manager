import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/format.dart';
import '../core/theme.dart';
import '../services/forecast_adapter.dart';
import '../services/forecast_explorer.dart';
import '../services/merchant_display.dart';
import '../services/salary_income_detector.dart';
import 'app_state.dart';
import 'forecast_models.dart';
import 'insights.dart';
import 'models.dart';
import 'seed_data.dart';
import 'sms_analysis_snapshot.dart';
import 'sms_models.dart';

/// Builds the forecast from the user's **real** confirmed obligations (Gmail /
/// manual) plus their configured NPS/PPF/MF/custom contributions, placed on the
/// real calendar. Returns the same [Insights] shape the screens already render.
///
/// When [snapshot] carries SMS/obligation data the dated ledger engines drive
/// the forecast (superseding the manual two-state balance math); otherwise the
/// manual/Gmail obligations in [AppState] do. [nowOverride] makes it
/// deterministic in tests.
Insights computeRealInsights(
  AppState s, {
  SmsAnalysisSnapshot? snapshot,
  DateTime? nowOverride,
}) {
  if (snapshot != null && snapshot.hasData) {
    return _forecastInsights(s, snapshot, nowOverride);
  }
  final now = nowOverride ?? DateTime.now();
  final isDark = s.isDark;
  const amber = AppColors.amber;
  const teal = AppColors.teal;
  final muted = isDark ? const Color(0xFF96A0B2) : const Color(0xFF5B6472);
  final tealHalf = teal.withValues(alpha: 0.5);
  final barNeutral = isDark ? const Color(0xFF3A4150) : const Color(0xFF9AA3B2);

  final curYm = now.year * 12 + (now.month - 1);
  String abbrevOf(int ym) => kMonths[ym % 12];
  String fullOf(int ym) =>
      DateFormat('MMMM').format(DateTime(ym ~/ 12, (ym % 12) + 1));

  // Amount an obligation contributes to a given absolute year-month.
  double obliInYm(ExpenseEntry o, int ym) {
    final due = o.dueDate;
    switch (o.recurrence) {
      case 'monthly':
        return o.amount;
      case 'quarterly':
        if (due == null) return 0; // no guessed due month
        final anchor = due.year * 12 + (due.month - 1);
        return (ym >= math.min(anchor, curYm) && (ym - anchor) % 3 == 0)
            ? o.amount
            : 0;
      case 'annual':
        if (due == null) return 0; // no guessed due month
        final anchorMonth = due.month - 1; // 0..11
        return ym % 12 == anchorMonth ? o.amount : 0;
      default: // one-time
        if (due == null) {
          return ym == curYm + 1 ? o.amount : 0; // undated → next month
        }
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
    addCat(
      s.customPlans[i].name,
      kCustomColors[i % kCustomColors.length],
      s.customPlans[i].contributionIn(selAbbr),
    );
  }
  final catList =
      catMap.entries
          .map(
            (e) => (name: e.key, color: e.value.color, amount: e.value.amount),
          )
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
  final maxCat = catList.isEmpty
      ? 1.0
      : catList.map((c) => c.amount).reduce(math.max);
  CategoryRow toRow(({String name, Color color, double amount}) c) =>
      CategoryRow(
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
  if (s.ppf.contributionIn(selAbbr) > 0) {
    drivers.add((name: 'PPF', amount: s.ppf.contributionIn(selAbbr)));
  }
  if (s.nps.contributionIn(selAbbr) > 0) {
    drivers.add((name: 'NPS', amount: s.nps.contributionIn(selAbbr)));
  }
  if (s.mf.contributionIn(selAbbr) > 0) {
    drivers.add((
      name: 'Mutual Fund SIP',
      amount: s.mf.contributionIn(selAbbr),
    ));
  }
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
  DateTime clampDay(int year, int month, int day) =>
      DateTime(year, month, math.min(day, 28));
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
        if (d.isBefore(today)) {
          d = clampDay(now.year + 1, due?.month ?? now.month, due?.day ?? 1);
        }
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

  final sortedBills = [...s.manualTx]
    ..sort((a, b) => nextDue(a).compareTo(nextDue(b)));
  final upcomingBills = sortedBills
      .map(
        (o) => BillRow(
          name: o.name,
          due:
              'Due ${DateFormat('d MMM').format(nextDue(o))} · ${recurLabel(o.recurrence)}',
          amount: inr(o.amount),
          initial: o.initial,
          color: o.color,
          bgColor: o.bgColor,
        ),
      )
      .toList();

  // ---- Activity list (the confirmed bills, filtered) ------------------------
  final f = s.txFilter;
  final txItems = sortedBills
      .where((o) => f == 'all' || o.categoryKey == f)
      .map(
        (o) => TxRow(
          name: o.name,
          category: o.category,
          categoryKey: o.categoryKey,
          amount: '-${inr(o.amount)}',
          initial: o.initial,
          color: o.color,
          bgColor: o.bgColor,
        ),
      )
      .toList();
  final dateGroups = txItems.isEmpty
      ? <TxGroupView>[]
      : [TxGroupView(date: 'Your bills', items: txItems)];

  // ---- Alerts ---------------------------------------------------------------
  final alerts = <AlertCard>[
    AlertCard(
      text: result >= 0
          ? "You're projected to have a ${inr(result)} surplus in $selMonthName."
          : "You'll be short by ${inr(result.abs())} in $selMonthName — set money aside ahead of time.",
      bg: (result >= 0 ? AppColors.green : AppColors.pink).withValues(
        alpha: 0.08,
      ),
      border: (result >= 0 ? AppColors.green : AppColors.pink).withValues(
        alpha: result >= 0 ? 0.25 : 0.30,
      ),
      isAlert: result < 0,
      isPositive: result >= 0,
      iconColor: AppColors.pink,
    ),
    if (drivers.isNotEmpty)
      AlertCard(
        text:
            '${drivers.first.name} is your biggest item in $selMonthName at ${inr(drivers.first.amount)}.',
        bg: amber.withValues(alpha: 0.08),
        border: amber.withValues(alpha: 0.25),
        isAlert: true,
        isPositive: false,
        iconColor: amber,
      ),
  ];

  // ---- Investments ----------------------------------------------------------
  final mfEntry = s.mf.enabled
      ? [
          Investment(
            type: 'MF',
            institution: s.mf.frequency == 'monthly'
                ? 'Index Fund SIP'
                : 'Index Fund (lump sum)',
            principal: s.mf.amountValue,
            maturityValue: 0,
            rate: '~12% avg',
            maturity: s.mf.frequency == 'monthly'
                ? 'Ongoing SIP'
                : 'Planned ${s.mf.month}',
            status: 'Active',
          ),
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
      ),
  ];
  // Only the user's own configured and manually entered investments.
  final allInvest = [...mfEntry, ...customInvest, ...s.manualInvestments];
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
      statusBg: soon
          ? amber.withValues(alpha: 0.15)
          : AppColors.green.withValues(alpha: 0.12),
    );
  }).toList();
  final investTotal = inr(allInvest.fold<double>(0, (a, b) => a + b.principal));

  return Insights(
    febRequired: nextTotal,
    janRemaining: thisTotal,
    heroLabel: isCurrent
        ? 'Due this month · $selMonthName'
        : 'Projected total · $selMonthName',
    heroAmount: inr(selTotal),
    heroSubText: heroSubText,
    heroSubColor: isCurrent ? muted : (delta >= 0 ? amber : AppColors.green),
    heroTrendBars: heroTrendBars,
    balanceCheckLabel: isCurrent ? 'this month' : 'next month',
    balanceAvailable: inr(available),
    balanceRequired: inr(selTotal),
    balanceResultLabel: result >= 0
        ? 'Projected surplus'
        : 'Projected shortfall',
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
    // No real FD-maturity data source yet (the app scans bills, not holdings),
    // so the roundoff-planner card stays empty here; the screen hides it in
    // live mode instead of inventing numbers.
    fdMaturityDate: '',
    fdMaturityValue: '',
    fdRenewTarget: '',
    fdTopUpAmount: '',
    fdMonthlyPlanAmount: '',
    fdTopUpMonths: 0,
    roundoffDoneText: '',
    breakdownMonthLabel: selMonthName,
    driverTitle: 'Why $selMonthName looks like this',
  );
}

// ---- SMS forecast path ------------------------------------------------------

/// Maps a [ForecastAdapter] outlook (dated ledger over the SMS/obligation
/// snapshot) onto the [Insights] view-model. This supersedes the manual
/// two-state balance math whenever the snapshot has data.
Insights _forecastInsights(
  AppState s,
  SmsAnalysisSnapshot snapshot,
  DateTime? nowOverride,
) {
  final now = nowOverride ?? DateTime.now();
  final isDark = s.isDark;
  const amber = AppColors.amber;
  const teal = AppColors.teal;
  final muted = isDark ? const Color(0xFF96A0B2) : const Color(0xFF5B6472);
  final tealHalf = teal.withValues(alpha: 0.5);
  final barNeutral = isDark ? const Color(0xFF3A4150) : const Color(0xFF9AA3B2);

  final outlook = const ForecastAdapter().build(s, snapshot, now: now);
  final monthName = DateFormat('MMMM').format(outlook.targetMonth);

  // Build the forecast explorer from the outlook and reserve plan
  final explorer = buildForecastExplorer(
    outlook: outlook,
    reservePlan: snapshot.reservePlan,
    now: now,
  );
  final nextPlan = explorer.planAt(1);
  final nextMonthLabel = DateFormat('MMMM').format(nextPlan.monthStart);

  // ---- rolling-month outflow totals for the charts --------------------------
  int monthOutflowPaise(ForecastMonthResult m) => m.events
      .where((e) => e.direction == LedgerDirection.outflow)
      .fold(0, (acc, e) => acc + e.amountPaise);
  final totals = outlook.months
      .map((m) => monthOutflowPaise(m) / 100.0)
      .toList();
  String abbrevOf(int i) => kMonths[(outlook.targetMonth.month - 1 + i) % 12];

  final committed = outlook.salary.committedPaise;
  final expected = outlook.salary.expectedSalaryPaise;
  final shortfall = outlook.shortfallPaise;
  final surplus = outlook.surplusPaise;
  final isShort = shortfall > 0;
  final resultColor = isShort ? AppColors.pink : AppColors.green;

  final maxTrend = totals.take(7).fold<double>(1, (m, v) => math.max(m, v));
  final heroTrendBars = List.generate(
    7,
    (i) => BarSpec(
      label: abbrevOf(i),
      height: math.max(4, (totals[i] / maxTrend * 56).round()).toDouble(),
      color: i == 0 ? amber : tealHalf,
    ),
  );
  final chartBars = List.generate(
    7,
    (i) => BarSpec(
      label: abbrevOf(i),
      tag: i == 0 ? 'proj' : '',
      height: math.max(6, (totals[i] / maxTrend * 140).round()).toDouble(),
      color: i == 0 ? amber : barNeutral,
    ),
  );
  final yearMax = totals.fold<double>(1, (m, v) => math.max(m, v));
  final yearTotal = totals.fold<double>(0, (a, v) => a + v);
  var peakIdx = 0;
  for (var i = 1; i < totals.length; i++) {
    if (totals[i] > totals[peakIdx]) peakIdx = i;
  }
  final yearForecast = List.generate(
    totals.length,
    (i) => BarSpec(
      label: abbrevOf(i),
      height: math.max(6, (totals[i] / yearMax * 120).round()).toDouble(),
      color: i == 0 ? tealHalf : (i == peakIdx ? amber : barNeutral),
    ),
  );

  // ---- categories: target-month dated outflows grouped by source ------------
  final catMap = <String, ({Color color, int amountPaise})>{};
  for (final line in outlook.lines) {
    if (line.date == null) continue;
    if (_isForecastInflow(line.source)) continue;
    if (!_datedInTargetMonth(line, outlook.targetMonth)) continue;
    final (name, color) = _forecastCategory(line.source);
    final existing = catMap[name];
    catMap[name] = (
      color: color,
      amountPaise: (existing?.amountPaise ?? 0) + line.amountPaise,
    );
  }
  final catList =
      catMap.entries
          .map(
            (e) => (
              name: e.key,
              color: e.value.color,
              amount: e.value.amountPaise / 100.0,
            ),
          )
          .toList()
        ..sort((a, b) => b.amount.compareTo(a.amount));
  final maxCat = catList.isEmpty
      ? 1.0
      : catList.map((c) => c.amount).reduce(math.max);
  CategoryRow toRow(({String name, Color color, double amount}) c) =>
      CategoryRow(
        name: c.name,
        color: c.color,
        amount: inr(c.amount),
        pct: (c.amount / maxCat * 100).round().toDouble(),
      );
  final categoriesFull = catList.map(toRow).toList();
  final categoriesTop = catList.take(5).map(toRow).toList();

  // ---- upcoming bills -------------------------------------------------------
  // Only genuine dated obligations belong here: confirmed bills, recurring
  // auto-debits, credit-card statements/payments, and planned contributions —
  // never the seasonal/discretionary spending *estimate* (which the ledger
  // dates on a day-28 placeholder and reads misleadingly like a real bill).
  // We draw from the remainder of the target month plus the whole of next month
  // so a card bill or premium coming up is surfaced early, then de-duplicate by
  // owner/date/amount and order by due date.
  final today = DateTime(now.year, now.month, now.day);
  final billCandidates = <ForecastLine>[
    for (final line in outlook.lines)
      if (_isUpcomingBillLine(line) && !line.date!.isBefore(today)) line,
    for (final line in nextPlan.hardLines)
      if (_isUpcomingBillLine(line)) line,
    for (final line in outlook.forwardEarmarks)
      if (_isRealBill(line.source) && line.date != null) line,
  ];
  final seenBills = <String>{};
  final billLines = <ForecastLine>[];
  for (final line in billCandidates) {
    final key =
        '${line.ownerKey}|${line.date!.toIso8601String()}|${line.amountPaise}';
    if (seenBills.add(key)) billLines.add(line);
  }
  billLines.sort((a, b) => a.date!.compareTo(b.date!));
  final upcomingBills = billLines.take(8).map((line) {
    final (catName, color) = _forecastCategory(line.source);
    return BillRow(
      name: line.label,
      due: 'Due ${DateFormat('d MMM').format(line.date!)} · $catName',
      amount: inr(line.amountPaise / 100.0),
      initial: initials(line.label),
      color: color,
      bgColor: color.withValues(alpha: 0.13),
    );
  }).toList();

  // ---- activity: the full real SMS history, grouped by day, with readable
  // Finart-style names and categories resolved on the fly. ---------------------
  const merchantDisplay = MerchantDisplay();
  TxRow txRowFor(ParsedTxn t, {bool withDate = false}) {
    final d = merchantDisplay.resolve(t);
    final isCredit = t.direction == TransactionDirection.credit;
    final sign = isCredit ? '+' : '-';
    final color = _categoryColor(d.categoryKey);
    return TxRow(
      name: d.name,
      category: d.categoryLabel,
      categoryKey: d.categoryKey,
      amount: '$sign${inr(t.amountPaise / 100.0)}',
      initial: initials(d.name),
      color: color,
      bgColor: color.withValues(alpha: 0.14),
      date: withDate ? DateFormat('d MMM').format(t.txnDate) : '',
      amountColor: isCredit ? AppColors.green : null,
      isCredit: isCredit,
    );
  }

  final history = snapshot.allTxns.isNotEmpty
      ? snapshot.allTxns
      : snapshot.currentMonthTxns;
  final txByDay = <DateTime, List<TxRow>>{};
  for (final t in history) {
    final day = DateTime(t.txnDate.year, t.txnDate.month, t.txnDate.day);
    txByDay.putIfAbsent(day, () => []).add(txRowFor(t));
  }
  final dayKeys = txByDay.keys.toList()..sort((a, b) => b.compareTo(a));
  final dateGroups = [
    for (final day in dayKeys)
      TxGroupView(
        date: DateFormat(
          day.year == now.year ? 'd MMM' : 'd MMM yyyy',
        ).format(day),
        items: txByDay[day]!,
      ),
  ];

  // ---- Home: spent this month + recent transactions -------------------------
  final spendTxns = [
    for (final t in snapshot.currentMonthTxns)
      if (_isConsumptionSpend(t)) t,
  ];
  final spentThisMonthPaise = spendTxns.fold<int>(
    0,
    (acc, t) => acc + t.amountPaise,
  );
  final recentTx = [
    for (final t in history.take(8)) txRowFor(t, withDate: true),
  ];

  // ---- "Need for <next month>": an explainable required-vs-receive plan ------
  // Required is split into non-overlapping components so the total is honest:
  //   • everyday spending  — trailing typical spend EXCLUDING recurring owners
  //                          and cards (both surfaced separately);
  //   • seasonal uplift    — the extra the user spent the same month last year
  //                          above their everyday typical (festival awareness);
  //   • recurring payments — projected auto-debits/subscriptions for the month;
  //   • credit-card bills  — projected card statements/payments for the month;
  //   • bills & contributions — confirmed bills and planned contributions.
  final commitmentOwnerKeys = {
    for (final c in snapshot.commitments) c.merchantNorm,
  };
  final everydayBasePaise = _typicalMonthlySpendPaise(
    history,
    now,
    excludeOwnerKeys: commitmentOwnerKeys,
  );
  final everydayLastYearPaise = _monthSpendPaise(
    history,
    nextPlan.monthStart.year - 1,
    nextPlan.monthStart.month,
    excludeOwnerKeys: commitmentOwnerKeys,
  );
  final seasonalUpliftPaise = math.max(
    0,
    everydayLastYearPaise - everydayBasePaise,
  );

  int sumNextHardOutflow(bool Function(ForecastEventSource) test) => nextPlan
      .hardLines
      .where(
        (l) =>
            l.status != ForecastLineStatus.alreadyInAnchor &&
            l.status != ForecastLineStatus.opening &&
            !_isForecastInflow(l.source) &&
            test(l.source),
      )
      .fold(0, (acc, l) => acc + l.amountPaise);
  final recurringNextPaise = sumNextHardOutflow(
    (src) => src == ForecastEventSource.recurring,
  );
  final cardsNextPaise = sumNextHardOutflow(_isCardSource);
  final otherBillsNextPaise = sumNextHardOutflow(
    (src) =>
        src == ForecastEventSource.gmailBill ||
        src == ForecastEventSource.configuredContribution ||
        src == ForecastEventSource.manual,
  );

  final requiredPaise =
      everydayBasePaise +
      seasonalUpliftPaise +
      recurringNextPaise +
      cardsNextPaise +
      otherBillsNextPaise;

  // Receive: the salary the user will get next month plus any extra income seen
  // the same calendar month last year (bonus / festival credits) once we know
  // the salary base to net it against.
  final salaryProfile = snapshot.salary;
  final salaryDetected =
      salaryProfile.basePaise != null &&
      salaryProfile.confidence != SalaryConfidence.insufficientData &&
      salaryProfile.confidence != SalaryConfidence.unknown;
  final salaryNextPaise = salaryDetected ? salaryProfile.basePaise! : 0;
  final lastYearIncomePaise = _monthIncomePaise(
    history,
    nextPlan.monthStart.year - 1,
    nextPlan.monthStart.month,
  );
  final lastYearExtraPaise = salaryDetected
      ? math.max(0, lastYearIncomePaise - salaryNextPaise)
      : 0;
  final receivePaise = salaryNextPaise + lastYearExtraPaise;

  final gapPaise = requiredPaise - receivePaise;
  final needIsShort = gapPaise > 0;

  final needPlanRequiredRows = <NeedPlanRow>[
    if (everydayBasePaise > 0)
      NeedPlanRow(
        label: 'Everyday spending',
        amount: inr(everydayBasePaise / 100.0),
        color: teal,
        note: 'Your recent monthly average',
      ),
    if (seasonalUpliftPaise > 0)
      NeedPlanRow(
        label: 'Seasonal · last $nextMonthLabel',
        amount: inr(seasonalUpliftPaise / 100.0),
        color: AppColors.violet,
        note: 'Extra you spent this month last year',
      ),
    if (recurringNextPaise > 0)
      NeedPlanRow(
        label: 'Recurring payments',
        amount: inr(recurringNextPaise / 100.0),
        color: AppColors.blue,
        note: 'Detected auto-debits & subscriptions',
      ),
    if (cardsNextPaise > 0)
      NeedPlanRow(
        label: 'Credit card bills',
        amount: inr(cardsNextPaise / 100.0),
        color: AppColors.orange,
        note: 'Card statements due next month',
      ),
    if (otherBillsNextPaise > 0)
      NeedPlanRow(
        label: 'Bills & contributions',
        amount: inr(otherBillsNextPaise / 100.0),
        color: amber,
        note: 'Confirmed bills and planned contributions',
      ),
  ];
  final needPlanReceiveRows = <NeedPlanRow>[
    NeedPlanRow(
      label: 'Salary',
      amount: inr(salaryNextPaise / 100.0),
      color: AppColors.green,
      note: salaryDetected
          ? 'Your detected monthly income'
          : 'Add your income to complete this',
    ),
    if (lastYearExtraPaise > 0)
      NeedPlanRow(
        label: 'Extra income · last $nextMonthLabel',
        amount: inr(lastYearExtraPaise / 100.0),
        color: AppColors.lime,
        note: 'Bonus or extra credits seen last year',
      ),
  ];
  final needPlan = NeedPlan(
    monthLabel: nextMonthLabel,
    requiredRows: needPlanRequiredRows,
    receiveRows: needPlanReceiveRows,
    requiredTotalLabel: inr(requiredPaise / 100.0),
    receiveTotalLabel: inr(receivePaise / 100.0),
    gapLabel: needIsShort
        ? 'Gather before $nextMonthLabel'
        : "You're ahead for $nextMonthLabel",
    gapAmountLabel: inr(gapPaise.abs() / 100.0),
    isShort: needIsShort,
    salaryMissing: !salaryDetected,
  );

  // The headline "Need for <next month>" figure is exactly the required total
  // above, so tapping it and reading the plan explains the number precisely.
  final nextMonthNeedPaise = requiredPaise;
  final nextMonthNeedLabel = inr(nextMonthNeedPaise / 100.0);

  // Monthly spend trend for the Home summary: the last four completed months
  // (actual spend), this month so far, and next month's projected need. This
  // is the "current and next month" chart the user reads at a glance.
  final trendPoints = <({String label, int paise, String kind})>[];
  for (var back = 4; back >= 1; back--) {
    final m = DateTime(now.year, now.month - back);
    trendPoints.add((
      label: DateFormat('MMM').format(m),
      paise: _monthSpendPaise(history, m.year, m.month),
      kind: 'past',
    ));
  }
  trendPoints.add((
    label: DateFormat('MMM').format(now),
    paise: spentThisMonthPaise,
    kind: 'current',
  ));
  trendPoints.add((
    label: DateFormat('MMM').format(nextPlan.monthStart),
    paise: nextMonthNeedPaise,
    kind: 'next',
  ));
  final trendMax = trendPoints.fold<int>(1, (m, p) => math.max(m, p.paise));
  final spendTrendBars = [
    for (final pt in trendPoints)
      BarSpec(
        label: pt.label,
        tag: pt.paise > 0 ? _compactInr(pt.paise) : '',
        height: math.max(6, (pt.paise / trendMax * 60).round()).toDouble(),
        color: switch (pt.kind) {
          'current' => amber,
          'next' => teal,
          _ => barNeutral,
        },
      ),
  ];

  // ---- alerts: headline + dated forward earmarks ----------------------------
  final alerts = <AlertCard>[
    AlertCard(
      text: outlook.headline,
      bg: resultColor.withValues(alpha: 0.08),
      border: resultColor.withValues(alpha: isShort ? 0.30 : 0.25),
      isAlert: isShort,
      isPositive: !isShort,
      iconColor: isShort ? AppColors.pink : AppColors.green,
    ),
    for (final line in outlook.forwardEarmarks)
      AlertCard(
        text:
            '${inr(line.amountPaise / 100.0)} ${line.label} due in ${DateFormat('MMMM').format(line.date!)} — set it aside so it stays out of your spendable balance.',
        bg: amber.withValues(alpha: 0.08),
        border: amber.withValues(alpha: 0.25),
        isAlert: true,
        isPositive: false,
        iconColor: amber,
      ),
  ];

  final driverText = catList.isEmpty
      ? 'Nothing dated for $monthName yet — scan your messages or add bills to fill in the forecast.'
      : 'Driven by ${catList.take(3).map((c) => '${c.name} (${inr(c.amount)})').join(', ')}'
            '${catList.length > 3 ? ', plus ${catList.length - 3} more' : ''}.';

  // ---- investments (from the user's own configured plans) -------------------
  final mfEntry = s.mf.enabled
      ? [
          Investment(
            type: 'MF',
            institution: s.mf.frequency == 'monthly'
                ? 'Index Fund SIP'
                : 'Index Fund (lump sum)',
            principal: s.mf.amountValue,
            maturityValue: 0,
            rate: '~12% avg',
            maturity: s.mf.frequency == 'monthly'
                ? 'Ongoing SIP'
                : 'Planned ${s.mf.month}',
            status: 'Active',
          ),
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
      ),
  ];
  final allInvest = [...mfEntry, ...customInvest, ...s.manualInvestments];
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
      statusBg: soon
          ? amber.withValues(alpha: 0.15)
          : AppColors.green.withValues(alpha: 0.12),
    );
  }).toList();
  final investTotal = inr(allInvest.fold<double>(0, (a, b) => a + b.principal));

  // ---- anchor provenance line ("as of 1 Aug · 1234") ------------------------
  final anchor = outlook.anchor;
  final anchorAsOf = DateFormat('d MMM').format(anchor.asOf);
  final anchorLast4 = anchor.accountLast4;
  final anchorAsOfLabel = (anchorLast4 != null && anchorLast4.isNotEmpty)
      ? 'as of $anchorAsOf · $anchorLast4'
      : 'as of $anchorAsOf';

  // ---- expected-vs-actual for the target month, by forecast category --------
  // Expected = every dated outflow line; actual = the portion already paid
  // (reconciled against a real posting this month).
  final evaMap = <String, ({Color color, int expected, int actual})>{};
  for (final line in outlook.lines) {
    if (line.date == null) continue;
    if (_isForecastInflow(line.source)) continue;
    if (!_datedInTargetMonth(line, outlook.targetMonth)) continue;
    final (name, color) = _forecastCategory(line.source);
    final existing = evaMap[name];
    final paid = line.status == ForecastLineStatus.paid ? line.amountPaise : 0;
    evaMap[name] = (
      color: color,
      expected: (existing?.expected ?? 0) + line.amountPaise,
      actual: (existing?.actual ?? 0) + paid,
    );
  }
  final evaEntries = evaMap.entries.toList()
    ..sort((a, b) => b.value.expected.compareTo(a.value.expected));
  final evaMax = evaEntries.isEmpty
      ? 1
      : evaEntries
            .map((e) => math.max(e.value.expected, e.value.actual))
            .reduce(math.max);
  final expectedVsActual = evaEntries
      .map(
        (e) => CompareRow(
          name: e.key,
          leftAmount: inr(e.value.expected / 100.0),
          rightAmount: inr(e.value.actual / 100.0),
          leftPct: (e.value.expected / evaMax * 100).clamp(0, 100).toDouble(),
          rightPct: (e.value.actual / evaMax * 100).clamp(0, 100).toDouble(),
          color: e.value.color,
        ),
      )
      .toList();

  // ---- same-month-last-year-vs-now, per category (snapshot.yearOverYear) -----
  final yoyEntries =
      snapshot.yearOverYear.values
          .where((y) => y.currentPaise > 0 || y.lastYearPaise > 0)
          .toList()
        ..sort((a, b) => b.currentPaise.compareTo(a.currentPaise));
  final yoyMax = yoyEntries.isEmpty
      ? 1
      : yoyEntries
            .map((y) => math.max(y.currentPaise, y.lastYearPaise))
            .reduce(math.max);
  final yearOverYear = yoyEntries
      .map(
        (y) => CompareRow(
          name: _categoryLabel(y.categoryKey),
          leftAmount: inr(y.lastYearPaise / 100.0),
          rightAmount: inr(y.currentPaise / 100.0),
          leftPct: (y.lastYearPaise / yoyMax * 100).clamp(0, 100).toDouble(),
          rightPct: (y.currentPaise / yoyMax * 100).clamp(0, 100).toDouble(),
          color: AppColors.slate,
          deltaLabel:
              '${y.deltaPaise >= 0 ? '+' : '-'}${inr(y.deltaPaise.abs() / 100.0)}',
          deltaUp: y.deltaPaise >= 0,
        ),
      )
      .toList();

  return Insights(
    febRequired: explorer.planAt(1).committedOutflowPaise / 100.0,
    janRemaining: explorer.planAt(0).committedOutflowPaise / 100.0,
    heroLabel: 'Forecast · $monthName',
    heroAmount: inr(committed / 100.0),
    heroSubText: outlook.headline,
    heroSubColor: isShort
        ? AppColors.pink
        : (outlook.salaryMissing ? muted : AppColors.green),
    heroTrendBars: heroTrendBars,
    balanceCheckLabel: 'this month',
    balanceAvailable: inr((outlook.openingBalancePaise + expected) / 100.0),
    balanceRequired: inr(committed / 100.0),
    balanceResultLabel: isShort ? 'Projected shortfall' : 'Projected surplus',
    balanceResultColor: resultColor,
    balanceResultAmount:
        '${isShort ? '-' : '+'}${inr((isShort ? shortfall : surplus) / 100.0)}',
    categoriesTop: categoriesTop,
    categoriesFull: categoriesFull,
    chartBars: chartBars,
    yearForecast: yearForecast,
    yearTotalLabel: inr(yearTotal),
    peakMonthLabel: '${abbrevOf(peakIdx)} · ${inr(totals[peakIdx])}',
    driverAmount:
        '${isShort ? '-' : '+'}${inr((isShort ? shortfall : surplus) / 100.0)}',
    driverText: driverText,
    alerts: alerts,
    upcomingBills: upcomingBills,
    dateGroups: dateGroups,
    txCountLabel: '${snapshot.currentMonthTxns.length} this month',
    investments: investments,
    investTotal: investTotal,
    fdMaturityDate: '',
    fdMaturityValue: '',
    fdRenewTarget: '',
    fdTopUpAmount: '',
    fdMonthlyPlanAmount: '',
    fdTopUpMonths: 0,
    roundoffDoneText: '',
    breakdownMonthLabel: monthName,
    driverTitle: 'Why $monthName looks like this',
    forecastLines: outlook.lines,
    forwardEarmarks: outlook.forwardEarmarks,
    salaryCommitted: inr(committed / 100.0),
    salaryExpected: inr(expected / 100.0),
    salaryFree: inr(outlook.salary.freePaise / 100.0),
    forecastHeadline: outlook.headline,
    anchorProvisional: outlook.isProvisional,
    anchorConfirmLabel: outlook.anchorConfirmLabel,
    anchorAsOfLabel: anchorAsOfLabel,
    coverageLines: outlook.coverageLines,
    expectedVsActual: expectedVsActual,
    yearOverYear: yearOverYear,
    forecastExplorer: explorer,
    spentThisMonthLabel: inr(spentThisMonthPaise / 100.0),
    spentThisMonthCount: spendTxns.length,
    nextMonthNeedLabel: nextMonthNeedLabel,
    nextMonthLabel: nextMonthLabel,
    recentTx: recentTx,
    spendTrendBars: spendTrendBars,
    needPlan: needPlan,
  );
}

bool _isForecastInflow(ForecastEventSource source) =>
    source == ForecastEventSource.salary ||
    source == ForecastEventSource.otherIncome ||
    source == ForecastEventSource.refund ||
    source == ForecastEventSource.currentActual;

/// Whether a forecast event source is a genuine, dateable **bill** the user
/// should see under "Upcoming bills" — a confirmed bill, recurring auto-debit,
/// credit-card statement/payment, or planned contribution. Deliberately
/// excludes the seasonal/discretionary spending *estimate*, cash, transfers,
/// and every inflow, so the bills list only carries real obligations.
bool _isRealBill(ForecastEventSource source) => switch (source) {
  ForecastEventSource.gmailBill ||
  ForecastEventSource.recurring ||
  ForecastEventSource.configuredContribution ||
  ForecastEventSource.cardStatement ||
  ForecastEventSource.cardPayment ||
  ForecastEventSource.cardOutstanding ||
  ForecastEventSource.manual => true,
  _ => false,
};

/// Whether a credit-card forecast source (statement, payment, or outstanding).
bool _isCardSource(ForecastEventSource source) =>
    source == ForecastEventSource.cardStatement ||
    source == ForecastEventSource.cardPayment ||
    source == ForecastEventSource.cardOutstanding;

/// Whether a forecast line is a dated, still-outstanding real bill suitable for
/// the "Upcoming bills" list (excludes opening/anchor rows and already-paid
/// ones so only genuinely upcoming obligations remain).
bool _isUpcomingBillLine(ForecastLine line) =>
    line.date != null &&
    _isRealBill(line.source) &&
    line.status != ForecastLineStatus.alreadyInAnchor &&
    line.status != ForecastLineStatus.opening &&
    line.status != ForecastLineStatus.paid;

bool _datedInTargetMonth(ForecastLine line, DateTime targetMonth) {
  final d = line.date;
  return d != null &&
      d.year == targetMonth.year &&
      d.month == targetMonth.month;
}

(String, Color) _forecastCategory(ForecastEventSource source) =>
    switch (source) {
      ForecastEventSource.recurring => ('Recurring', AppColors.blue),
      ForecastEventSource.gmailBill => ('Bills', AppColors.amber),
      ForecastEventSource.configuredContribution => (
        'Investments',
        AppColors.violet,
      ),
      ForecastEventSource.cardStatement ||
      ForecastEventSource.cardPayment ||
      ForecastEventSource.cardOutstanding => ('Cards', AppColors.orange),
      ForecastEventSource.seasonal => ('Discretionary', AppColors.teal),
      ForecastEventSource.untrackedCash => ('Cash', AppColors.slate),
      ForecastEventSource.transfer => ('Transfers', AppColors.slate),
      _ => ('Other', AppColors.slate),
    };

/// A human label for a raw transaction category key (e.g. `food` → `Food`).
String _categoryLabel(String key) {
  if (key.isEmpty) return 'Other';
  return key[0].toUpperCase() + key.substring(1).replaceAll('_', ' ');
}

/// A stable avatar/accent colour per spending category key, so the activity
/// list reads at a glance (Finart-style coloured initials).
Color _categoryColor(String key) => switch (key) {
  'food' => AppColors.orange,
  'groceries' => AppColors.green,
  'shopping' => AppColors.violet,
  'transport' => AppColors.blue,
  'travel' => AppColors.teal,
  'entertainment' => AppColors.pink,
  'subscriptions' => AppColors.pink,
  'utilities' => AppColors.amber,
  'housing' => AppColors.amber,
  'health' => AppColors.green,
  'insurance' => AppColors.blue,
  'investments' => AppColors.violet,
  'cash' => AppColors.slate,
  'transfers' => AppColors.slate,
  'income' => AppColors.green,
  'refund' => AppColors.green,
  _ => AppColors.slate,
};

/// The user's typical monthly outflow, averaged over the completed calendar
/// months in the trailing window (default 3) that actually have activity. Real
/// debits only, excluding self/account transfers. Returns 0 with no history.
int _typicalMonthlySpendPaise(
  List<ParsedTxn> history,
  DateTime now, {
  int months = 3,
  Set<String> excludeOwnerKeys = const {},
}) {
  final byMonth = <String, int>{};
  for (var back = 1; back <= months; back++) {
    final m = DateTime(now.year, now.month - back);
    byMonth['${m.year}-${m.month.toString().padLeft(2, '0')}'] = 0;
  }
  for (final t in history) {
    if (!_isConsumptionSpend(t)) continue;
    if (t.ownerKey != null && excludeOwnerKeys.contains(t.ownerKey)) continue;
    final key =
        '${t.txnDate.year}-${t.txnDate.month.toString().padLeft(2, '0')}';
    if (byMonth.containsKey(key)) {
      byMonth[key] = byMonth[key]! + t.amountPaise;
    }
  }
  final active = byMonth.values.where((v) => v > 0).toList();
  if (active.isEmpty) return 0;
  return active.reduce((a, b) => a + b) ~/ active.length;
}

/// Total real spend (debits, excluding transfers) in one calendar month.
/// Used to surface last-year same-month festival spend in the next-month need.
/// [excludeOwnerKeys] drops recurring-commitment owners so the everyday figure
/// does not double-count amounts listed separately as recurring payments.
int _monthSpendPaise(
  List<ParsedTxn> history,
  int year,
  int month, {
  Set<String> excludeOwnerKeys = const {},
}) {
  var sum = 0;
  for (final t in history) {
    if (!_isConsumptionSpend(t)) continue;
    if (t.ownerKey != null && excludeOwnerKeys.contains(t.ownerKey)) continue;
    if (t.txnDate.year == year && t.txnDate.month == month) {
      sum += t.amountPaise;
    }
  }
  return sum;
}

/// Total genuine **income** credited in one calendar month — bank credits that
/// are incoming money (salary, bonus, interest), excluding refunds/reversals,
/// transfers between the user's own accounts, wallet top-ups, and card credits.
/// Surfaces last-year same-month extra income on the receive side of the plan.
int _monthIncomePaise(List<ParsedTxn> history, int year, int month) {
  var sum = 0;
  for (final t in history) {
    if (t.txnDate.year != year || t.txnDate.month != month) continue;
    if (!_isIncomeCredit(t)) continue;
    sum += t.amountPaise;
  }
  return sum;
}

bool _isIncomeCredit(ParsedTxn t) {
  if (t.direction != TransactionDirection.credit) return false;
  if (t.type == TxnType.transfer) return false;
  if (t.payeeType == PayeeType.selfTransfer) return false;
  if (t.payeeType == PayeeType.wallet) return false;
  if (t.instrument == PaymentInstrument.card) return false;
  if (t.categoryKey.toLowerCase().contains('refund')) return false;
  return !_matchesAny(t.rawBodyRedacted.toLowerCase(), _kRefundMarkers);
}

/// Reversal/refund/cashback signals — these offset a prior debit rather than
/// being new income, so they are excluded from the receive side.
const _kRefundMarkers = ['refund', 'reversed', 'reversal', 'cashback'];

/// Compact Indian-format rupee label for tight chart captions (e.g. `₹1.9L`,
/// `₹12k`, `₹850`).
String _compactInr(int paise) {
  final rupees = paise / 100.0;
  if (rupees >= 10000000) {
    return '₹${(rupees / 10000000).toStringAsFixed(1)}Cr';
  }
  if (rupees >= 100000) {
    return '₹${(rupees / 100000).toStringAsFixed(1)}L';
  }
  if (rupees >= 1000) {
    return '₹${(rupees / 1000).round()}k';
  }
  return '₹${rupees.round()}';
}

/// Whether a stored transaction is genuine **consumption** that left the user's
/// bank this period. Leading trackers (e.g. FinArt) separate spend from money
/// that is merely *moved* or *reserved*, and so do we — excluding:
///   • cash withdrawals (ATM) — cash on hand, not yet spent;
///   • investments / SIP auto-debits — savings, not consumption;
///   • credit-card purchases — not a bank cash outflow (the later bill payment
///     is the single bank event, per the SMS-layer design §11);
///   • future auto-pay mandate registrations and bill-due notices
///     ("will be debited", "is due for payment") — the money has not left yet;
///   • transfers and self-transfers between the user's own accounts.
///
/// Detection is re-derived from the redacted SMS body at read time, so it
/// corrects already-stored rows without needing a rescan (some banks mis-tag an
/// ATM cash-out as a POS purchase because the body names the debit card, so the
/// raw body is the reliable signal).
bool _isConsumptionSpend(ParsedTxn t) {
  if (t.direction != TransactionDirection.debit) return false;
  if (t.type == TxnType.transfer || t.type == TxnType.atm) return false;
  if (t.payeeType == PayeeType.selfTransfer) return false;
  if (t.instrument == PaymentInstrument.card) return false;
  if (t.isFutureDebitNotice) return false;
  final body = t.rawBodyRedacted.toLowerCase();
  return !_matchesAny(body, _kCashWithdrawalMarkers) &&
      !_matchesAny(body, _kInvestmentMarkers) &&
      !_matchesAny(body, _kCreditCardPurchaseMarkers);
}

bool _matchesAny(String body, List<String> markers) =>
    markers.any(body.contains);

/// ATM / cash-out signals. Some banks mis-tag these as POS because the body
/// mentions the debit card, so the raw body — not the parsed type — is reliable.
const _kCashWithdrawalMarkers = ['withdrawn', 'cash withdrawal', 'atm wdl'];

/// Recurring investment / SIP auto-debit originators (Indian broking houses and
/// mutual-fund clearing corporations). These are savings, not spend.
const _kInvestmentMarkers = [
  'groww',
  'indian clearing corp',
  'iccl',
  'zerodha',
  'mutual fund',
  'invest tech',
  'nse clearing',
  'bse star',
  'kfintech',
];

/// Credit-card purchase alerts, identified by the reported available *limit*
/// (a bank debit-card purchase reports the available *balance* instead).
const _kCreditCardPurchaseMarkers = [
  'avl lmt',
  'available limit',
  'available credit',
  'credit limit',
];
