import 'package:intl/intl.dart';

import '../core/format.dart';
import '../data/app_state.dart';
import '../data/forecast_models.dart';
import '../data/forecast_risk_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_analysis_snapshot.dart';
import 'anchor_selector.dart';
import 'forecast_ledger_engine.dart';
import 'forecast_reconciliation_engine.dart';
import 'recurring_debit_detector.dart';
import 'reserve_planner.dart';
import 'salary_income_detector.dart';

/// Months of forward outlook the rolling ledger projects (matches the 12-bar
/// year chart the screens render).
const int kForecastHorizonMonths = 12;

/// Minimum size (paise) of an obligation beyond the target month that is
/// surfaced as a dated forward-earmark heads-up so "extra" stays honest
/// (spec §7 "Forward earmark"). ₹10,000.
const int kForwardEarmarkMinPaise = 1000000;

/// A shortfall driven by a discretionary/seasonal estimate below this
/// confidence is labelled an *estimated buffer shortfall*, not a hard
/// due-date shortfall (spec §7).
const double kSeasonalBufferConfidenceThreshold = 0.5;

/// Day-of-month a projected recurring/salary event is placed on when only the
/// cadence (not an exact day) is known; clamped so it is always a valid day.
const int kProjectedEventDayCap = 28;

/// The salary "committed / expected / free" strip (spec §7).
class ForecastSalaryStrip {
  const ForecastSalaryStrip({
    required this.committedPaise,
    required this.expectedPaise,
    required this.freePaise,
  });

  /// Money already earmarked for dated outflows in the target month.
  final int committedPaise;

  /// Salary expected to arrive in the target month (0 when already inside the
  /// balance anchor).
  final int expectedPaise;

  /// What remains after the month's flows — the projected closing balance.
  final int freePaise;
}

/// The reduced forecast for the target month plus the rolling horizon, produced
/// by feeding a [SmsAnalysisSnapshot] through the reconciliation and ledger
/// engines. This is the view-model-agnostic result the `Insights` mapping and
/// the Phase G why-log both read.
class ForecastOutlook {
  const ForecastOutlook({
    required this.targetMonth,
    required this.anchor,
    required this.openingBalancePaise,
    required this.closingBalancePaise,
    required this.minimumBalancePaise,
    required this.minimumBalanceDate,
    required this.shortfallPaise,
    required this.headline,
    required this.isProvisional,
    required this.anchorConfirmLabel,
    required this.salaryMissing,
    required this.isSeasonalBufferShortfall,
    required this.salary,
    required this.lines,
    required this.coverageLines,
    required this.forwardEarmarks,
    required this.assignments,
    required this.months,
    this.riskLines = const [],
  });

  final DateTime targetMonth;
  final BalanceAnchor anchor;
  final int openingBalancePaise;
  final int closingBalancePaise;

  /// The least the balance reaches inside the target month — this drives the
  /// headline (spec §7).
  final int minimumBalancePaise;
  final DateTime minimumBalanceDate;

  /// `max(0, -minimumBalance)` — how much more is needed by [minimumBalanceDate].
  final int shortfallPaise;

  /// The projected surplus (the honest minimum) when there is no shortfall.
  int get surplusPaise => minimumBalancePaise > 0 ? minimumBalancePaise : 0;

  final String headline;
  final bool isProvisional;
  final String anchorConfirmLabel;
  final bool salaryMissing;
  final bool isSeasonalBufferShortfall;
  final ForecastSalaryStrip salary;

  /// The itemised why-log for the target month.
  final List<ForecastLine> lines;
  final List<ForecastCoverageLine> coverageLines;

  /// Dated, material obligations beyond the target month, tagged with their due
  /// month via [ForecastLine.date] (planner-readiness guarantee, spec §13).
  final List<ForecastLine> forwardEarmarks;

  /// Weak (pending) events that did not meet hard confidence threshold and have
  /// no confirmed risk decision — surfaced separately so they cannot create
  /// false safety or false shortfall.
  final List<ForecastLine> riskLines;

  final List<OwnedForecastItem> assignments;
  final List<ForecastMonthResult> months;
}

