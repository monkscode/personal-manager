import 'dart:math' as math;

import '../core/clamped_date.dart';
import '../data/models.dart';
import '../data/sms_models.dart';

/// Cadence of a locked recurring commitment (spec §3 gap classification).
enum RecurringCadence { monthly, quarterly, halfYearly, annual }

/// Minimum occurrences to lock a commitment from history alone (spec §3).
const int kRecurringMinOccurrences = 3;

/// Minimum occurrences to lock when reinforced by a matching configured plan
/// (spec §3 "Reinforced by user-configured contributions").
const int kRecurringConfiguredMatchMinOccurrences = 2;

/// Day-of-month variance window (± days) for a consistent cadence (spec §3).
const int kRecurringDayOfMonthVarianceDays = 4;

/// Amount jitter tolerance as a fraction of the group median (spec §3).
const double kRecurringAmountJitterRatio = 0.10;

/// Amount jitter floor in paise (₹50) — the larger of ratio/floor applies.
const int kRecurringAmountJitterFloorPaise = 5000;

/// Base confidence for a cleanly locked (≥3 occurrence) commitment.
const double kRecurringBaseConfidence = 0.7;

/// Confidence added when a locked group matches a configured contribution.
const double kRecurringConfiguredMatchConfidenceBoost = 0.2;

/// Confidence for a 2-occurrence group locked only via a configured match.
const double kRecurringConfiguredTwoOccurrenceConfidence = 0.6;

/// Inclusive inter-occurrence gap windows (in days) per cadence.
const Map<RecurringCadence, (int, int)> kRecurringCadenceGapDays = {
  RecurringCadence.monthly: (28, 33),
  RecurringCadence.quarterly: (88, 95),
  RecurringCadence.halfYearly: (178, 190),
  RecurringCadence.annual: (360, 370),
};

/// A locked recurring outflow commitment.
class RecurringCommitment {
  const RecurringCommitment({
    required this.merchantNorm,
    required this.amountPaise,
    required this.cadence,
    required this.categoryKey,
    required this.nextExpected,
    required this.confidence,
    required this.occurrences,
    required this.matchedConfiguredPlan,
    this.configuredPlanKey,
  });

  final String merchantNorm;
  final int amountPaise;
  final RecurringCadence cadence;
  final String categoryKey;
  final DateTime nextExpected;
  final double confidence;
  final int occurrences;
  final bool matchedConfiguredPlan;

  /// Owner tag identifying the configured plan this commitment matched, so a
  /// configured-contribution owner (F1) is not double-counted (D8 dedup).
  final String? configuredPlanKey;
}

/// Kind of unlocked review candidate emitted for a repeating debit group.
enum ReviewCandidateKind { possibleRecurringDebit, irregularRepeatingDebit }

/// A repeating debit group that did not lock but is surfaced for review so its
/// rupees still land in a coverage bucket (spec §3, no silent exclusion).
class ReviewCandidate {
  const ReviewCandidate({
    required this.merchantNorm,
    required this.categoryKey,
    required this.minAmountPaise,
    required this.maxAmountPaise,
    required this.latestDates,
    required this.kind,
    required this.occurrences,
  });

  final String merchantNorm;
  final String categoryKey;
  final int minAmountPaise;
  final int maxAmountPaise;
  final List<DateTime> latestDates;
  final ReviewCandidateKind kind;
  final int occurrences;
}

/// Detects recurring outflow commitments (SIPs, subscriptions, EMIs) from
/// parsed debit history using the fully specified spec §3 algorithm, reinforced
/// by user-configured contribution plans.
class RecurringDebitDetector {
  const RecurringDebitDetector();

  /// Locked commitments derived from [history].
  List<RecurringCommitment> detect(
    List<ParsedTxn> history, {
    required List<ContribPlan> configuredPlans,
    required DateTime now,
  }) {
    final commitments = <RecurringCommitment>[];
    for (final group in _groups(history).values) {
      final analysis = _analyze(group, configuredPlans, now);
      if (analysis.commitment != null) commitments.add(analysis.commitment!);
    }
    return commitments;
  }

