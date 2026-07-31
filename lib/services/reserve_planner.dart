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
      final isOverdue = obligation.dueDate!.isBefore(now);

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

    // If only immediate opportunity or no opportunities left
    if (opportunities.isEmpty) {
      return [];
    }

    // Distribute remaining amount across opportunities
    final numOpportunities = opportunities.length;
    final perOpportunityPaise = (remainingPaise / numOpportunities).ceil();

    // Ceiling to whole rupees (100 paise)
    final ceiledPerOpportunity = ((perOpportunityPaise + 99) ~/ 100) * 100;

    final contributions = <ReserveContribution>[];
    var distributed = 0;

    for (var i = 0; i < opportunities.length; i++) {
      final isLast = i == opportunities.length - 1;
      int amount;
      if (isLast) {
        // For last contribution, take remaining and ceiling to whole rupees
        final remaining = remainingPaise - distributed;
        amount = ((remaining + 99) ~/ 100) * 100;
      } else {
        amount = ceiledPerOpportunity.clamp(0, remainingPaise - distributed);
      }

      if (amount > 0) {
        contributions.add(
          ReserveContribution(date: opportunities[i], amountPaise: amount),
        );
        distributed += amount;
      }
    }

    return contributions;
  }

  DateTime _getSalaryDateForMonth(DateTime month, int salaryDay) {
    // Get the last day of the month
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    final actualDay = salaryDay.clamp(1, lastDay);
    return DateTime(month.year, month.month, actualDay);
  }
}
