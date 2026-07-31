import '../core/money.dart';
import '../data/sms_models.dart';

/// Confidence tier of a detected salary profile (spec §7).
enum SalaryConfidence {
  detectedStable,
  detectedVariable,
  configuredFallback,
  insufficientData,
  unknown,
}

/// Minimum clean monthly salary credits required to detect a salary (cold-start
/// guard, spec §7).
const int kSalaryMinCleanCredits = 3;

/// Sanity floor (in paise) below which a recurring credit is never treated as
/// salary — excludes micro-refunds; P2P/self-transfer is excluded separately by
/// payee type.
const int kSalaryMinMonthlyPaise = 100000;

/// Percentile used as the conservative floor for a variable salary (D4).
const double kVariableSalaryFloorPercentile = 0.20;

/// Upper percentile describing the top of a variable salary range.
const double kVariableSalaryUpperPercentile = 0.80;

/// A monthly credit within ±this ratio of the cluster median counts as a
/// stable salary; wider spread is treated as variable.
const double kSalaryStableToleranceRatio = 0.10;

/// A monthly credit above this multiple of the median is a bonus/arrears outlier.
const double kSalaryBonusMultiplier = 1.5;

/// A monthly credit below this multiple of the median is a low outlier.
const double kSalaryLowOutlierMultiplier = 0.5;

/// Trailing window (days) over which primary-account credit volume is compared
/// (decision D1).
const int kPrimaryAccountLookbackDays = 90;

/// A detected (or configured) salary profile.
class SalaryProfile {
  const SalaryProfile({
    required this.confidence,
    this.basePaise,
    this.expectedDay,
    this.expectedDayWindowDays = 0,
    this.effectiveMonthSatisfied = false,
    this.rangeLowPaise,
    this.rangeHighPaise,
  });

  final SalaryConfidence confidence;

  /// Conservative base for planning: stable → cluster median; variable → p20
  /// floor; configured → parsed configured amount; null when undetected.
  final int? basePaise;

  /// Observed day-of-month the salary posts, or null when undetected.
  final int? expectedDay;

  /// Observed drift around [expectedDay]; the pessimistic (latest) edge is used
  /// for minimum-balance planning.
  final int expectedDayWindowDays;

  /// Whether the current calendar month's salary has already posted (so the
  /// forecast must not re-add it across the anchor).
  final bool effectiveMonthSatisfied;

  final int? rangeLowPaise;
  final int? rangeHighPaise;
}

/// Kind of non-salary income candidate.
enum IncomeCandidateKind { recurringOtherIncome, oneOffCredit }

/// A non-salary credit stream surfaced for user confirmation (spec §7): P2P,
/// self-transfer, and other income are never auto-promoted.
class IncomeCandidate {
  const IncomeCandidate({
    required this.label,
    required this.amountPaise,
    required this.occurrences,
    required this.needsConfirmation,
    required this.kind,
  });

  final String label;
  final int amountPaise;
  final int occurrences;
  final bool needsConfirmation;
  final IncomeCandidateKind kind;
}

/// Detects salary and other income from credit history, and resolves the
/// primary (salary-landing) account before a salary sender is known (D1).
class SalaryIncomeDetector {
  const SalaryIncomeDetector();

  SalaryProfile detectSalary(
    List<ParsedTxn> credits, {
    String? configuredSalaryRupees,
    required DateTime now,
  }) {
    final salaryCredits = credits.where(_isSalaryCandidate).toList();
    final monthlyMax = _monthlyMax(salaryCredits);

    if (monthlyMax.length < kSalaryMinCleanCredits) {
      return _fallback(configuredSalaryRupees);
    }

    final median = _median(
      monthlyMax.values.map((t) => t.amountPaise).toList(),
    );
    final clean = monthlyMax.values
        .where(
          (t) =>
              t.amountPaise <= median * kSalaryBonusMultiplier &&
              t.amountPaise >= median * kSalaryLowOutlierMultiplier,
        )
        .toList();

    if (clean.length < kSalaryMinCleanCredits) {
      return _fallback(configuredSalaryRupees);
    }

    final cleanAmounts = clean.map((t) => t.amountPaise).toList();
    final cleanMedian = _median(cleanAmounts);
    final stable = cleanAmounts.every(
      (a) => (a - cleanMedian).abs() <= cleanMedian * kSalaryStableToleranceRatio,
    );

    final days = clean.map((t) => t.txnDate.day).toList();
    final expectedDay = _median(days).round();
    final windowDays = days
        .map((d) => (d - expectedDay).abs())
        .fold(0, (a, b) => a > b ? a : b);

    return SalaryProfile(
      confidence: stable
          ? SalaryConfidence.detectedStable
          : SalaryConfidence.detectedVariable,
      basePaise: stable
          ? cleanMedian.round()
          : _percentile(cleanAmounts, kVariableSalaryFloorPercentile).round(),
      expectedDay: expectedDay,
      expectedDayWindowDays: windowDays,
      effectiveMonthSatisfied: salaryCredits.any(
        (t) => t.txnDate.year == now.year && t.txnDate.month == now.month,
      ),
      rangeLowPaise:
          _percentile(cleanAmounts, kVariableSalaryFloorPercentile).round(),
      rangeHighPaise:
          _percentile(cleanAmounts, kVariableSalaryUpperPercentile).round(),
    );
  }