/// Turns a reduced [SmsAnalysisSnapshot] into a dated cash-flow [ForecastOutlook]
/// by feeding its owned reconciliation items through the reconciliation engine
/// and rolling them forward with the ledger engine (spec §7).
class ForecastAdapter {
  const ForecastAdapter({
    this.reconciliationEngine = const ForecastReconciliationEngine(),
    this.ledgerEngine = const ForecastLedgerEngine(),
  });

  final ForecastReconciliationEngine reconciliationEngine;
  final ForecastLedgerEngine ledgerEngine;

  ForecastOutlook build(
    AppState state,
    SmsAnalysisSnapshot snapshot, {
    DateTime? now,
  }) {
    final referenceNow = now ?? DateTime.now();
    // The reconciliation items were reduced for the snapshot's target month;
    // reconcile and roll forward from that same month so dated items are never
    // misclassified. [referenceNow] still drives anchor freshness and
    // due-vs-today status.
    final targetMonth = snapshot.targetMonth;

    // 1. Blend the SMS bank balance with any user-entered balance (spec §7 /
    //    AnchorSelector): the newest evidence wins, positive bank evidence wins
    //    an exact-day tie.
    final anchor = _resolveAnchor(state, snapshot, referenceNow, targetMonth);

    // 2. Reconcile the target month's owned items (paid / unpaid / possibly-paid
    //    / future-earmark), producing dated events and coverage lines.
    final reconciliation = reconciliationEngine.reconcileMonth(
      targetMonth: targetMonth,
      anchor: anchor,
      items: snapshot.reconciliationItems,
      now: referenceNow,
    );

    // 3. Build the single candidate horizon, apply risk decisions, then
    //    partition into hard events (enter ledger) and risk lines (surfaced
    //    separately so weak candidates cannot create false safety).
    //    Target-month events from reconciliation are always hard (already
    //    resolved by the reconciliation engine).
    final candidateEvents = _horizonEvents(
      snapshot,
      reconciliation,
      targetMonth,
      referenceNow,
    );
    final riskDecisionMap = _buildDecisionMap(snapshot.riskDecisions);
    final hardEvents = <ForecastEvent>[];
    final riskLines = <ForecastLine>[];
    for (final event in candidateEvents) {
      final monthKey = _monthKey(event.date);
      final decision = riskDecisionMap['${event.ownerKey}:$monthKey'];

      if (decision?.status == ForecastRiskDecisionStatus.dismissed) {
        continue; // dismissed — disappear entirely
      }

      if (_isHard(event, decision)) {
        hardEvents.add(_applyOverride(event, decision));
      } else {
        riskLines.add(
          ForecastLine(
            label: event.label,
            amountPaise: event.amountPaise,
            source: event.source,
            date: event.date,
            ownerKey: event.ownerKey,
            status: ForecastLineStatus.review,
            confidence: event.confidence,
            isUserConfirmed: event.isUserConfirmed,
            obligationDedupeKey: event.obligationDedupeKey,
          ),
        );
      }
    }

    final months = ledgerEngine.buildRollingMonths(
      firstMonth: targetMonth,
      monthCount: kForecastHorizonMonths,
      anchor: anchor,
      events: hardEvents,
      coverageLines: reconciliation.coverageLines,
      now: referenceNow,
    );
    final month0 = months.first;

    // 4. Derive the headline drivers.
    final salaryMissing = _isSalaryMissing(state, snapshot, month0);
    final isProvisional = month0.anchorFreshness == AnchorFreshness.stale;
    final seasonalBuffer = _isSeasonalBufferShortfall(month0);
    final salaryStrip = _salaryStrip(month0);
    final forwardEarmarks = _forwardEarmarks(reconciliation);

    final headline = _headline(
      targetMonth: targetMonth,
      month0: month0,
      salaryMissing: salaryMissing,
      isProvisional: isProvisional,
      seasonalBuffer: seasonalBuffer,
    );

    return ForecastOutlook(
      targetMonth: targetMonth,
      anchor: anchor,
      openingBalancePaise: anchor.amountPaise,
      closingBalancePaise: month0.closingBalancePaise,
      minimumBalancePaise: month0.minimumBalancePaise,
      minimumBalanceDate: month0.minimumBalanceDate,
      shortfallPaise: month0.shortfallPaise,
      headline: headline,
      isProvisional: isProvisional,
      anchorConfirmLabel: isProvisional ? 'Confirm balance' : '',
      salaryMissing: salaryMissing,
      isSeasonalBufferShortfall: seasonalBuffer,
      salary: salaryStrip,
      lines: reconciliation.lines,
      coverageLines: month0.coverageLines,
      forwardEarmarks: forwardEarmarks,
      riskLines: List.unmodifiable(riskLines),
      assignments: reconciliation.assignments,
      months: months,
    );
  }

