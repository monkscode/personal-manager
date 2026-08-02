import '../data/forecast_models.dart';
import '../data/sms_models.dart';

class ForecastReconciliationEngine {
  const ForecastReconciliationEngine();

  static const int materialCashThresholdPaise = 500000;

  ForecastReconciliationResult reconcileMonth({
    required DateTime targetMonth,
    required BalanceAnchor anchor,
    required List<ReconciliationItem> items,
    DateTime? now,
  }) {
    _assertUniqueIds(items);
    final referenceNow = now ?? DateTime.now();
    final bridgeTargetIds = {
      for (final item in items)
        if (item.transferBridgeToId != null) item.transferBridgeToId!,
    };
    final atmTotalPaise = items
        .where(
          (item) =>
              item.owner == ForecastOwner.atmCash &&
              item.amountPaise != null &&
              item.eventDate != null &&
              _sameMonth(item.eventDate!, targetMonth) &&
              item.eventDate!.isAfter(anchor.asOf),
        )
        .fold<int>(0, (sum, item) => sum + item.amountPaise!);

    final groups = <String, List<ReconciliationItem>>{};
    for (final item in items) {
      final groupKey = _groupKey(item, bridgeTargetIds);
      groups.putIfAbsent(groupKey, () => []).add(item);
    }

    final events = <ForecastEvent>[];
    final coverageLines = <ForecastCoverageLine>[];
    final lines = <ForecastLine>[];
    final assignments = <OwnedForecastItem>[];

    for (final group in groups.values) {
      final ordered = [...group]..sort(_compareOwnerPrecedence);
      if (_hasUnresolvableTie(ordered)) {
        for (final item in ordered) {
          _assignCoverage(
            item,
            CoverageReason.reviewNeeded,
            CoverageAction.review,
            ForecastLineStatus.review,
            CoverageBucket.reviewPending,
            coverageLines,
            lines,
            assignments,
          );
        }
        continue;
      }

      final winners = _chooseWinners(ordered);
      final winnerIds = {for (final winner in winners) winner.id};
      for (final winner in winners) {
        _applyWinner(
          winner,
          targetMonth,
          anchor,
          referenceNow,
          atmTotalPaise,
          events,
          coverageLines,
          lines,
          assignments,
        );
      }
      for (final duplicate in ordered.where(
        (item) => !winnerIds.contains(item.id),
      )) {
        _assignReconciledDuplicate(
          duplicate,
          bridgeTargetIds,
          coverageLines,
          assignments,
        );
      }
    }

    _assertCompleteAssignments(items, assignments);

    events.sort((a, b) => a.date.compareTo(b.date));
    return ForecastReconciliationResult(
      events: List.unmodifiable(events),
      coverageLines: List.unmodifiable(coverageLines),
      lines: List.unmodifiable(lines),
      assignments: List.unmodifiable(assignments),
    );
  }

