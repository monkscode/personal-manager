import '../data/forecast_models.dart';
import 'forecast_adapter.dart';
import 'reserve_planner.dart';

/// Immutable view-model exposing exactly 12 month-specific forecast plans,
/// each with required opening balance, lines, reserves, and risk buffer.
class ForecastExplorer {
  const ForecastExplorer({
    required this.plans,
    required this.currentAction,
    required this.availableToEnable,
  });

  final List<ForecastMonthPlan> plans;
  final ForecastCurrentAction currentAction;
  final List<ReserveCandidate> availableToEnable;

  ForecastMonthPlan planAt(int offset) {
    if (offset < 0 || offset >= plans.length) {
      throw RangeError.range(offset, 0, plans.length - 1, 'offset');
    }
    return plans[offset];
  }
}

/// Forecast plan for a single month with all details needed to render
/// the month's requirements, lines, reserves, and risk buffer.
class ForecastMonthPlan {
  const ForecastMonthPlan({
    required this.monthStart,
    required this.requiredInBankPaise,
    required this.openingBalancePaise,
    required this.closingBalancePaise,
    required this.minimumBalancePaise,
    required this.minimumBalanceDate,
    required this.shortfallPaise,
    required this.committedOutflowPaise,
    required this.expectedInflowPaise,
    required this.reserveContributionPaise,
    required this.reserveSchedules,
    required this.riskBufferPaise,
    required this.riskLines,
    required this.hardLines,
    required this.coverageLines,
    required this.confidence,
    required this.isProvisional,
  });

  final DateTime monthStart;

  /// Zero-based signed event-prefix minimum: the amount needed in the bank
  /// at month start to survive all dated flows, NOT the same as shortfall.
  final int requiredInBankPaise;

  final int openingBalancePaise;
  final int closingBalancePaise;
  final int minimumBalancePaise;
  final DateTime minimumBalanceDate;

  /// Max(0, -minimumBalance): the gap to fill by minimumBalanceDate.
  final int shortfallPaise;

  final int committedOutflowPaise;
  final int expectedInflowPaise;
  final int reserveContributionPaise;
  final List<ReserveSchedule> reserveSchedules;
  final int riskBufferPaise;
  final List<ForecastLine> riskLines;
  final List<ForecastLine> hardLines;
  final List<ForecastCoverageLine> coverageLines;
  final double confidence;
  final bool isProvisional;
}

/// Current action guidance for the target month (first plan).
class ForecastCurrentAction {
  const ForecastCurrentAction({
    required this.requiredInBankPaise,
    required this.keepAvailableUntil,
    required this.reserveContributionPaise,
    required this.reserveSchedules,
    required this.isProvisional,
  });

  final int requiredInBankPaise;
  final DateTime keepAvailableUntil;
  final int reserveContributionPaise;
  final List<ReserveSchedule> reserveSchedules;
  final bool isProvisional;
}

