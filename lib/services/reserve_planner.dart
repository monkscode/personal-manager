import '../data/forecast_models.dart';
import '../data/obligation_models.dart';

const int kReserveMinimumPaise = 1000000; // Rs 10,000
const double kReserveHardConfidence = 0.8;

class ReserveContribution {
  const ReserveContribution({required this.date, required this.amountPaise});
  final DateTime date;
  final int amountPaise;
}

class ReserveSchedule {
  const ReserveSchedule({
    required this.dedupeKey,
    required this.label,
    required this.dueDate,
    required this.targetPaise,
    required this.fundedPaise,
    required this.remainingPaise,
    required this.contributions,
    required this.isFullyFunded,
    required this.isOverdue,
  });
  final String dedupeKey;
  final String label;
  final DateTime dueDate;
  final int targetPaise;
  final int fundedPaise;
  final int remainingPaise;
  final List<ReserveContribution> contributions;
  final bool isFullyFunded;
  final bool isOverdue;

  int get nextContributionPaise =>
      contributions.isEmpty ? 0 : contributions.first.amountPaise;
}

class ReserveCandidate {
  const ReserveCandidate({
    required this.dedupeKey,
    required this.label,
    required this.dueDate,
    required this.targetPaise,
  });
  final String dedupeKey;
  final String label;
  final DateTime dueDate;
  final int targetPaise;
}

class ReservePlan {
  const ReservePlan({required this.schedules, required this.availableToEnable});
  const ReservePlan.empty()
    : schedules = const [],
      availableToEnable = const [];
  final List<ReserveSchedule> schedules;
  final List<ReserveCandidate> availableToEnable;

  int contributionInMonth(DateTime month) => schedules
      .expand((schedule) => schedule.contributions)
      .where(
        (entry) =>
            entry.date.year == month.year && entry.date.month == month.month,
      )
      .fold(0, (sum, entry) => sum + entry.amountPaise);
}

class ReservePlanner {
  const ReservePlanner();

  ReservePlan build({
    required List<ObligationRecord> obligations,
    required DateTime now,
    required int? expectedSalaryDay,
  }) {
    final schedules = <ReserveSchedule>[];
    final availableToEnable = <ReserveCandidate>[];

    for (final obligation in obligations) {
      // Skip paid, dismissed, or monthly obligations
      if (obligation.paymentStatus == ReconciliationPaymentStatus.paid ||
          obligation.reviewStatus == ObligationReviewStatus.dismissed ||
          obligation.recurrence == ReconciliationRecurrence.monthly) {
        continue;
      }

      // Calculate target amount
      final targetPaise =
          obligation.outstandingPaise ??
          ((obligation.amountPaise ?? 0) - (obligation.amountPaidPaise ?? 0));

      if (targetPaise <= 0 || obligation.dueDate == null) {
        continue;
      }

      // Check eligibility
      final isConfirmed =
          obligation.reviewStatus == ObligationReviewStatus.confirmed;
      final isHighConfidence = obligation.confidence >= kReserveHardConfidence;
      final isEnabled = obligation.reserveEnabled;
      final meetsThreshold = targetPaise >= kReserveMinimumPaise;

      if (!isConfirmed && !isHighConfidence) {
        continue;
      }

      // If eligible but not enabled and below threshold, add to availableToEnable
      if (!isEnabled && !meetsThreshold) {
        availableToEnable.add(
          ReserveCandidate(
            dedupeKey: obligation.dedupeKey,
            label: obligation.merchant,
            dueDate: obligation.dueDate!,
            targetPaise: targetPaise,
          ),
        );
        continue;
      }

      // Generate schedule
      final fundedPaise = obligation.reserveFundedPaise;
      final remainingPaise = (targetPaise - fundedPaise).clamp(0, targetPaise);
      final isFullyFunded = remainingPaise == 0;
      // Day-only: a bill due today at 00:00 is not overdue at 2pm today
      // (TASK-24 M3).
      final isOverdue = _dayOnly(obligation.dueDate!).isBefore(_dayOnly(now));

      final contributions = isFullyFunded
          ? <ReserveContribution>[]
          : _generateContributions(
              remainingPaise: remainingPaise,
              dueDate: obligation.dueDate!,
              now: now,
              expectedSalaryDay: expectedSalaryDay,
            );

      schedules.add(
        ReserveSchedule(
          dedupeKey: obligation.dedupeKey,
          label: obligation.merchant,
          dueDate: obligation.dueDate!,
          targetPaise: targetPaise,
          fundedPaise: fundedPaise,
          remainingPaise: remainingPaise,
          contributions: contributions,
          isFullyFunded: isFullyFunded,
          isOverdue: isOverdue,
        ),
      );
    }

    return ReservePlan(
      schedules: schedules,
      availableToEnable: availableToEnable,
    );
  }

  List<ReserveContribution> _generateContributions({
    required int remainingPaise,
    required DateTime dueDate,
    required DateTime now,
    required int? expectedSalaryDay,
  }) {
    final opportunities = <DateTime>[];

    // Add immediate opportunity (today)
    opportunities.add(now);

    // Add monthly opportunities strictly before due date
    var currentMonth = DateTime(now.year, now.month);
    final dueMonth = DateTime(dueDate.year, dueDate.month);

    while (currentMonth.isBefore(dueMonth)) {
      // Move to next month
      currentMonth = DateTime(
        currentMonth.year + (currentMonth.month == 12 ? 1 : 0),
        currentMonth.month == 12 ? 1 : currentMonth.month + 1,
      );

      // Calculate opportunity date for this month
      // Use salary day if known, otherwise fallback to calendar day 1
      final opportunityDate = expectedSalaryDay != null
          ? _getSalaryDateForMonth(currentMonth, expectedSalaryDay)
          : DateTime(currentMonth.year, currentMonth.month, 1);

      // Only add if strictly before due date
      if (opportunityDate.isBefore(dueDate)) {
        opportunities.add(opportunityDate);
      }
    }

    // Distribute the remaining amount across the opportunities in whole-rupee
    // instalments, using integer arithmetic throughout: money never touches a
    // double (TASK-24 M1).
    final numOpportunities = opportunities.length;
    final perOpportunityPaise =
        (remainingPaise + numOpportunities - 1) ~/ numOpportunities;
    final instalmentPaise = _ceilToRupee(perOpportunityPaise);

    final contributions = <ReserveContribution>[];
    var distributed = 0;

    for (final date in opportunities) {
      if (distributed >= remainingPaise) break;
      final outstanding = remainingPaise - distributed;
      // The final instalment absorbs the residual rather than repeating the
      // already-ceiled instalment, so the plan overshoots the target by less
      // than one rupee in total. Some overshoot is unavoidable while
      // instalments are whole rupees.
      final amount = instalmentPaise < outstanding
          ? instalmentPaise
          : _ceilToRupee(outstanding);
      contributions.add(
        ReserveContribution(date: date, amountPaise: amount),
      );
      distributed += amount;
    }

    return contributions;
  }

  static int _ceilToRupee(int paise) => ((paise + 99) ~/ 100) * 100;

  static DateTime _dayOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  DateTime _getSalaryDateForMonth(DateTime month, int salaryDay) {
    // Get the last day of the month
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final actualDay = salaryDay.clamp(1, lastDay);
    return DateTime(month.year, month.month, actualDay);
  }
}