  // ---- anchor -------------------------------------------------------------

  BalanceAnchor _resolveAnchor(
    AppState state,
    SmsAnalysisSnapshot snapshot,
    DateTime now,
    DateTime targetMonth,
  ) {
    final manualAnchor = _manualAnchor(state, now);
    final selected = AnchorSelector.select(
      smsAnchor: snapshot.anchor,
      manualAnchor: manualAnchor,
      now: now,
    );
    return selected ??
        BalanceAnchor(
          amountPaise: 0,
          asOf: targetMonth,
          source: BalanceAnchorSource.projectedCarryForward,
        );
  }

  /// A user-entered current balance is treated as observed at the start of
  /// today: it is the freshest ground truth and wins over an older SMS balance,
  /// but on the same calendar day the SMS bank balance wins (AnchorSelector's
  /// tie rule / spec "positive bank evidence").
  BalanceAnchor? _manualAnchor(AppState state, DateTime now) {
    final rupees = double.tryParse(state.currentBalance.trim());
    if (rupees == null || rupees <= 0) return null;
    return BalanceAnchor(
      amountPaise: (rupees * 100).round(),
      asOf: DateTime(now.year, now.month, now.day),
      source: BalanceAnchorSource.manualUserEntry,
    );
  }

  // ---- horizon events -----------------------------------------------------

