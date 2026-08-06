import 'package:flutter/material.dart';

import '../services/forecast_explorer.dart';
import 'app_state.dart';
import 'forecast_models.dart';
import 'real_insights.dart';
import 'sms_analysis_snapshot.dart';

class BarSpec {
  const BarSpec({
    required this.label,
    required this.height,
    required this.color,
    this.tag = '',
  });
  final String label;
  final double height;
  final Color color;
  final String tag;
}

class CategoryRow {
  const CategoryRow({
    required this.name,
    required this.color,
    required this.amount,
    required this.pct,
  });
  final String name;
  final Color color;
  final String amount;
  final double pct;
}

class BillRow {
  const BillRow({
    required this.name,
    required this.due,
    required this.amount,
    required this.initial,
    required this.color,
    required this.bgColor,
  });
  final String name;
  final String due;
  final String amount;
  final String initial;
  final Color color;
  final Color bgColor;
}

class TxRow {
  const TxRow({
    required this.name,
    required this.category,
    required this.amount,
    required this.initial,
    required this.color,
    required this.bgColor,
    this.categoryKey = '',
    this.date = '',
    this.amountColor,
    this.isCredit = false,
    this.subtitle = '',
    this.isCardSettlement = false,
  });
  final String name;
  final String category;
  final String amount;
  final String initial;
  final Color color;
  final Color bgColor;

  /// Stable category key for filtering (e.g. `food`). Empty when unclassified.
  final String categoryKey;

  /// Optional per-row date label (e.g. `12 Jul`) used by flat lists such as the
  /// Home recent-transactions strip. Empty when the list is grouped by day.
  final String date;

  /// Optional amount colour (green for credits, primary for debits).
  final Color? amountColor;
  final bool isCredit;

  /// A second line under [category], explaining why a row the user can see is
  /// not in the total beside it. Empty for an ordinary row.
  final String subtitle;

  /// Whether this row settles a credit-card bill. The money left the bank, so
  /// the row stays on screen; it is not consumption, so it is in no spend
  /// total. Both facts have to be visible at once or the total looks wrong.
  final bool isCardSettlement;
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
  const AlertCard({
    required this.text,
    required this.bg,
    required this.border,
    required this.isPositive,
    required this.isAlert,
    required this.iconColor,
  });
  final String text;
  final Color bg;
  final Color border;
  final bool isPositive;
  final bool isAlert;
  final Color iconColor;
}

class CompareRow {
  const CompareRow({
    required this.name,
    required this.leftAmount,
    required this.rightAmount,
    required this.leftPct,
    required this.rightPct,
    required this.color,
    this.deltaLabel = '',
    this.deltaUp = false,
  });
  final String name;
  final String leftAmount;
  final String rightAmount;
  final double leftPct;
  final double rightPct;
  final Color color;
  final String deltaLabel;
  final bool deltaUp;
}

/// A single line in the [NeedPlan] — a labelled money amount with an optional
/// caption explaining where it comes from and an accent colour for its dot.
class NeedPlanRow {
  const NeedPlanRow({
    required this.label,
    required this.amount,
    required this.color,
    this.note = '',
  });

  final String label;
  final String amount;
  final Color color;

  /// Short caption explaining the source of the amount (e.g. `Trailing 3-month
  /// average`). Empty when no caption is needed.
  final String note;
}

/// An explainable breakdown of *how much the user needs to have* for a month
/// versus *how much they will receive*, and the resulting gap.
///
/// The required rows are non-overlapping (everyday spend excludes recurring and
/// card outflows, which are listed separately) so their total is honest. The
/// receive rows sum salary plus any extra income seen the same month last year.
class NeedPlan {
  const NeedPlan({
    required this.monthLabel,
    required this.requiredRows,
    required this.receiveRows,
    required this.requiredTotalLabel,
    required this.receiveTotalLabel,
    required this.gapLabel,
    required this.gapAmountLabel,
    required this.isShort,
    this.salaryMissing = false,
  });

  /// Full name of the month this plan is for (e.g. `August`).
  final String monthLabel;

  /// Components of what the user needs (everyday, seasonal, cards, recurrings).
  final List<NeedPlanRow> requiredRows;

  /// Components of what the user will receive (salary, last-year extra income).
  final List<NeedPlanRow> receiveRows;

  final String requiredTotalLabel;
  final String receiveTotalLabel;

  /// e.g. `Gather more` when short, or `You're ahead` when a surplus.
  final String gapLabel;

  /// The formatted gap amount (always non-negative).
  final String gapAmountLabel;

  /// Whether the receive side falls short of the required side.
  final bool isShort;

  /// Whether the salary could not be detected, so the receive side is partial.
  final bool salaryMissing;
}

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
    this.forecastLines = const [],
    this.forwardEarmarks = const [],
    this.coverageLines = const [],
    this.salaryCommitted = '',
    this.salaryExpected = '',
    this.salaryFree = '',
    this.forecastHeadline = '',
    this.anchorProvisional = false,
    this.anchorAsOfLabel = '',
    this.expectedVsActual = const [],
    this.yearOverYear = const [],
    this.forecastExplorer,
    this.spentThisMonthLabel = '',
    this.spentThisMonthCount = 0,
    this.nextMonthNeedLabel = '',
    this.nextMonthLabel = '',
    this.recentTx = const [],
    this.spendTrendBars = const [],
    this.needPlan,
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
  final String breakdownMonthLabel;
  final String driverTitle;
  final List<ForecastLine> forecastLines;
  final List<ForecastLine> forwardEarmarks;
  final List<ForecastCoverageLine> coverageLines;
  final String salaryCommitted;
  final String salaryExpected;
  final String salaryFree;
  final String forecastHeadline;
  final bool anchorProvisional;
  final String anchorAsOfLabel;
  final List<CompareRow> expectedVsActual;
  final List<CompareRow> yearOverYear;
  final ForecastExplorer? forecastExplorer;

  /// Total real spend recorded from SMS in the current month (formatted).
  final String spentThisMonthLabel;

  /// Number of current-month transactions behind [spentThisMonthLabel].
  final int spentThisMonthCount;

  /// Projected amount the user needs for next month (formatted).
  final String nextMonthNeedLabel;

  /// Full name of next month (e.g. `August`).
  final String nextMonthLabel;

  /// Most recent transactions with readable names for the Home strip.
  final List<TxRow> recentTx;

  /// Monthly spend trend for the Home summary: recent completed months, this
  /// month so far, and next month's projected need (last bar). Each bar's
  /// [BarSpec.tag] carries a compact rupee label.
  final List<BarSpec> spendTrendBars;

  /// An explainable required-vs-receive breakdown for next month, backing the
  /// tappable "Need for `<Month>`" figure. Null on the manual/sample path.
  final NeedPlan? needPlan;

  static bool isLiveMode(AppState state, {bool hasSmsData = false}) =>
      state.hasFinancialData || state.gmailEmail.isNotEmpty || hasSmsData;

  static Insights compute(
    AppState state, {
    bool hasSmsData = false,
    SmsAnalysisSnapshot? snapshot,
    DateTime? now,
  }) => computeRealInsights(state, snapshot: snapshot, nowOverride: now);
}
