import 'package:intl/intl.dart';

import '../core/format.dart';
import '../core/money.dart';
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
import 'seasonal_estimator.dart';

/// Minimum size (paise) of an obligation beyond the target month that is
/// surfaced as a dated forward-earmark heads-up so "extra" stays honest
/// (spec §7 "Forward earmark"). ₹10,000.
const int kForwardEarmarkMinPaise = 1000000;

/// Day-of-month a projected recurring/salary event is placed on when only the
/// cadence (not an exact day) is known; clamped so it is always a valid day.
const int kProjectedEventDayCap = 28;

/// The salary "committed / expected / free" strip (spec §7).
class ForecastSalaryStrip {
  const ForecastSalaryStrip({
    required this.committedPaise,
    required this.expectedSalaryPaise,
    required this.freePaise,
  });

  /// Money already earmarked for dated outflows in the target month.
  final int committedPaise;

  /// Salary expected to arrive in the target month (0 when already inside the
  /// balance anchor).
  final int expectedSalaryPaise;

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
    required this.salaryMissing,
    required this.isSeasonalBufferShortfall,
    required this.salary,
    required this.lines,
    required this.coverageLines,
    required this.forwardEarmarks,
    required this.assignments,
    required this.months,
    this.riskLines = const [],
    this.decidedLines = const [],
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