  List<ForecastEvent> _horizonEvents(
    SmsAnalysisSnapshot snapshot,
    ForecastReconciliationResult reconciliation,
    DateTime targetMonth,
    DateTime now,
  ) {
    // The target month is fully reconciled against actuals; future months are
    // projected from the locked recurring commitments and the salary profile.
    final events = <ForecastEvent>[...reconciliation.events];

    final salary = snapshot.salary;
    final projectSalary =
        salary.basePaise != null &&
        salary.confidence != SalaryConfidence.insufficientData &&
        salary.confidence != SalaryConfidence.unknown;
    final salaryDay = _min(salary.expectedDay ?? 1, kProjectedEventDayCap);
    final salaryConfidence = _salaryProjectionConfidence(salary.confidence);

    // Collect future obligation events already in reconciliation items (they
    // were tagged as future-earmark by the reconciliation engine). These have
    // known due dates beyond the target month and enter their due month exactly
    // once regardless of amount threshold.
    final futureObligationEvents = <ForecastEvent>[];
    for (final item in snapshot.reconciliationItems) {
      final eventDate = item.eventDate;
      if (eventDate == null) continue;
      if (_sameMonth(eventDate, targetMonth)) continue;
      if (item.amountPaise == null) continue;
      // Only primary-scope items with known amounts.
      if (item.accountScope == AccountScope.secondary) continue;

      final monthOffset =
          (eventDate.year * 12 + eventDate.month) -
          (targetMonth.year * 12 + targetMonth.month);
      if (monthOffset < 1 || monthOffset >= kForecastHorizonMonths) continue;

      futureObligationEvents.add(
        ForecastEvent(
          date: eventDate,
          amountPaise: item.amountPaise!,
          direction: item.direction,
          source: _eventSourceFor(item.owner),
          ownerKey: item.ownerKey,
          label: item.label,
          confidence: item.confidence,
          isUserConfirmed: item.isUserConfirmed,
          obligationDedupeKey: item.obligationDedupeKey,
        ),
      );
    }

    // Build identity-based dedup keys from future obligation events.
    // Uses canonical dedupeKey+month for exact identity, and
    // label+direction+month+amount for economic equivalence checking.
    final futureIdentityKeys = <String>{
      for (final e in futureObligationEvents)
        if (e.obligationDedupeKey != null)
          '${e.obligationDedupeKey}:${_monthKey(e.date)}',
    };
    final futureEconomicKeys = <String>{
      for (final e in futureObligationEvents)
        '${_normLabel(e.label)}:${e.direction.name}:${_monthKey(e.date)}:${e.amountPaise}',
    };

    // Project confirmed active obligations across future offsets 1..11 so they
    // appear as hard canonical events throughout the 12-month horizon.
    final canonicalEvents = _projectCanonicalObligations(
      snapshot.obligations,
      targetMonth,
      futureIdentityKeys,
    );
    // Register canonical projections for economic-equivalence suppression of
    // detected commitments below.
    final canonicalEconomicKeys = <String>{
      for (final e in canonicalEvents)
        '${_normLabel(e.label)}:${e.direction.name}:${_monthKey(e.date)}:${e.amountPaise}',
    };

    for (var offset = 1; offset < kForecastHorizonMonths; offset++) {
      final month = DateTime(targetMonth.year, targetMonth.month + offset);
      for (final commitment in snapshot.commitments) {
        if (!_cadenceHitsMonth(commitment, month)) continue;
        // Suppress only if an economically equivalent canonical/future
        // obligation exists: same label, direction, month, and amount within
        // recurring jitter tolerance.
        if (_isCommitmentSuppressed(
          commitment,
          month,
          canonicalEconomicKeys,
          futureEconomicKeys,
          canonicalEvents,
          futureObligationEvents,
        )) {
          continue;
        }

        final day = _min(commitment.nextExpected.day, kProjectedEventDayCap);
        events.add(
          ForecastEvent(
            date: DateTime(month.year, month.month, day),
            amountPaise: commitment.amountPaise,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.recurring,
            ownerKey: 'commitment:${commitment.merchantNorm}',
            label: _titleCase(commitment.merchantNorm),
            confidence: commitment.confidence,
          ),
        );
      }
      if (projectSalary) {
        events.add(
          ForecastEvent(
            date: DateTime(month.year, month.month, salaryDay),
            amountPaise: salary.basePaise!,
            direction: LedgerDirection.inflow,
            source: ForecastEventSource.salary,
            ownerKey: 'salary:projected',
            label: 'Salary (expected)',
            confidence: salaryConfidence,
          ),
        );
      }
    }

    // Add future obligation events after projected commitments so they are
    // included in the candidate horizon for risk partitioning.
    events.addAll(futureObligationEvents);

    // Add canonical obligation projections — these are user-confirmed and will
    // be partitioned as hard by _isHard.
    events.addAll(canonicalEvents);

    return events;
  }

  /// Projects confirmed, active obligations from [obligations] across future
  /// months 1..11 from [targetMonth] according to their recurrence. Only
  /// obligations with a known positive amount and a concrete due anchor
  /// (dueDay or dueDate) are projected. Dismissed, secondary-scope, and fully
  /// paid one-time obligations are excluded. Months already occupied in
  /// [existingMonthKeys] (from future reconciliation items) are skipped to
  /// prevent double-counting.
  List<ForecastEvent> _projectCanonicalObligations(
    List<ObligationRecord> obligations,
    DateTime targetMonth,
    Set<String> existingMonthKeys,
  ) {
    final events = <ForecastEvent>[];
    // Track keys we project to avoid duplicate projection across obligations
    // with the same label but different identity.
    final projectedKeys = <String>{};

    for (final obl in obligations) {
      // Must be confirmed and active.
      if (obl.reviewStatus == ObligationReviewStatus.dismissed) continue;
      if (obl.paymentAccountScope == AccountScope.secondary) continue;

      // Must have a known positive amount.
      final amount = obl.amountPaise;
      if (amount == null || amount <= 0) continue;

      // Must have a concrete due anchor: dueDay from dueDate or explicit.
      final dueDay = obl.dueDay ?? obl.dueDate?.day;
      if (dueDay == null) continue;

      // For quarterly/annual, need a month anchor.
      final dueMonth = obl.dueMonth ?? obl.dueDate?.month;

      // Fully paid one-time — skip entirely.
      if (obl.recurrence == ReconciliationRecurrence.onetime &&
          obl.paymentStatus == ReconciliationPaymentStatus.paid) {
        continue;
      }

      final isConfirmed = obl.reviewStatus == ObligationReviewStatus.confirmed;
      final ownerName = _obligationOwnerName(obl.sourceType);
      final clampedDay = _min(dueDay, kProjectedEventDayCap);

      for (var offset = 1; offset < kForecastHorizonMonths; offset++) {
        final month = DateTime(targetMonth.year, targetMonth.month + offset);

        if (!_obligationHitsMonth(
          obl.recurrence,
          dueMonth,
          targetMonth,
          month,
        )) {
          continue;
        }

        // Deduplicate against existing future obligation events using
        // exact canonical identity (dedupeKey + month) only — not label alone,
        // so distinct same-label obligations with different amounts survive.
        final canonicalKey = '${obl.dedupeKey}:${_monthKey(month)}';

        if (existingMonthKeys.contains(canonicalKey)) continue;
        if (projectedKeys.contains(canonicalKey)) continue;
        projectedKeys.add(canonicalKey);

        events.add(
          ForecastEvent(
            date: DateTime(month.year, month.month, clampedDay),
            amountPaise: amount,
            direction: LedgerDirection.outflow,
            source: _eventSourceForObligationSource(obl.sourceType),
            ownerKey: '$ownerName:obl:${obl.dedupeKey}',
            label: obl.merchant,
            confidence: obl.confidence,
            isUserConfirmed: isConfirmed,
            obligationDedupeKey: obl.dedupeKey,
          ),
        );
      }
    }
    return events;
  }