  List<IncomeCandidate> detectOtherIncome(
    List<ParsedTxn> credits, {
    required DateTime now,
  }) {
    final salaryCredits = credits.where(_isSalaryCandidate).toList();
    final salaryChosen = _monthlyMax(salaryCredits).values.toSet();
    final byLabel = <String, List<ParsedTxn>>{};
    for (final txn in credits) {
      if (salaryChosen.contains(txn)) continue;
      byLabel.putIfAbsent(_label(txn), () => []).add(txn);
    }

    return [
      for (final entry in byLabel.entries)
        IncomeCandidate(
          label: entry.key,
          amountPaise: _median(
            entry.value.map((t) => t.amountPaise).toList(),
          ).round(),
          occurrences: entry.value.length,
          needsConfirmation: true,
          kind: entry.value.length >= 2
              ? IncomeCandidateKind.recurringOtherIncome
              : IncomeCandidateKind.oneOffCredit,
        ),
    ];
  }

  /// Resolves the primary (salary-landing) account (decision D1): the bank
  /// account with the most credit volume over the trailing
  /// [kPrimaryAccountLookbackDays]; on a tie or no data, the account of the most
  /// recent bank-balance SMS.
  String? resolvePrimaryAccountLast4(
    List<ParsedTxn> history, {
    required DateTime now,
    String? mostRecentBalanceAccountLast4,
  }) {
    final cutoff = now.subtract(
      const Duration(days: kPrimaryAccountLookbackDays),
    );
    final volumes = <String, int>{};
    for (final txn in history) {
      if (txn.direction != TransactionDirection.credit) continue;
      if (txn.instrument != PaymentInstrument.bank) continue;
      final account = txn.accountLast4;
      if (account == null) continue;
      if (txn.txnDate.isBefore(cutoff)) continue;
      volumes[account] = (volumes[account] ?? 0) + txn.amountPaise;
    }

    if (volumes.isEmpty) return mostRecentBalanceAccountLast4;

    final maxVolume = volumes.values.reduce((a, b) => a > b ? a : b);
    final leaders =
        volumes.entries.where((e) => e.value == maxVolume).toList();
    if (leaders.length > 1) return mostRecentBalanceAccountLast4;
    return leaders.single.key;
  }

  bool _isSalaryCandidate(ParsedTxn txn) =>
      txn.direction == TransactionDirection.credit &&
      txn.instrument == PaymentInstrument.bank &&
      txn.payeeType != PayeeType.p2pIndividual &&
      txn.payeeType != PayeeType.selfTransfer &&
      txn.payeeType != PayeeType.wallet &&
      txn.amountPaise >= kSalaryMinMonthlyPaise;

  /// The largest salary-candidate credit per calendar month (salary is the
  /// dominant monthly credit; refunds/top-ups are smaller).
  Map<String, ParsedTxn> _monthlyMax(List<ParsedTxn> salaryCredits) {
    final byMonth = <String, ParsedTxn>{};
    for (final txn in salaryCredits) {
      final existing = byMonth[txn.txnMonth];
      if (existing == null || txn.amountPaise > existing.amountPaise) {
        byMonth[txn.txnMonth] = txn;
      }
    }
    return byMonth;
  }

  SalaryProfile _fallback(String? configuredSalaryRupees) {
    if (configuredSalaryRupees != null && configuredSalaryRupees.isNotEmpty) {
      return SalaryProfile(
        confidence: SalaryConfidence.configuredFallback,
        basePaise: MoneyParser.parseRupeesToPaise(configuredSalaryRupees),
      );
    }
    return const SalaryProfile(confidence: SalaryConfidence.insufficientData);
  }

  String _label(ParsedTxn txn) =>
      txn.merchant ?? txn.upiVpaNorm ?? txn.sender;

  double _median(List<num> values) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid].toDouble()
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  double _percentile(List<num> values, double p) {
    if (values.isEmpty) return 0;
    final sorted = [...values]..sort();
    if (sorted.length == 1) return sorted.first.toDouble();
    final rank = p * (sorted.length - 1);
    final lo = rank.floor();
    final hi = rank.ceil();
    if (lo == hi) return sorted[lo].toDouble();
    return sorted[lo] + (rank - lo) * (sorted[hi] - sorted[lo]);
  }
}