  /// Candidates whose placement is the user's own decision, so that decision
  /// can be reversed (TASK-40). Not a ledger input — nothing sums this.
  final List<ForecastDecidedLine> decidedLines;

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
    //    Target-month events from reconciliation go through the same partition
    //    as everything else — being reconciled does not make an item hard, and
    //    a weak target-month candidate is routed to the risk lines like any
    //    other (TASK-24 M4; the comment here used to claim the opposite).
    final horizon = _horizonEvents(
      snapshot,
      reconciliation,
      targetMonth,
      referenceNow,
    );
    final candidateEvents = horizon.events;
    final riskDecisionMap = _buildDecisionMap(snapshot.riskDecisions);
    final hardEvents = <ForecastEvent>[];
    final riskLines = <ForecastLine>[];
    // Every candidate the user has ruled on, so the ruling can be reversed.
    // Both branches below used to be terminal: a dismissed candidate reached no
    // collection at all, and a confirmed one landed in the hard lines, which
    // render without controls (TASK-40).
    final decidedLines = <ForecastDecidedLine>[];
    for (final event in candidateEvents) {
      final monthKey = _monthKey(event.date);
      final decision = riskDecisionMap['${event.ownerKey}:$monthKey'];

      if (decision?.status == ForecastRiskDecisionStatus.dismissed) {
        // Report it before dropping it. The override is deliberately NOT
        // applied: it never reached the ledger either, so echoing it back
        // would show the user an amount nothing ever used.
        decidedLines.add(
          ForecastDecidedLine(
            line: _decidedLine(event, ForecastLineStatus.review),
            status: ForecastRiskDecisionStatus.dismissed,
          ),
        );
        continue; // dismissed — stays out of the plan
      }

      if (_isHard(event, decision)) {
        final resolved = _applyOverride(event, decision);
        hardEvents.add(resolved);
        // Only a decision earns an undo. An event that is hard on its own
        // confidence has nothing for the user to reverse.
        if (decision?.status == ForecastRiskDecisionStatus.confirmed) {
          decidedLines.add(
            ForecastDecidedLine(
              line: _decidedLine(resolved, ForecastLineStatus.projected),
              status: ForecastRiskDecisionStatus.confirmed,
            ),
          );
        }
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
            direction: event.direction,
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
      coverageLines: [
        ...reconciliation.coverageLines,
        ..._retiredCoverage(snapshot.obligations),
      ],
      horizonCoverageLines: _mergeHorizonCoverage(
        _discretionaryCoverage(snapshot, targetMonth, hardEvents),
        horizon.ambiguity,
      ),
      now: referenceNow,
    );
    final month0 = months.first;

    // 4. Derive the headline drivers.
    final salaryMissing = _isSalaryMissing(state, snapshot, month0);
    // An anchor the app has never observed is provisional whatever its date:
    // the fabricated fallback is stamped with the start of the target month,
    // which reads as `current` for the first six days of every month (TASK-22).
    final isProvisional =
        !anchor.hasEvidence || month0.anchorFreshness == AnchorFreshness.stale;
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
      salaryMissing: salaryMissing,
      isSeasonalBufferShortfall: seasonalBuffer,
      salary: salaryStrip,
      lines: reconciliation.lines,
      coverageLines: month0.coverageLines,
      forwardEarmarks: forwardEarmarks,
      riskLines: List.unmodifiable(riskLines),
      decidedLines: List.unmodifiable(decidedLines),
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
          hasEvidence: false,
        );
  }

  /// A user-entered current balance is treated as observed at the start of
  /// today: it is the freshest ground truth and wins over an older SMS balance,
  /// but on the same calendar day the SMS bank balance wins (AnchorSelector's
  /// tie rule / spec "positive bank evidence").
  BalanceAnchor? _manualAnchor(AppState state, DateTime now) {
    // MoneyParser, not `double.tryParse`: Indian digit grouping ("1,20,000") is
    // how a user actually types a balance and a double drops the anchor
    // entirely, while a double multiply loses a paise on inputs like
    // "40000.005" and accepts "1e9" as a billion rupees (TASK-22).
    final paise = MoneyParser.tryParseRupeesToPaise(state.currentBalance);
    if (paise == null || paise <= 0) return null;
    return BalanceAnchor(
      amountPaise: paise,
      asOf: DateTime(now.year, now.month, now.day),
      source: BalanceAnchorSource.manualUserEntry,
    );
  }

  // ---- horizon events -----------------------------------------------------

  ({List<ForecastEvent> events, Map<int, List<ForecastCoverageLine>> ambiguity})
  _horizonEvents(
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

    // Build identity-based dedup keys from future obligation events, on the
    // canonical dedupeKey + month.
    final futureIdentityKeys = <String>{
      for (final e in futureObligationEvents)
        if (e.obligationDedupeKey != null)
          '${e.obligationDedupeKey}:${_monthKey(e.date)}',
    };

    // Project confirmed active obligations across future offsets 1..11 so they
    // appear as hard canonical events throughout the 12-month horizon. The
    // index records what each projection *is* — category included — so a
    // detected commitment can be joined to it without relying on the merchant
    // string matching character for character (TASK-23).
    final projectedObligations = <_HorizonObligation>[
      // A future reconciliation item carries no category, so a commitment can
      // only ever join it by label. Named limitation, not an oversight.
      for (final e in futureObligationEvents) _HorizonObligation.fromEvent(e),
    ];
    final canonicalEvents = _projectCanonicalObligations(
      snapshot.obligations,
      targetMonth,
      futureIdentityKeys,
      projectedObligations,
    );

    final ambiguity = <int, List<ForecastCoverageLine>>{};
    for (var offset = 1; offset < kForecastHorizonMonths; offset++) {
      final month = DateTime(targetMonth.year, targetMonth.month + offset);
      for (final commitment in snapshot.commitments) {
        if (!_cadenceHitsMonth(commitment, month)) continue;
        final verdict = _commitmentSuppression(
          commitment,
          month,
          projectedObligations,
        );
        if (verdict.suppressed) {
          final line = verdict.line;
          if (line != null) {
            (ambiguity[offset] ??= <ForecastCoverageLine>[]).add(line);
          }
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
      events.addAll(_seasonalEvents(snapshot, month, offset));
    }

    // Add future obligation events after projected commitments so they are
    // included in the candidate horizon for risk partitioning.
    events.addAll(futureObligationEvents);

    // Add canonical obligation projections — these are user-confirmed and will
    // be partitioned as hard by _isHard.
    events.addAll(canonicalEvents);

    return (events: events, ambiguity: ambiguity);
  }

  /// One line per obligation a scan has retired, so a commitment dropping out
  /// of the forecast is visible rather than silent.
  ///
  /// Dismissed rows are excluded: the user already said they did not want it,
  /// and re-surfacing it as something needing attention would undo that.
  static List<ForecastCoverageLine> _retiredCoverage(
    List<ObligationRecord> obligations,
  ) => [
    for (final obl in obligations)
      if (obl.isRetired &&
          obl.reviewStatus != ObligationReviewStatus.dismissed)
        ForecastCoverageLine(
          label: '${obl.merchant} is no longer detected',
          reason: CoverageReason.retiredObligation,
          action: CoverageAction.review,
          confidence: obl.confidence,
          amountPaise: obl.amountPaise,
          ownerKey: 'retired:${obl.dedupeKey}',
        ),
  ];

  static Map<int, List<ForecastCoverageLine>> _mergeHorizonCoverage(
    Map<int, List<ForecastCoverageLine>> a,
    Map<int, List<ForecastCoverageLine>> b,
  ) {
    if (b.isEmpty) return a;
    final merged = <int, List<ForecastCoverageLine>>{
      for (final entry in a.entries) entry.key: [...entry.value],
    };
    for (final entry in b.entries) {
      (merged[entry.key] ??= <ForecastCoverageLine>[]).addAll(entry.value);
    }
    return merged;
  }

  /// A `discretionaryNotModelled` line for every horizon month whose everyday
  /// spending never reached the ledger.
  ///
  /// Two ways that happens, and both must be named: there is no seasonal
  /// estimate for the month at all, or there is one but it was too weak to
  /// clear [kReserveHardConfidence] and was partitioned into the risk lines.
  /// Either way the month models fixed costs against full salary, and a surplus
  /// that omits groceries is exactly the false-safe reading the spec forbids.
  /// When an estimate exists the line carries its amount, so the omission is
  /// quantified rather than merely flagged.
  Map<int, List<ForecastCoverageLine>> _discretionaryCoverage(
    SmsAnalysisSnapshot snapshot,
    DateTime targetMonth,
    List<ForecastEvent> hardEvents,
  ) {
    final modelledMonths = <String>{
      for (final event in hardEvents)
        if (event.source == ForecastEventSource.seasonal) _monthKey(event.date),
    };

    final lines = <int, List<ForecastCoverageLine>>{};
    for (var offset = 0; offset < kForecastHorizonMonths; offset++) {
      final month = DateTime(targetMonth.year, targetMonth.month + offset);
      if (modelledMonths.contains(_monthKey(month))) continue;

      final estimate = _seasonalFor(snapshot, offset);
      final total = estimate?.totalAmountPaise ?? 0;
      lines[offset] = [
        ForecastCoverageLine(
          label: 'Everyday spending not included',
          reason: CoverageReason.discretionaryNotModelled,
          action: CoverageAction.review,
          confidence: 0.3,
          amountPaise: total > 0 ? total : null,
          ownerKey: 'seasonal:${_monthKey(month)}',
        ),
      ];
    }
    return lines;
  }

  /// This future month's estimated everyday spending, one event per category.
  ///
  /// The target month gets its seasonal estimate through the reconciliation
  /// engine, which nets it against month-to-date spend and spreads the residual
  /// over the days still ahead (TASK-16). A future month has no month-to-date
  /// spend, so it takes the full estimate — and no intra-month timing evidence
  /// either, so it is dated on the last day rather than spread across ~30 days
  /// per category, which would multiply ledger lines by an order of magnitude
  /// for precision the estimate does not contain.
  List<ForecastEvent> _seasonalEvents(
    SmsAnalysisSnapshot snapshot,
    DateTime month,
    int offset,
  ) {
    final estimate = _seasonalFor(snapshot, offset);
    if (estimate == null) return const [];
    final lastDay = DateTime(month.year, month.month + 1, 0).day;
    return [
      for (final category in estimate.byCategory.values)
        if (category.amountPaise > 0)
          ForecastEvent(
            date: DateTime(month.year, month.month, lastDay),
            amountPaise: category.amountPaise,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.seasonal,
            ownerKey: 'seasonal:${category.categoryKey}',
            label: _titleCase(category.categoryKey),
            confidence: category.confidence,
          ),
    ];
  }

  static SeasonalEstimate? _seasonalFor(SmsAnalysisSnapshot snapshot, int offset) {
    final horizon = snapshot.horizonSeasonal;
    if (offset < 0 || offset >= horizon.length) return null;
    return horizon[offset];
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
    List<_HorizonObligation> index,
  ) {
    final events = <ForecastEvent>[];
    // Track keys we project to avoid duplicate projection across obligations
    // with the same label but different identity.
    final projectedKeys = <String>{};

    for (final obl in obligations) {
      // Must be confirmed and active.
      if (obl.reviewStatus == ObligationReviewStatus.dismissed) continue;
      // Retired: a scan established that nothing derives this key any more, so
      // projecting it would double-count against the row that replaced it. It
      // is named in a coverage line rather than dropped in silence — see
      // `_retiredCoverage` (TASK-37).
      if (obl.isRetired) continue;
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
        index.add(
          _HorizonObligation(
            label: obl.merchant,
            labelKey: _normLabel(obl.merchant),
            categoryKey: obl.categoryKey,
            monthKey: _monthKey(month),
            amountPaise: amount,
            direction: LedgerDirection.outflow,
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

  /// Render an event as the line shown beside its undo control.
  static ForecastLine _decidedLine(
    ForecastEvent event,
    ForecastLineStatus status,
  ) => ForecastLine(
    label: event.label,
    amountPaise: event.amountPaise,
    source: event.source,
    date: event.date,
    ownerKey: event.ownerKey,
    status: status,
    confidence: event.confidence,
    direction: event.direction,
    isUserConfirmed: event.isUserConfirmed,
    obligationDedupeKey: event.obligationDedupeKey,
  );

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
  ///
  /// Case, spacing and punctuation are all noise here: an SMS-detected
  /// commitment carries `merchantNorm` ("actfibernet") while a Gmail obligation
  /// carries the merchant as written ("ACT Fibernet"). Trim-and-lowercase alone
  /// left those two spellings of one bill projecting into every future month
  /// (TASK-23).
  static String _normLabel(String label) =>
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

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

  /// Whether a detected commitment is already carried by an obligation this
  /// month, and how sure the join is.
  ///
  /// The spec's join order is reference id, then cadence, then an amount
  /// window — merchant text last, because SMS merchant extraction is weak.
  /// Every candidate here has already passed cadence (it is being projected
  /// into this month) and the amount window; what remains is deciding whether
  /// two differently-spelled payees are one payee.
  _SuppressionVerdict _commitmentSuppression(
    RecurringCommitment commitment,
    DateTime month,
    List<_HorizonObligation> projected,
  ) {
    final normLabel = _normLabel(commitment.merchantNorm);
    final monthStr = _monthKey(month);
    const direction = LedgerDirection.outflow; // commitments are always outflow

    _HorizonObligation? ambiguous;
    for (final obligation in projected) {
      if (obligation.direction != direction) continue;
      if (obligation.monthKey != monthStr) continue;
      if (!_withinRecurringJitter(
        commitment.amountPaise,
        obligation.amountPaise,
      )) {
        continue;
      }
      // Same payee once spelling is discounted: an unambiguous duplicate.
      // An empty key is not an identity — a label of nothing but punctuation
      // normalises to "" and would otherwise make every such payee the same
      // payee, which is the ownerless-key grouping failure TASK-31 and TASK-33
      // found in the parser.
      if (normLabel.isNotEmpty && obligation.labelKey == normLabel) {
        return const _SuppressionVerdict.confident();
      }
      // Different payee text, same category, amount and month. That is real
      // ambiguity, and the spec routes ambiguity to review. Projecting both
      // would double-count the rupee; dropping it unnamed would make it vanish.
      // So it is carried once and named (TASK-23).
      if (obligation.categoryKey != null &&
          obligation.categoryKey == commitment.categoryKey) {
        ambiguous ??= obligation;
      }
    }
    if (ambiguous != null) {
      return _SuppressionVerdict.ambiguous(
        commitmentLabel: _titleCase(commitment.merchantNorm),
        obligationLabel: ambiguous.label,
        ownerKey: 'commitment:${commitment.merchantNorm}',
        amountPaise: commitment.amountPaise,
      );
    }
    return const _SuppressionVerdict.none();
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

  /// Whether the in-month low is driven purely by *estimated* everyday spending
  /// rather than by a dated bill — the difference between "your buffer looks
  /// thin" and "you owe this on the 5th".
  ///
  /// This used to demand `confidence < kSeasonalBufferConfidenceThreshold`
  /// (0.5) as well, which contradicted `_isHard`: nothing below
  /// [kReserveHardConfidence] (0.8) is ever admitted to the ledger, so no event
  /// in [ForecastMonthResult.events] could satisfy both. The headline was
  /// unreachable except through a risk the user had explicitly confirmed, which
  /// is backwards. The threshold has been deleted rather than worked around —
  /// admitting sub-0.5 events to the ledger would break the rule that weak
  /// candidates may not create a false shortfall. Being a seasonal estimate is
  /// itself the softness the headline is reporting (TASK-23).
  bool _isSeasonalBufferShortfall(ForecastMonthResult month0) {
    if (month0.minimumBalancePaise >= 0) return false;
    final minDay = _dayOnly(month0.minimumBalanceDate);
    final driving = month0.events.where(
      (e) =>
          e.direction == LedgerDirection.outflow && _dayOnly(e.date) == minDay,
    );
    return driving.isNotEmpty &&
        driving.every((e) => e.source == ForecastEventSource.seasonal);
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
      expectedSalaryPaise: expected,
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

/// An obligation already projected into a horizon month, carrying enough
/// identity to join a detected recurring commitment to it without relying on
/// the merchant string matching character for character (TASK-23).
class _HorizonObligation {
  const _HorizonObligation({
    required this.label,
    required this.labelKey,
    required this.monthKey,
    required this.amountPaise,
    required this.direction,
    this.categoryKey,
  });

  /// A future reconciliation item has no category on it, so a commitment can
  /// only ever join one of these by label.
  factory _HorizonObligation.fromEvent(ForecastEvent event) =>
      _HorizonObligation(
        label: event.label,
        labelKey: ForecastAdapter._normLabel(event.label),
        monthKey: ForecastAdapter._monthKey(event.date),
        amountPaise: event.amountPaise,
        direction: event.direction,
      );

  final String label;
  final String labelKey;
  final String? categoryKey;
  final String monthKey;
  final int amountPaise;
  final LedgerDirection direction;
}

/// Whether a detected commitment is already carried by a projected obligation,
/// and — when the join was ambiguous — the coverage line that names it.
class _SuppressionVerdict {
  const _SuppressionVerdict.none() : suppressed = false, line = null;

  const _SuppressionVerdict.confident() : suppressed = true, line = null;

  _SuppressionVerdict.ambiguous({
    required String commitmentLabel,
    required String obligationLabel,
    required String ownerKey,
    required int amountPaise,
  }) : suppressed = true,
       line = ForecastCoverageLine(
         label: '"$commitmentLabel" looks like the same commitment as '
             '"$obligationLabel" — counted once',
         reason: CoverageReason.duplicateSuppressed,
         action: CoverageAction.review,
         confidence: 0.5,
         amountPaise: amountPaise,
         ownerKey: ownerKey,
       );

  final bool suppressed;
  final ForecastCoverageLine? line;
}