  /// Whether [recurrence] hits [month] given a [dueMonth] anchor relative to
  /// [targetMonth].
  static bool _obligationHitsMonth(
    ReconciliationRecurrence recurrence,
    int? dueMonth,
    DateTime targetMonth,
    DateTime month,
  ) {
    final offset =
        (month.year * 12 + month.month) -
        (targetMonth.year * 12 + targetMonth.month);
    if (offset < 1) return false;
    return switch (recurrence) {
      ReconciliationRecurrence.monthly => true,
      ReconciliationRecurrence.quarterly =>
        dueMonth != null && (month.month - dueMonth) % 3 == 0,
      ReconciliationRecurrence.annual =>
        dueMonth != null && month.month == dueMonth,
      ReconciliationRecurrence.onetime => false,
    };
  }

  static String _obligationOwnerName(ObligationSourceType source) =>
      switch (source) {
        ObligationSourceType.gmail => 'gmailBill',
        ObligationSourceType.manual => 'gmailBill',
        ObligationSourceType.smsRecurring => 'recurringCommitment',
        ObligationSourceType.configuredPlan => 'configuredContribution',
      };

  static ForecastEventSource _eventSourceForObligationSource(
    ObligationSourceType source,
  ) => switch (source) {
    ObligationSourceType.gmail => ForecastEventSource.gmailBill,
    ObligationSourceType.manual => ForecastEventSource.manual,
    ObligationSourceType.smsRecurring => ForecastEventSource.recurring,
    ObligationSourceType.configuredPlan =>
      ForecastEventSource.configuredContribution,
  };

  static ForecastEventSource _eventSourceFor(ForecastOwner owner) =>
      switch (owner) {
        ForecastOwner.salary => ForecastEventSource.salary,
        ForecastOwner.otherIncome => ForecastEventSource.otherIncome,
        ForecastOwner.recurringCommitment => ForecastEventSource.recurring,
        ForecastOwner.gmailBill => ForecastEventSource.gmailBill,
        ForecastOwner.configuredContribution =>
          ForecastEventSource.configuredContribution,
        ForecastOwner.cardPurchase ||
        ForecastOwner.cardStatement => ForecastEventSource.cardStatement,
        ForecastOwner.cardPayment => ForecastEventSource.cardPayment,
        ForecastOwner.refund => ForecastEventSource.refund,
        ForecastOwner.transfer => ForecastEventSource.transfer,
        _ => ForecastEventSource.recurring,
      };

  static bool _sameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;

  // ---- risk decision helpers ----------------------------------------------

  /// Build a lookup map keyed by "ownerKey:yyyy-mm".
  static Map<String, ForecastRiskDecision> _buildDecisionMap(
    List<ForecastRiskDecision> decisions,
  ) {
    return {for (final d in decisions) '${d.ownerKey}:${d.targetMonth}': d};
  }

