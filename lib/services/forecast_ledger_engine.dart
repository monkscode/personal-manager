import '../data/forecast_models.dart';

class ForecastLedgerEngine {
  const ForecastLedgerEngine();

  /// Opening-line confidence for a projected carry-forward month decays with the
  /// number of months projected past the real anchor:
  /// `max(_carryForwardMinConfidence, _carryForwardBaseConfidence -
  /// _carryForwardDecayPerMonth * offset)`.
  static const _carryForwardBaseConfidence = 0.9;
  static const _carryForwardDecayPerMonth = 0.1;
  static const _carryForwardMinConfidence = 0.2;

  /// Opening confidence for a month that opens on a fabricated anchor. There is
  /// no evidence to decay from, so it does not decay — it is zero at every
  /// offset (TASK-22).
  static const _noEvidenceConfidence = 0.0;

  List<ForecastMonthResult> buildRollingMonths({
    required DateTime firstMonth,
    required int monthCount,
    required BalanceAnchor anchor,
    required List<ForecastEvent> events,
    List<ForecastCoverageLine> coverageLines = const [],
    Map<int, List<ForecastCoverageLine>> horizonCoverageLines = const {},
    DateTime? now,
  }) {
    if (monthCount < 1) {
      throw ArgumentError.value(monthCount, 'monthCount', 'Must be at least 1');
    }

    final results = <ForecastMonthResult>[];
    var openingAnchor = anchor;
    for (var offset = 0; offset < monthCount; offset++) {
      final targetMonth = DateTime(firstMonth.year, firstMonth.month + offset);
      final result = buildMonth(
        targetMonth: targetMonth,
        anchor: openingAnchor,
        events: events,
        // [coverageLines] describe the target month's reconciliation and belong
        // to offset 0 alone. [horizonCoverageLines] is the per-month channel
        // future months previously had no access to at all, which is why an
        // omission in month 7 could not be reported anywhere (TASK-21).
        coverageLines: [
          if (offset == 0) ...coverageLines,
          ...?horizonCoverageLines[offset],
        ],
        offset: offset,
        now: now,
      );
      results.add(result);

      final nextMonth = DateTime(
        firstMonth.year,
        firstMonth.month + offset + 1,
      );
      openingAnchor = BalanceAnchor(
        amountPaise: result.closingBalancePaise,
        asOf: nextMonth.subtract(const Duration(microseconds: 1)),
        accountLast4: anchor.accountLast4,
        source: BalanceAnchorSource.projectedCarryForward,
        // A close projected from an evidence-free opening is no more evidenced
        // than the opening was.
        hasEvidence: anchor.hasEvidence,
      );
    }
    return List.unmodifiable(results);
  }