/// Build the immutable forecast explorer from outlook and reserve plan.
/// Validates that outlook contains exactly 12 months as per adapter contract.
ForecastExplorer buildForecastExplorer({
  required ForecastOutlook outlook,
  required ReservePlan reservePlan,
  required DateTime now,
}) {
  if (outlook.months.length != kForecastHorizonMonths) {
    throw StateError(
      'ForecastOutlook must contain exactly $kForecastHorizonMonths months, '
      'got ${outlook.months.length}',
    );
  }

  final plans = <ForecastMonthPlan>[];

  for (var i = 0; i < kForecastHorizonMonths; i++) {
    final monthResult = outlook.months[i];
    final monthStart = DateTime(
      outlook.targetMonth.year,
      outlook.targetMonth.month + i,
    );

    // Required opening balance: zero-based event-prefix minimum
    final requiredInBank = requiredOpeningBalancePaise(monthResult.events);

    // Build hard lines from event ownership + matched reconciliation lines
    final monthHardLines = _hardLinesForMonth(
      monthResult.events,
      outlook.lines,
      monthStart,
    );
    final monthRiskLines = _linesForMonth(outlook.riskLines, monthStart);
    // Use coverage lines from the month result (already month-specific)
    final monthCoverageLines = monthResult.coverageLines;

    // Reserve schedules with contributions in this month
    final monthReserveSchedules = reservePlan.schedules
        .where(
          (schedule) => schedule.contributions.any(
            (c) =>
                c.date.year == monthStart.year &&
                c.date.month == monthStart.month,
          ),
        )
        .toList();

    // Reserve contribution total for this month
    final reserveContribution = reservePlan.contributionInMonth(monthStart);

    // Risk buffer: sum of risk line amounts in this month
    final riskBuffer = monthRiskLines.fold<int>(
      0,
      (sum, line) => sum + line.amountPaise,
    );

    // Committed outflow: sum of hard outflow events
    final committedOutflow = monthResult.events
        .where((e) => e.direction == LedgerDirection.outflow)
        .fold<int>(0, (sum, e) => sum + e.amountPaise);

    // Expected inflow: sum of hard inflow events
    final expectedInflow = monthResult.events
        .where((e) => e.direction == LedgerDirection.inflow)
        .fold<int>(0, (sum, e) => sum + e.amountPaise);

    // Confidence: minimum of all evidence sources
    final confidences = <double>[
      // Opening line confidence from month result lines
      ...monthResult.lines.map((line) => line.confidence),
      // Event confidences
      ...monthResult.events.map((e) => e.confidence),
      // Coverage line confidences
      ...monthResult.coverageLines.map((c) => c.confidence),
      // Risk line confidences (dated only)
      ...monthRiskLines.map((r) => r.confidence),
    ];
    final confidence = confidences.isEmpty
        ? 0.3 // Low confidence when no evidence
        : confidences.reduce((a, b) => a < b ? a : b);

    plans.add(
      ForecastMonthPlan(
        monthStart: monthStart,
        requiredInBankPaise: requiredInBank,
        openingBalancePaise: monthResult.openingBalancePaise,
        closingBalancePaise: monthResult.closingBalancePaise,
        minimumBalancePaise: monthResult.minimumBalancePaise,
        minimumBalanceDate: monthResult.minimumBalanceDate,
        shortfallPaise: monthResult.shortfallPaise,
        committedOutflowPaise: committedOutflow,
        expectedInflowPaise: expectedInflow,
        reserveContributionPaise: reserveContribution,
        reserveSchedules: monthReserveSchedules,
        riskBufferPaise: riskBuffer,
        riskLines: monthRiskLines,
        hardLines: monthHardLines,
        coverageLines: monthCoverageLines,
        confidence: confidence,
        isProvisional: outlook.isProvisional,
      ),
    );
  }

  // Current action from first month
  final firstPlan = plans.first;
  final currentAction = ForecastCurrentAction(
    requiredInBankPaise: firstPlan.requiredInBankPaise,
    keepAvailableUntil: firstPlan.minimumBalanceDate,
    reserveContributionPaise: firstPlan.reserveContributionPaise,
    reserveSchedules: firstPlan.reserveSchedules,
    isProvisional: outlook.isProvisional,
  );

  return ForecastExplorer(
    plans: plans,
    currentAction: currentAction,
    availableToEnable: List.unmodifiable(reservePlan.availableToEnable),
  );
}

/// Compute required opening balance using zero-based signed event-prefix
/// minimum. This is NOT the same as shortfall, which includes opening balance.
int requiredOpeningBalancePaise(List<ForecastEvent> events) {
  final ordered = [...events]
    ..sort((a, b) {
      final dateCompare = a.date.compareTo(b.date);
      if (dateCompare != 0) return dateCompare;
      // Same date: outflows before inflows (conservative, matches ledger)
      if (a.direction == LedgerDirection.outflow &&
          b.direction == LedgerDirection.inflow) {
        return -1;
      }
      if (a.direction == LedgerDirection.inflow &&
          b.direction == LedgerDirection.outflow) {
        return 1;
      }
      return 0;
    });

  var cumulative = 0;
  var minimum = 0;

  for (final event in ordered) {
    cumulative += event.direction == LedgerDirection.inflow
        ? event.amountPaise
        : -event.amountPaise;
    if (cumulative < minimum) {
      minimum = cumulative;
    }
  }

  return -minimum;
}