  /// Unlocked repeating groups surfaced as review candidates.
  List<ReviewCandidate> possibleRecurring(
    List<ParsedTxn> history, {
    required List<ContribPlan> configuredPlans,
    required DateTime now,
  }) {
    final candidates = <ReviewCandidate>[];
    for (final group in _groups(history).values) {
      final analysis = _analyze(group, configuredPlans, now);
      if (analysis.candidate != null) candidates.add(analysis.candidate!);
    }
    return candidates;
  }

  Map<String, List<ParsedTxn>> _groups(List<ParsedTxn> history) {
    final groups = <String, List<ParsedTxn>>{};
    for (final txn in history) {
      if (txn.direction != TransactionDirection.debit) continue;
      if (txn.type == TxnType.atm) continue;
      groups.putIfAbsent(_ownerNorm(txn), () => []).add(txn);
    }
    return groups;
  }

  _GroupAnalysis _analyze(
    List<ParsedTxn> group,
    List<ContribPlan> plans,
    DateTime now,
  ) {
    final sorted = [...group]..sort((a, b) => a.txnDate.compareTo(b.txnDate));
    final occurrences = sorted.length;
    if (occurrences < 2) return const _GroupAnalysis();

    final merchantNorm = _ownerNorm(sorted.first);
    final categoryKey = _dominantCategory(sorted);
    final amounts = sorted.map((t) => t.amountPaise).toList();
    final minAmount = amounts.reduce(math.min);
    final maxAmount = amounts.reduce(math.max);
    final median = _median(amounts);
    final tolerance = math.max(
      (median * kRecurringAmountJitterRatio).round(),
      kRecurringAmountJitterFloorPaise,
    );
    final amountConsistent =
        amounts.every((a) => (a - median).abs() <= tolerance);

    final cadence = _cadence(sorted);
    final daySpread = _circularSpread(
      sorted.map((t) => t.txnDate.day).toList(),
      31,
    );
    final dayOk = daySpread <= kRecurringDayOfMonthVarianceDays;

    final matchedPlan = cadence == null
        ? null
        : _matchPlan(plans, median, cadence, tolerance);

    final structureOk = cadence != null && amountConsistent && dayOk;
    final enoughOccurrences =
        occurrences >= kRecurringMinOccurrences ||
        (matchedPlan != null &&
            occurrences >= kRecurringConfiguredMatchMinOccurrences);

    if (structureOk && enoughOccurrences) {
      final double confidence;
      if (occurrences >= kRecurringMinOccurrences) {
        confidence = matchedPlan != null
            ? math.min(
                1.0,
                kRecurringBaseConfidence +
                    kRecurringConfiguredMatchConfidenceBoost,
              )
            : kRecurringBaseConfidence;
      } else {
        confidence = kRecurringConfiguredTwoOccurrenceConfidence;
      }

      return _GroupAnalysis(
        commitment: RecurringCommitment(
          merchantNorm: merchantNorm,
          amountPaise: median,
          cadence: cadence,
          categoryKey: categoryKey,
          nextExpected: _nextExpected(sorted.last.txnDate, cadence, now),
          confidence: confidence,
          occurrences: occurrences,
          matchedConfiguredPlan: matchedPlan != null,
          configuredPlanKey: matchedPlan == null
              ? null
              : _planKey(matchedPlan, median),
        ),
      );
    }

    return _GroupAnalysis(
      candidate: ReviewCandidate(
        merchantNorm: merchantNorm,
        categoryKey: categoryKey,
        minAmountPaise: minAmount,
        maxAmountPaise: maxAmount,
        latestDates: sorted.reversed
            .take(3)
            .map((t) => t.txnDate)
            .toList(growable: false),
        kind: occurrences >= kRecurringMinOccurrences
            ? ReviewCandidateKind.irregularRepeatingDebit
            : ReviewCandidateKind.possibleRecurringDebit,
        occurrences: occurrences,
      ),
    );
  }