  ForecastMonthResult buildMonth({
    required DateTime targetMonth,
    required BalanceAnchor anchor,
    required List<ForecastEvent> events,
    List<ForecastCoverageLine> coverageLines = const [],
    int offset = 0,
    DateTime? now,
  }) {
    final referenceNow = now ?? DateTime.now();
    final monthStart = DateTime(targetMonth.year, targetMonth.month);
    final openingDate = _sameMonth(anchor.asOf, monthStart)
        ? anchor.asOf
        : monthStart;
    final anchorFreshness = anchor.freshnessAsOf(referenceNow);
    // A projected carry-forward opening is not a live SMS reading: its trust
    // decays with distance from the real anchor and it never emits the stale
    // coverage line (a projection is not a stale balance to reconfirm).
    final isProjection =
        anchor.source == BalanceAnchorSource.projectedCarryForward;
    // A fabricated anchor is not a carry-forward from anything: it must not
    // borrow the carry-forward's 0.9 (TASK-22).
    final openingConfidence = !anchor.hasEvidence
        ? _noEvidenceConfidence
        : isProjection
        ? _carryForwardConfidence(offset)
        : switch (anchorFreshness) {
            AnchorFreshness.current => 1.0,
            AnchorFreshness.amber => 0.7,
            AnchorFreshness.stale => 0.3,
          };
    final sortedEvents =
        events
            .where((event) => _isAppliedEvent(event, targetMonth, anchor))
            .toList()
          ..sort(_compareEvents);
    final alreadyInAnchor =
        events
            .where((event) => _isAlreadyInAnchor(event, targetMonth, anchor))
            .toList()
          ..sort(_compareEvents);

    var balance = anchor.amountPaise;
    var minimumBalance = balance;
    var minimumDate = openingDate;
    final lines = <ForecastLine>[
      ForecastLine(
        label: 'Opening balance',
        amountPaise: anchor.amountPaise,
        source: ForecastEventSource.currentActual,
        date: openingDate,
        ownerKey: 'anchor:${anchor.accountLast4 ?? 'primary'}',
        status: ForecastLineStatus.opening,
        confidence: openingConfidence,
      ),
      for (final event in alreadyInAnchor)
        ForecastLine(
          label: event.label,
          amountPaise: event.amountPaise,
          source: event.source,
          date: event.date,
          ownerKey: event.ownerKey,
          status: ForecastLineStatus.alreadyInAnchor,
          confidence: event.confidence,
          note: 'Already reflected in the balance anchor.',
        ),
    ];

    for (final event in sortedEvents) {
      balance = switch (event.direction) {
        LedgerDirection.inflow => balance + event.amountPaise,
        LedgerDirection.outflow => balance - event.amountPaise,
      };
      lines.add(
        ForecastLine(
          label: event.label,
          amountPaise: event.amountPaise,
          source: event.source,
          date: event.date,
          ownerKey: event.ownerKey,
          status: ForecastLineStatus.projected,
          confidence: event.confidence,
        ),
      );
      if (balance < minimumBalance) {
        minimumBalance = balance;
        minimumDate = DateTime(
          event.date.year,
          event.date.month,
          event.date.day,
        );
      }
    }

    final resolvedCoverageLines = [
      if (!anchor.hasEvidence)
        ForecastCoverageLine(
          label: 'No balance reading yet',
          reason: CoverageReason.noBalanceEvidence,
          action: CoverageAction.confirmBalance,
          confidence: 1,
          ownerKey: 'anchor:${anchor.accountLast4 ?? 'primary'}',
        )
      else if (!isProjection && anchorFreshness == AnchorFreshness.stale)
        ForecastCoverageLine(
          label: 'Balance anchor is stale',
          reason: CoverageReason.staleAnchor,
          action: CoverageAction.confirmBalance,
          confidence: 0.3,
          ownerKey: 'anchor:${anchor.accountLast4 ?? 'primary'}',
        ),
      ...coverageLines,
    ];

    return ForecastMonthResult(
      openingBalancePaise: anchor.amountPaise,
      closingBalancePaise: balance,
      minimumBalancePaise: minimumBalance,
      minimumBalanceDate: minimumDate,
      shortfallPaise: minimumBalance < 0 ? -minimumBalance : 0,
      events: List.unmodifiable(sortedEvents),
      coverageLines: List.unmodifiable(resolvedCoverageLines),
      anchor: anchor,
      anchorFreshness: anchorFreshness,
      lines: List.unmodifiable(lines),
    );
  }

  static bool _isAppliedEvent(
    ForecastEvent event,
    DateTime targetMonth,
    BalanceAnchor anchor,
  ) {
    if (!_sameMonth(event.date, targetMonth)) return false;
    // A balance that was never read reflects nothing, so every event in the
    // month is still ahead of it. Without this, the fabricated anchor — dated
    // at the start of the target month — swallows every first-of-month rent,
    // EMI and salary into "already in the anchor" and they never move the
    // ledger at all (TASK-22).
    if (!anchor.hasEvidence) return true;
    return event.date.isAfter(anchor.asOf);
  }

  static bool _isAlreadyInAnchor(
    ForecastEvent event,
    DateTime targetMonth,
    BalanceAnchor anchor,
  ) {
    if (!_sameMonth(event.date, targetMonth)) return false;
    if (!anchor.hasEvidence) return false;
    return !event.date.isAfter(anchor.asOf);
  }

  static double _carryForwardConfidence(int offset) {
    final decayed =
        _carryForwardBaseConfidence - _carryForwardDecayPerMonth * offset;
    return decayed < _carryForwardMinConfidence
        ? _carryForwardMinConfidence
        : decayed;
  }

  static int _compareEvents(ForecastEvent a, ForecastEvent b) {
    final dateCompare = a.date.compareTo(b.date);
    if (dateCompare != 0) return dateCompare;
    return _directionSort(a.direction).compareTo(_directionSort(b.direction));
  }

  static int _directionSort(LedgerDirection direction) => switch (direction) {
    LedgerDirection.outflow => 0,
    LedgerDirection.inflow => 1,
  };

  static bool _sameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;
}