  /// An event is "hard" (enters the rolling ledger) if it is user-confirmed, a
  /// confirmed risk decision exists, or confidence meets the reserve threshold.
  static bool _isHard(ForecastEvent event, ForecastRiskDecision? decision) =>
      decision?.status == ForecastRiskDecisionStatus.confirmed ||
      event.isUserConfirmed ||
      event.confidence >= kReserveHardConfidence;

  /// Apply amount/date overrides from a confirmed decision.
  static ForecastEvent _applyOverride(
    ForecastEvent event,
    ForecastRiskDecision? decision,
  ) {
    if (decision == null) return event;
    if (decision.status != ForecastRiskDecisionStatus.confirmed) return event;
    final amount = decision.amountOverridePaise ?? event.amountPaise;
    final date = decision.dueDateOverride ?? event.date;
    return ForecastEvent(
      date: date,
      amountPaise: amount,
      direction: event.direction,
      source: event.source,
      ownerKey: event.ownerKey,
      label: event.label,
      confidence: event.confidence,
      isUserConfirmed: true,
      obligationDedupeKey: event.obligationDedupeKey,
    );
  }

  /// Format a DateTime as yyyy-mm for decision lookup.
  static String _monthKey(DateTime date) {
    final y = date.year.toString();
    final m = date.month.toString().padLeft(2, '0');
    return '$y-$m';
  }

  /// Normalize a label for deduplication purposes.
  static String _normLabel(String label) => label.trim().toLowerCase();

  bool _cadenceHitsMonth(RecurringCommitment commitment, DateTime month) {
    final expected = commitment.nextExpected;
    final diff =
        (month.year * 12 + month.month) - (expected.year * 12 + expected.month);
    if (diff < 0) return false;
    return switch (commitment.cadence) {
      RecurringCadence.monthly => true,
      RecurringCadence.quarterly => diff % 3 == 0,
      RecurringCadence.halfYearly => diff % 6 == 0,
      RecurringCadence.annual => diff % 12 == 0,
    };
  }

  /// Suppresses a detected commitment only when an economically equivalent
  /// canonical or future obligation exists: same normalized label, direction,
  /// month, and amount within recurring jitter tolerance.
  bool _isCommitmentSuppressed(
    RecurringCommitment commitment,
    DateTime month,
    Set<String> canonicalEconomicKeys,
    Set<String> futureEconomicKeys,
    List<ForecastEvent> canonicalEvents,
    List<ForecastEvent> futureObligationEvents,
  ) {
    final normLabel = _normLabel(commitment.merchantNorm);
    final monthStr = _monthKey(month);
    final direction = LedgerDirection.outflow; // commitments are always outflow

    // Check exact economic match first (fast path).
    final exactKey =
        '$normLabel:${direction.name}:$monthStr:${commitment.amountPaise}';
    if (canonicalEconomicKeys.contains(exactKey) ||
        futureEconomicKeys.contains(exactKey)) {
      return true;
    }

    // Check amount-within-jitter against canonical events in the same month.
    for (final e in canonicalEvents) {
      if (_normLabel(e.label) != normLabel) continue;
      if (e.direction != direction) continue;
      if (_monthKey(e.date) != monthStr) continue;
      if (_withinRecurringJitter(commitment.amountPaise, e.amountPaise)) {
        return true;
      }
    }
    // Check amount-within-jitter against future obligation events.
    for (final e in futureObligationEvents) {
      if (_normLabel(e.label) != normLabel) continue;
      if (e.direction != direction) continue;
      if (_monthKey(e.date) != monthStr) continue;
      if (_withinRecurringJitter(commitment.amountPaise, e.amountPaise)) {
        return true;
      }
    }
    return false;
  }

  /// Whether [actual] is within the recurring amount jitter tolerance of [expected].
  static bool _withinRecurringJitter(int actual, int expected) {
    final tolerance = _max(
      (expected * kRecurringAmountJitterRatio).round(),
      kRecurringAmountJitterFloorPaise,
    );
    return (actual - expected).abs() <= tolerance;
  }

