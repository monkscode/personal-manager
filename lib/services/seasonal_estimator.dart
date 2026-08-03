import '../data/sms_models.dart';

/// Weight on the same-month median (across prior years) in the seasonal blend
/// (D3 spec default).
const double kSeasonalSameMonthWeight = 0.6;

/// Weight on the trailing-N average in the seasonal blend (D3 spec default).
const double kSeasonalTrailingWeight = 0.4;

/// Number of trailing calendar months averaged (D3 spec default, N=3).
const int kSeasonalTrailingN = 3;

/// Below this many distinct months of category history the estimate falls back
/// to recent-average-only with degraded confidence.
const int kSeasonalThinHistoryMonths = 6;

/// Minimum distinct months before winsorization of trailing one-offs applies.
const int kSeasonalWinsorizeMinPoints = 5;

/// Upper percentile at which trailing one-offs are capped (winsorization).
const double kSeasonalWinsorizePercentile = 0.90;

/// Confidence when the same-month median is backed by ≥2 prior years.
const double kSeasonalConfidenceSeasonal = 0.8;

/// Confidence when the same-month median rests on a single prior year.
const double kSeasonalConfidenceSingleYear = 0.6;

/// Confidence when there is no same-month signal but history is not thin.
const double kSeasonalConfidenceRecentOnly = 0.45;

/// Confidence when history is thin (recent-average-only).
const double kSeasonalConfidenceThin = 0.3;

/// Per-category seasonal estimate for a target month.
class CategorySeasonalEstimate {
  const CategorySeasonalEstimate({
    required this.categoryKey,
    required this.amountPaise,
    required this.confidence,
  });

  final String categoryKey;
  final int amountPaise;
  final double confidence;
}

/// Seasonal discretionary-spend estimate for a target month, keyed by category.
class SeasonalEstimate {
  const SeasonalEstimate({required this.targetMonth, required this.byCategory});

  final int targetMonth;
  final Map<String, CategorySeasonalEstimate> byCategory;

  int get totalAmountPaise =>
      byCategory.values.fold(0, (sum, e) => sum + e.amountPaise);
}

/// Estimates seasonal discretionary cash spend per category for a target month
/// (spec §3). Excludes transfers, ATM, card-owned, and any owner-owned rupee
/// (one-owner). Blends the same-month median across prior years with a
/// winsorized trailing-N average; degrades to recent-average-only when history
/// is thin. Deterministic via the injected [now].
class SeasonalEstimator {
  const SeasonalEstimator();

  SeasonalEstimate estimate({
    required int targetMonth1to12,
    required List<ParsedTxn> discretionaryHistory,
    required Set<String> ownedOwnerKeys,
    required DateTime now,
  }) {
    final byCategory = <String, List<ParsedTxn>>{};
    for (final txn in discretionaryHistory) {
      if (txn.type == TxnType.transfer || txn.type == TxnType.atm) continue;
      if (txn.instrument == PaymentInstrument.card) continue;
      // A bank *announcement* of a future debit is not spend. Rows written
      // before TASK-32 stored one beside the real debit, so the same rupee
      // entered the trailing average twice.
      if (txn.isFutureDebitNotice) continue;
      final ownerKey = txn.ownerKey;
      if (ownerKey != null && ownedOwnerKeys.contains(ownerKey)) continue;
      byCategory.putIfAbsent(txn.categoryKey, () => []).add(txn);
    }

    final trailingPeriods = _trailingPeriods(now, kSeasonalTrailingN);
    final estimates = <String, CategorySeasonalEstimate>{};

    for (final entry in byCategory.entries) {
      final monthlyNets = _monthlyNets(entry.value);
      if (monthlyNets.isEmpty) continue;

      final allNets = monthlyNets.values.toList();
      final distinctMonths = monthlyNets.length;

      final trailingValues = [
        for (final period in trailingPeriods) monthlyNets[period] ?? 0,
      ];
      final trailingAvg = distinctMonths >= kSeasonalWinsorizeMinPoints
          ? _mean(_winsorizeUpper(trailingValues, allNets))
          : _mean(trailingValues.map((v) => v.toDouble()).toList());

      final targetYear = _targetYear(now, targetMonth1to12);
      final sameMonthValues = [
        for (final period in monthlyNets.keys)
          if (_isPriorYearTargetMonth(period, targetMonth1to12, targetYear))
            monthlyNets[period]!,
      ];

      final double amount;
      final double confidence;
      if (distinctMonths < kSeasonalThinHistoryMonths) {
        amount = trailingAvg;
        confidence = kSeasonalConfidenceThin;
      } else if (sameMonthValues.isNotEmpty) {
        // Median is inherently robust to a single anomalous prior year.
        final sameMonth = _median(sameMonthValues);
        amount = kSeasonalSameMonthWeight * sameMonth +
            kSeasonalTrailingWeight * trailingAvg;
        confidence = sameMonthValues.length >= 2
            ? kSeasonalConfidenceSeasonal
            : kSeasonalConfidenceSingleYear;
      } else {
        amount = trailingAvg;
        confidence = kSeasonalConfidenceRecentOnly;
      }

      estimates[entry.key] = CategorySeasonalEstimate(
        categoryKey: entry.key,
        amountPaise: amount.round(),
        confidence: confidence,
      );
    }

    return SeasonalEstimate(
      targetMonth: targetMonth1to12,
      byCategory: estimates,
    );
  }