  /// The single cadence all consecutive gaps agree on, or null when the gaps
  /// are irregular or classify to more than one cadence.
  RecurringCadence? _cadence(List<ParsedTxn> sorted) {
    RecurringCadence? cadence;
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i].txnDate.difference(sorted[i - 1].txnDate).inDays;
      final classified = _classifyGap(gap);
      if (classified == null) return null;
      if (cadence == null) {
        cadence = classified;
      } else if (cadence != classified) {
        return null;
      }
    }
    return cadence;
  }

  RecurringCadence? _classifyGap(int days) {
    for (final entry in kRecurringCadenceGapDays.entries) {
      if (days >= entry.value.$1 && days <= entry.value.$2) return entry.key;
    }
    return null;
  }

  ContribPlan? _matchPlan(
    List<ContribPlan> plans,
    int medianPaise,
    RecurringCadence cadence,
    int tolerance,
  ) {
    for (final plan in plans) {
      if (!plan.enabled) continue;
      final planPaise = (plan.amountValue * 100).round();
      if ((planPaise - medianPaise).abs() > tolerance) continue;
      final planCadence = plan.frequency == 'monthly'
          ? RecurringCadence.monthly
          : RecurringCadence.annual;
      if (planCadence == cadence) return plan;
    }
    return null;
  }

  String _planKey(ContribPlan plan, int medianPaise) =>
      'configured:${plan.frequency}:$medianPaise:${plan.month}';

  /// The next occurrence at or after [now]. Advancing one period from the last
  /// *observed* payment left a live commitment dated in the past — history
  /// ending in April with `now` in July produced 10 May, which the engine filed
  /// as a `futureEarmark` and excluded from the ledger entirely.
  DateTime _nextExpected(
    DateTime last,
    RecurringCadence cadence,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    var periods = 1;
    var next = _addCadence(last, cadence, periods);
    // Each step is measured from the original day, not from the clamped result,
    // so a month-end cadence does not walk 31 Jan → 28 Feb → 28 Mar.
    while (next.isBefore(today)) {
      periods++;
      next = _addCadence(last, cadence, periods);
    }
    return next;
  }

  DateTime _addCadence(
    DateTime last,
    RecurringCadence cadence, [
    int periods = 1,
  ]) {
    final months = switch (cadence) {
      RecurringCadence.monthly => 1,
      RecurringCadence.quarterly => 3,
      RecurringCadence.halfYearly => 6,
      RecurringCadence.annual => 12,
    };
    // Clamped so a month-end cadence advances to the next month's last day
    // (31 Jan + 1 month = 28 Feb) instead of overflowing past it and skipping
    // that month entirely.
    return clampedDate(last.year, last.month + months * periods, last.day);
  }

  String _ownerNorm(ParsedTxn txn) {
    final raw = txn.merchant ?? txn.upiVpaNorm ?? txn.sender;
    return raw.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  String _dominantCategory(List<ParsedTxn> txns) {
    final counts = <String, int>{};
    for (final txn in txns) {
      counts[txn.categoryKey] = (counts[txn.categoryKey] ?? 0) + 1;
    }
    return counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }

  int _median(List<int> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  /// Smallest arc (in day units) covering all day-of-month values on a circle
  /// of [modulus] days — handles month-end wrap (e.g. 30 and 2).
  int _circularSpread(List<int> values, int modulus) {
    final sorted = [...values]..sort();
    if (sorted.length <= 1) return 0;
    var maxGap = modulus - (sorted.last - sorted.first);
    for (var i = 1; i < sorted.length; i++) {
      final gap = sorted[i] - sorted[i - 1];
      if (gap > maxGap) maxGap = gap;
    }
    return modulus - maxGap;
  }
}

class _GroupAnalysis {
  const _GroupAnalysis({this.commitment, this.candidate});

  final RecurringCommitment? commitment;
  final ReviewCandidate? candidate;
}