/// Normalize a date to the first of the month.
DateTime _normalizeMonth(DateTime date) {
  return DateTime(date.year, date.month, 1);
}

/// Filter lines to those with a date in the specified month.
List<ForecastLine> _linesForMonth(List<ForecastLine> lines, DateTime month) {
  return lines.where((line) {
    if (line.date == null) return false;
    final lineMonth = _normalizeMonth(line.date!);
    return lineMonth.year == month.year && lineMonth.month == month.month;
  }).toList();
}

/// Statuses that represent true hard states (not weak/risk/coverage).
const _hardStatuses = {
  ForecastLineStatus.paid,
  ForecastLineStatus.unpaid,
  ForecastLineStatus.overdue,
  ForecastLineStatus.alreadyInAnchor,
  ForecastLineStatus.projected,
  ForecastLineStatus.reconciled,
  ForecastLineStatus.estimated,
  ForecastLineStatus.exceeded,
  ForecastLineStatus.opening,
};

/// Build hard lines for a month from event ownership, enriched with matched
/// reconciliation lines. Also includes alreadyInAnchor informational lines
/// from [reconLines] even though they are not events.
List<ForecastLine> _hardLinesForMonth(
  List<ForecastEvent> events,
  List<ForecastLine> reconLines,
  DateTime monthStart,
) {
  final result = <ForecastLine>[];
  final usedKeys = <String>{};

  // Index reconciliation lines by ownerKey for O(1) lookup.
  final reconByOwner = <String, List<ForecastLine>>{};
  for (final line in reconLines) {
    if (line.date == null) continue;
    final lm = _normalizeMonth(line.date!);
    if (lm.year != monthStart.year || lm.month != monthStart.month) continue;
    (reconByOwner[line.ownerKey] ??= []).add(line);
  }

  // 1. For each hard event, find matching reconciliation line or create one.
  for (final event in events) {
    final em = _normalizeMonth(event.date);
    if (em.year != monthStart.year || em.month != monthStart.month) continue;

    final dedupeKey =
        '${event.ownerKey}:${event.date.millisecondsSinceEpoch}:${event.amountPaise}';
    if (usedKeys.contains(dedupeKey)) continue;
    usedKeys.add(dedupeKey);

    // Try to find a matching reconciliation line with a hard status.
    final candidates = reconByOwner[event.ownerKey];
    ForecastLine? match;
    if (candidates != null) {
      for (final c in candidates) {
        if (c.amountPaise == event.amountPaise &&
            c.date == event.date &&
            _hardStatuses.contains(c.status)) {
          match = c;
          break;
        }
      }
    }

    if (match != null) {
      result.add(match);
    } else {
      // Create a projected line from the event.
      result.add(
        ForecastLine(
          label: event.label,
          amountPaise: event.amountPaise,
          source: event.source,
          date: event.date,
          ownerKey: event.ownerKey,
          status: ForecastLineStatus.projected,
          confidence: event.confidence,
          isUserConfirmed: event.isUserConfirmed,
          obligationDedupeKey: event.obligationDedupeKey,
        ),
      );
    }
  }

  // 2. Include alreadyInAnchor informational lines from reconciliation
  //    (these are not events but must appear in hardLines).
  for (final line in reconByOwner.values.expand((v) => v)) {
    if (line.status != ForecastLineStatus.alreadyInAnchor) continue;
    final dedupeKey =
        '${line.ownerKey}:${line.date!.millisecondsSinceEpoch}:${line.amountPaise}';
    if (usedKeys.contains(dedupeKey)) continue;
    usedKeys.add(dedupeKey);
    result.add(line);
  }

  return result;
}