  /// Net spend per `yyyy-mm` for a category: debits add, refund/reversal credits
  /// subtract (§11.10), clamped at zero.
  Map<String, int> _monthlyNets(List<ParsedTxn> txns) {
    final nets = <String, int>{};
    for (final txn in txns) {
      final delta = txn.direction == TransactionDirection.debit
          ? txn.amountPaise
          : -txn.amountPaise;
      nets[txn.txnMonth] = (nets[txn.txnMonth] ?? 0) + delta;
    }
    return {
      for (final entry in nets.entries) entry.key: entry.value < 0 ? 0 : entry.value,
    };
  }

  List<String> _trailingPeriods(DateTime now, int n) {
    final periods = <String>[];
    var year = now.year;
    var month = now.month;
    for (var i = 0; i < n; i++) {
      month--;
      if (month == 0) {
        month = 12;
        year--;
      }
      periods.add(
        '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}',
      );
    }
    return periods;
  }

  /// The calendar year the forecast means when it asks for [targetMonth1to12]:
  /// the next occurrence of that month at or after [now]'s month. A forecast
  /// never estimates a month that has already passed, so December asking for
  /// January means *next* January.
  int _targetYear(DateTime now, int targetMonth1to12) =>
      targetMonth1to12 >= now.month ? now.year : now.year + 1;

  /// Whether [period] is the target month in a year strictly before the one
  /// being forecast.
  ///
  /// This compares against the **target** year, not `now.year`. Comparing
  /// against `now.year` was harmless while the only caller asked for
  /// `now.month`, but it meant forecasting January 2027 from December 2026
  /// discarded January 2026 — the single most relevant observation — and
  /// downgraded the result from [kSeasonalConfidenceSeasonal] to
  /// [kSeasonalConfidenceSingleYear] (TASK-21). The target month's own partial
  /// data is still excluded, because its year is never strictly less than
  /// itself.
  bool _isPriorYearTargetMonth(String period, int targetMonth, int targetYear) {
    final parts = period.split('-');
    final year = int.parse(parts[0]);
    final month = int.parse(parts[1]);
    return month == targetMonth && year < targetYear;
  }

  /// Caps trailing one-offs at the [reference] distribution's upper percentile
  /// so a single blow-out month cannot dominate the trailing mean, while a
  /// genuine sustained recent increase (near the top of the distribution) is
  /// left essentially untouched.
  List<double> _winsorizeUpper(List<int> values, List<int> reference) {
    if (values.isEmpty) return const [];
    final cap = _percentile(reference, kSeasonalWinsorizePercentile);
    return [
      for (final v in values) v > cap ? cap : v.toDouble(),
    ];
  }

  double _percentile(List<int> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    if (sorted.length == 1) return sorted.first.toDouble();
    final rank = p * (sorted.length - 1);
    final lo = rank.floor();
    final hi = rank.ceil();
    if (lo == hi) return sorted[lo].toDouble();
    return sorted[lo] + (rank - lo) * (sorted[hi] - sorted[lo]);
  }

  double _median(List<num> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid].toDouble()
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  double _mean(List<double> values) =>
      values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
}