  void _applyWinner(
    ReconciliationItem item,
    DateTime targetMonth,
    BalanceAnchor anchor,
    DateTime now,
    int atmTotalPaise,
    List<ForecastEvent> events,
    List<ForecastCoverageLine> coverageLines,
    List<ForecastLine> lines,
    List<OwnedForecastItem> assignments,
  ) {
    if (item.amountStatus == AmountStatus.missing || item.amountPaise == null) {
      _assignCoverage(
        item,
        CoverageReason.reviewNeeded,
        CoverageAction.review,
        ForecastLineStatus.review,
        CoverageBucket.reviewPending,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.needsAttributionReview) {
      _assignCoverage(
        item,
        CoverageReason.reviewNeeded,
        item.owner == ForecastOwner.cardPayment
            ? CoverageAction.setCardCycle
            : CoverageAction.review,
        ForecastLineStatus.review,
        CoverageBucket.reviewPending,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.cardPurchase) {
      _assignCoverage(
        item,
        CoverageReason.cardCycleOnly,
        item.cardCycleKey == null
            ? CoverageAction.setCardCycle
            : CoverageAction.none,
        ForecastLineStatus.reconciled,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.cardStatement &&
        item.paymentStatus == ReconciliationPaymentStatus.partial) {
      _assignCoverage(
        item,
        CoverageReason.partialCardOutstanding,
        CoverageAction.review,
        ForecastLineStatus.coverage,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.paymentStatus == ReconciliationPaymentStatus.possiblyPaid) {
      _assignCoverage(
        item,
        CoverageReason.possiblyAlreadyPaid,
        CoverageAction.markUnpaid,
        ForecastLineStatus.review,
        CoverageBucket.reviewPending,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.refund &&
        item.instrument == ReconciliationInstrument.card) {
      _assignCoverage(
        item,
        CoverageReason.cardCycleOnly,
        CoverageAction.none,
        ForecastLineStatus.reconciled,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.recurringP2pOutflow &&
        item.userCadenceStatus != UserCadenceStatus.userConfirmed) {
      _assignCoverage(
        item,
        CoverageReason.p2pConfirmationRequired,
        CoverageAction.dismiss,
        ForecastLineStatus.coverage,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.p2pIncomeCandidate &&
        item.userCadenceStatus != UserCadenceStatus.userConfirmed) {
      _assignCoverage(
        item,
        CoverageReason.reviewNeeded,
        CoverageAction.confirmIncome,
        ForecastLineStatus.review,
        CoverageBucket.reviewPending,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    final eventDate = item.eventDate;
    if (eventDate == null) {
      _assignCoverage(
        item,
        CoverageReason.unscheduledObligation,
        CoverageAction.setDueMonth,
        ForecastLineStatus.coverage,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (!_sameMonth(eventDate, targetMonth)) {
      _assignCoverage(
        item,
        CoverageReason.futureEarmark,
        CoverageAction.none,
        ForecastLineStatus.coverage,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.owner == ForecastOwner.nonPrimaryAccountObligation &&
        item.accountScope == AccountScope.secondary) {
      _assignCoverage(
        item,
        CoverageReason.outOfPrimaryScope,
        CoverageAction.linkAccount,
        ForecastLineStatus.coverage,
        CoverageBucket.quantifiedExcluded,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (item.actualDate == null &&
        item.dueDate != null &&
        !item.dueDate!.isAfter(anchor.asOf) &&
        item.paymentStatus == ReconciliationPaymentStatus.unpaid) {
      _assignCoverage(
        item,
        CoverageReason.possiblyAlreadyPaid,
        CoverageAction.markUnpaid,
        ForecastLineStatus.review,
        CoverageBucket.reviewPending,
        coverageLines,
        lines,
        assignments,
      );
      return;
    }

    if (!eventDate.isAfter(anchor.asOf)) {
      assignments.add(
        OwnedForecastItem(
          itemId: item.id,
          ownerKey: item.ownerKey,
          owner: item.owner,
          coverageBucket: CoverageBucket.anchorIncluded,
          status: ForecastLineStatus.alreadyInAnchor,
          amountPaise: item.amountPaise,
        ),
      );
      lines.add(
        ForecastLine(
          label: item.label,
          amountPaise: item.amountPaise!,
          source: _eventSourceFor(item.owner),
          date: eventDate,
          ownerKey: item.ownerKey,
          status: ForecastLineStatus.alreadyInAnchor,
          confidence: item.confidence,
        ),
      );
      return;
    }

    if (item.accountScope == AccountScope.unknown) {
      _addCoverageLineOnly(
        item,
        CoverageReason.accountHintUncertain,
        CoverageAction.linkAccount,
        coverageLines,
      );
    }

    if (item.owner == ForecastOwner.atmCash &&
        atmTotalPaise >= materialCashThresholdPaise) {
      _addCoverageLineOnly(
        item,
        CoverageReason.untrackedCash,
        CoverageAction.none,
        coverageLines,
      );
    }

    assignments.add(
      OwnedForecastItem(
        itemId: item.id,
        ownerKey: item.ownerKey,
        owner: item.owner,
        coverageBucket: CoverageBucket.datedEvent,
        status: _statusForDatedItem(item, now),
        amountPaise: item.amountPaise,
      ),
    );
    events.add(
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
    lines.add(
      ForecastLine(
        label: item.label,
        amountPaise: item.amountPaise!,
        source: _eventSourceFor(item.owner),
        date: eventDate,
        ownerKey: item.ownerKey,
        status: _statusForDatedItem(item, now),
        confidence: item.confidence,
        isUserConfirmed: item.isUserConfirmed,
        obligationDedupeKey: item.obligationDedupeKey,
      ),
    );
  }

  void _assignReconciledDuplicate(
    ReconciliationItem item,
    Set<String> bridgeTargetIds,
    List<ForecastCoverageLine> coverageLines,
    List<OwnedForecastItem> assignments,
  ) {
    assignments.add(
      OwnedForecastItem(
        itemId: item.id,
        ownerKey: item.ownerKey,
        owner: item.owner,
        coverageBucket: CoverageBucket.quantifiedExcluded,
        status: ForecastLineStatus.reconciled,
        amountPaise: item.amountPaise,
      ),
    );
    if (item.owner == ForecastOwner.nonPrimaryAccountObligation &&
        item.accountScope == AccountScope.secondary) {
      _addCoverageLineOnly(
        item,
        CoverageReason.outOfPrimaryScope,
        CoverageAction.linkAccount,
        coverageLines,
      );
      return;
    }
    if (bridgeTargetIds.contains(item.id)) {
      _addCoverageLineOnly(
        item,
        CoverageReason.transferBridgeReview,
        CoverageAction.review,
        coverageLines,
      );
      return;
    }
    // Unconditional: a suppressed duplicate leaves the ledger, so without a
    // line naming it the user cannot tell it from a rupee that vanished.
    _addCoverageLineOnly(
      item,
      CoverageReason.duplicateSuppressed,
      CoverageAction.none,
      coverageLines,
    );
  }

  void _assignCoverage(
    ReconciliationItem item,
    CoverageReason reason,
    CoverageAction action,
    ForecastLineStatus status,
    CoverageBucket bucket,
    List<ForecastCoverageLine> coverageLines,
    List<ForecastLine> lines,
    List<OwnedForecastItem> assignments,
  ) {
    assignments.add(
      OwnedForecastItem(
        itemId: item.id,
        ownerKey: item.ownerKey,
        owner: item.owner,
        coverageBucket: bucket,
        status: status,
        amountPaise: item.amountPaise,
      ),
    );
    coverageLines.add(
      ForecastCoverageLine(
        label: item.label,
        amountPaise: item.amountPaise,
        reason: reason,
        action: action,
        confidence: item.confidence,
        ownerKey: item.ownerKey,
      ),
    );
    if (item.amountPaise != null) {
      lines.add(
        ForecastLine(
          label: item.label,
          amountPaise: item.amountPaise!,
          source: _eventSourceFor(item.owner),
          date: item.eventDate,
          ownerKey: item.ownerKey,
          status: status,
          confidence: item.confidence,
        ),
      );
    }
  }

  void _addCoverageLineOnly(
    ReconciliationItem item,
    CoverageReason reason,
    CoverageAction action,
    List<ForecastCoverageLine> coverageLines,
  ) {
    coverageLines.add(
      ForecastCoverageLine(
        label: item.label,
        amountPaise: item.amountPaise,
        reason: reason,
        action: action,
        confidence: item.confidence,
        ownerKey: item.ownerKey,
      ),
    );
  }

  static void _assertUniqueIds(List<ReconciliationItem> items) {
    final ids = <String>{};
    for (final item in items) {
      if (!ids.add(item.id)) {
        throw ArgumentError.value(item.id, 'items', 'Duplicate item id');
      }
    }
  }

  static void _assertCompleteAssignments(
    List<ReconciliationItem> items,
    List<OwnedForecastItem> assignments,
  ) {
    final itemIds = {for (final item in items) item.id};
    final assignmentIds = {
      for (final assignment in assignments) assignment.itemId,
    };
    if (assignments.length != items.length ||
        assignmentIds.length != itemIds.length) {
      throw StateError(
        'Every reconciliation item must produce exactly one assignment.',
      );
    }
    if (!assignmentIds.containsAll(itemIds)) {
      throw StateError('Reconciliation assignments missing input items.');
    }
  }

  static String _groupKey(
    ReconciliationItem item,
    Set<String> bridgeTargetIds,
  ) {
    // The bridge outranks the match key: a transfer that names an obligation is
    // direct evidence about *that* obligation, whereas a match key is only a
    // merchant/cadence coincidence. Ordered the other way, any bridge target
    // carrying a match key — which real matcher output almost always does —
    // stayed in its merchant group and never met the transfer funding it.
    if (item.transferBridgeToId != null) {
      return 'bridge:${item.transferBridgeToId}';
    }
    if (bridgeTargetIds.contains(item.id)) return 'bridge:${item.id}';
    if (item.matchKey != null) return 'match:${item.matchKey}';
    if ((item.owner == ForecastOwner.cardStatement ||
            item.owner == ForecastOwner.cardPayment) &&
        item.cardCycleKey != null) {
      return 'cardCycle:${item.cardCycleKey}';
    }
    return 'item:${item.id}';
  }

  static bool _hasUnresolvableTie(List<ReconciliationItem> ordered) {
    if (ordered.length < 2) return false;
    final first = _ownerPrecedence(ordered[0].owner);
    final second = _ownerPrecedence(ordered[1].owner);
    return first == second && ordered[0].matchKey == null;
  }

  /// The members of a group whose amounts the ledger keeps. Normally one — a
  /// group exists to resolve competing *descriptions* of one rupee.
  ///
  /// Observed card payments are the exception: two payments in a cycle are two
  /// debits that already left the bank, not two estimates of one. Forecast
  /// obligations can be deduplicated; observed actuals cannot.
  static List<ReconciliationItem> _chooseWinners(
    List<ReconciliationItem> ordered,
  ) {
    final bridging = [
      for (final item in ordered)
        if (item.transferBridgeToId != null &&
            item.owner == ForecastOwner.transfer)
          item,
    ];
    // Same rule as card payments: transfers are observed debits, so two of them
    // aimed at one obligation are two real cash movements, not two accounts of
    // one. Only the obligation they fund is suppressed.
    if (bridging.isNotEmpty) return bridging;
    final payments = [
      for (final item in ordered)
        if (item.owner == ForecastOwner.cardPayment && item.actualDate != null)
          item,
    ];
    if (payments.isNotEmpty) return payments;
    return [ordered.first];
  }

  static ForecastLineStatus _statusForDatedItem(
    ReconciliationItem item,
    DateTime now,
  ) {
    if (item.actualDate != null ||
        item.paymentStatus == ReconciliationPaymentStatus.paid) {
      return ForecastLineStatus.paid;
    }
    if (item.direction == LedgerDirection.inflow) {
      return ForecastLineStatus.projected;
    }
    final dueDate = item.dueDate;
    if (dueDate == null) return ForecastLineStatus.projected;
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(dueDate.year, dueDate.month, dueDate.day);
    return dueDay.isBefore(today)
        ? ForecastLineStatus.overdue
        : ForecastLineStatus.unpaid;
  }

  static int _compareOwnerPrecedence(
    ReconciliationItem a,
    ReconciliationItem b,
  ) {
    final priority = _ownerPrecedence(
      a.owner,
    ).compareTo(_ownerPrecedence(b.owner));
    if (priority != 0) return priority;
    // Within the same owner precedence, user-confirmed items win.
    if (a.isUserConfirmed != b.isUserConfirmed) {
      return a.isUserConfirmed ? -1 : 1;
    }
    return a.id.compareTo(b.id);
  }

  static int _ownerPrecedence(ForecastOwner owner) => switch (owner) {
    ForecastOwner.gmailBill => 10,
    ForecastOwner.configuredContribution => 20,
    ForecastOwner.recurringCommitment => 30,
    ForecastOwner.cardStatement => 35,
    ForecastOwner.cardPayment => 36,
    ForecastOwner.refund => 40,
    ForecastOwner.transfer || ForecastOwner.atmCash => 50,
    ForecastOwner.salary => 55,
    ForecastOwner.otherIncome => 56,
    ForecastOwner.cardPurchase => 60,
    ForecastOwner.nonPrimaryAccountObligation => 65,
    ForecastOwner.annualUnscheduled => 70,
    ForecastOwner.recurringP2pOutflow => 75,
    ForecastOwner.p2pIncomeCandidate => 80,
    ForecastOwner.discretionarySpend => 90,
  };

  static ForecastEventSource _eventSourceFor(ForecastOwner owner) =>
      switch (owner) {
        ForecastOwner.salary => ForecastEventSource.salary,
        ForecastOwner.otherIncome => ForecastEventSource.otherIncome,
        ForecastOwner.recurringCommitment ||
        ForecastOwner.recurringP2pOutflow => ForecastEventSource.recurring,
        ForecastOwner.gmailBill ||
        ForecastOwner.annualUnscheduled ||
        ForecastOwner.nonPrimaryAccountObligation =>
          ForecastEventSource.gmailBill,
        ForecastOwner.configuredContribution =>
          ForecastEventSource.configuredContribution,
        ForecastOwner.cardStatement => ForecastEventSource.cardStatement,
        ForecastOwner.cardPayment => ForecastEventSource.cardPayment,
        ForecastOwner.cardPurchase => ForecastEventSource.cardOutstanding,
        ForecastOwner.refund => ForecastEventSource.refund,
        ForecastOwner.transfer => ForecastEventSource.transfer,
        ForecastOwner.atmCash => ForecastEventSource.untrackedCash,
        ForecastOwner.discretionarySpend => ForecastEventSource.seasonal,
        ForecastOwner.p2pIncomeCandidate => ForecastEventSource.otherIncome,
      };

  static bool _sameMonth(DateTime date, DateTime month) =>
      date.year == month.year && date.month == month.month;
}