  static int _max(int a, int b) => a > b ? a : b;

  double _salaryProjectionConfidence(SalaryConfidence confidence) =>
      switch (confidence) {
        SalaryConfidence.detectedStable => 0.9,
        SalaryConfidence.detectedVariable => 0.7,
        SalaryConfidence.configuredFallback => 0.6,
        SalaryConfidence.insufficientData || SalaryConfidence.unknown => 0.4,
      };

  // ---- headline drivers ---------------------------------------------------

  bool _isSalaryMissing(
    AppState state,
    SmsAnalysisSnapshot snapshot,
    ForecastMonthResult month0,
  ) {
    final hasSalaryEvent = month0.events.any(
      (e) => e.source == ForecastEventSource.salary,
    );
    if (hasSalaryEvent) return false;
    final salary = snapshot.salary;
    final detected =
        salary.basePaise != null &&
        salary.confidence != SalaryConfidence.insufficientData &&
        salary.confidence != SalaryConfidence.unknown;
    if (detected) return false;
    final configured = (double.tryParse(state.salary.trim()) ?? 0) > 0;
    return !configured;
  }

  bool _isSeasonalBufferShortfall(ForecastMonthResult month0) {
    if (month0.minimumBalancePaise >= 0) return false;
    final minDay = _dayOnly(month0.minimumBalanceDate);
    final driving = month0.events.where(
      (e) =>
          e.direction == LedgerDirection.outflow && _dayOnly(e.date) == minDay,
    );
    return driving.isNotEmpty &&
        driving.every(
          (e) =>
              e.source == ForecastEventSource.seasonal &&
              e.confidence < kSeasonalBufferConfidenceThreshold,
        );
  }

  ForecastSalaryStrip _salaryStrip(ForecastMonthResult month0) {
    var committed = 0;
    var expected = 0;
    for (final event in month0.events) {
      switch (event.direction) {
        case LedgerDirection.outflow:
          committed += event.amountPaise;
        case LedgerDirection.inflow:
          if (event.source == ForecastEventSource.salary) {
            expected += event.amountPaise;
          }
      }
    }
    return ForecastSalaryStrip(
      committedPaise: committed,
      expectedPaise: expected,
      freePaise: month0.closingBalancePaise,
    );
  }

  List<ForecastLine> _forwardEarmarks(ForecastReconciliationResult recon) {
    final earmarkOwnerKeys = {
      for (final line in recon.coverageLines)
        if (line.reason == CoverageReason.futureEarmark) line.ownerKey,
    };
    final earmarks = [
      for (final line in recon.lines)
        if (line.date != null &&
            line.amountPaise >= kForwardEarmarkMinPaise &&
            earmarkOwnerKeys.contains(line.ownerKey))
          line,
    ]..sort((a, b) => a.date!.compareTo(b.date!));
    return List.unmodifiable(earmarks);
  }

  String _headline({
    required DateTime targetMonth,
    required ForecastMonthResult month0,
    required bool salaryMissing,
    required bool isProvisional,
    required bool seasonalBuffer,
  }) {
    final monthName = DateFormat('MMMM').format(targetMonth);
    final String core;
    if (salaryMissing) {
      core = 'Add your income to project $monthName.';
    } else if (seasonalBuffer) {
      final amount = inr(month0.shortfallPaise / 100.0);
      final date = DateFormat('d MMM').format(month0.minimumBalanceDate);
      core =
          'Estimated buffer shortfall of $amount around $date — mostly discretionary, not a fixed bill.';
    } else if (month0.shortfallPaise > 0) {
      final amount = inr(month0.shortfallPaise / 100.0);
      final date = DateFormat('d MMM').format(month0.minimumBalanceDate);
      core = 'You need $amount more by $date';
    } else {
      final amount = inr(month0.minimumBalancePaise / 100.0);
      core = "For $monthName you're projected to have $amount extra";
    }
    if (isProvisional) {
      return 'Provisional — confirm your balance. $core';
    }
    return core;
  }

  // ---- small helpers ------------------------------------------------------

  static int _min(int a, int b) => a < b ? a : b;

  static DateTime _dayOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  static String _titleCase(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return trimmed;
    return trimmed
        .split(RegExp(r'\s+'))
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}
