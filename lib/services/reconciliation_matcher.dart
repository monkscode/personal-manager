import 'dart:math' as math;

import '../data/card_models.dart';
import '../data/forecast_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_models.dart';
import 'recurring_debit_detector.dart';
import 'salary_income_detector.dart';
import 'seasonal_estimator.dart';

/// A known annual heads-up line expires (requires refresh) after this many
/// months without fresh evidence (D8 spec default).
const int kAnnualHeadsUpExpiryMonths = 15;

/// Day-of-month a monthly discretionary buffer is dated on when no finer
/// allocation exists (a planning placeholder; refined by the Phase F ledger).
const int kSeasonalBufferDayOfMonth = 28;

/// Builds owned [ReconciliationItem]s by joining the Phase D producers
/// (obligations, recurring commitments, seasonal, salary, cards) against
/// observed SMS actuals (spec §7). This is the paid/unpaid detection layer: it
/// assigns every input exactly one [ForecastOwner] and a shared `matchKey`
/// wherever a join exists, so the downstream [ForecastReconciliationEngine]
/// resolves precedence without double-counting. The engine is fed unchanged.
class ReconciliationMatcher {
  const ReconciliationMatcher();

  List<ReconciliationItem> buildItems({
    required List<ParsedTxn> actuals,
    required List<ObligationRecord> obligations,
    required List<RecurringCommitment> commitments,
    required SeasonalEstimate seasonal,
    required SalaryProfile salary,
    required List<CardCycleEstimate> cards,
    required BalanceAnchor anchor,
    required DateTime targetMonth,
  }) {
    final owners = <_JoinOwner>[];
    owners.addAll(_obligationOwners(obligations, targetMonth));
    owners.addAll(_commitmentOwners(commitments, targetMonth));

    // A debit that references a known obligation is that obligation's payment,
    // never a card-bill payment (BillDesk fronts both, so the reference wins).
    final ownerRefKeys = {for (final owner in owners) ...owner.refKeys};

    // Classify actuals into their processing lanes.
    final debits = <ParsedTxn>[];
    final refunds = <ParsedTxn>[];
    final cardPayments = <ParsedTxn>[];
    final atmWithdrawals = <ParsedTxn>[];
    final transfers = <ParsedTxn>[];
    for (final txn in actuals) {
      final referencesObligation =
          txn.refNumber != null &&
          ownerRefKeys.contains(txn.refNumber) &&
          txn.direction == TransactionDirection.debit;
      if (_isRefund(txn)) {
        refunds.add(txn);
      } else if (txn.type == TxnType.atm &&
          txn.direction == TransactionDirection.debit) {
        atmWithdrawals.add(txn);
      } else if (txn.type == TxnType.transfer &&
          txn.direction == TransactionDirection.debit) {
        transfers.add(txn);
      } else if (referencesObligation) {
        debits.add(txn);
      } else if (_isCardPayment(txn)) {
        cardPayments.add(txn);
      } else if (txn.instrument == PaymentInstrument.card) {
        // Per-purchase card SMS is represented by the CardCycleEstimate, not as
        // an individual bank cash item.
        continue;
      } else if (txn.direction == TransactionDirection.debit) {
        debits.add(txn);
      }
    }

    _foldActualsIntoOwners(debits, owners, targetMonth);

    final items = <ReconciliationItem>[];
    items.addAll(owners.map((o) => o.toItem()));
    items.addAll(_cardItems(cards, cardPayments));
    final salaryItem = _salaryItem(salary, targetMonth);
    if (salaryItem != null) items.add(salaryItem);
    items.addAll(_seasonalItems(seasonal, targetMonth));
    items.addAll(_refundItems(refunds, actuals));
    items.addAll(_atmItems(atmWithdrawals));
    items.addAll(_transferItems(transfers));
    return items;
  }

  // ---- obligations --------------------------------------------------------

  List<_JoinOwner> _obligationOwners(
    List<ObligationRecord> obligations,
    DateTime targetMonth,
  ) {
    final owners = <_JoinOwner>[];
    for (final obligation in obligations) {
      if (_annualHeadsUpExpired(obligation, targetMonth)) continue;

      final dueDate =
          obligation.dueDate ??
          (obligation.dueDay != null
              ? DateTime(
                  targetMonth.year,
                  targetMonth.month,
                  obligation.dueDay!,
                )
              : null);
      final owner = _obligationOwner(obligation, dueDate);
      final matchKey = _obligationMatchKey(obligation, owner);
      final refKeys = <String>{
        if (obligation.sourceId != null) obligation.sourceId!,
        obligation.dedupeKey,
      };

      owners.add(
        _JoinOwner(
          id: 'obl:${obligation.dedupeKey}',
          label: obligation.merchant,
          owner: owner,
          direction: LedgerDirection.outflow,
          amountPaise: obligation.amountPaise,
          amountStatus: obligation.amountStatus,
          merchantNorm: obligation.merchantNorm,
          categoryKey: obligation.categoryKey,
          accountLast4: obligation.paymentAccountHintLast4,
          recurrence: obligation.recurrence,
          dueDate: dueDate,
          matchKey: matchKey,
          accountScope: obligation.paymentAccountScope,
          confidence: obligation.confidence,
          source: _sourceFor(obligation.sourceType),
          refKeys: refKeys,
          paymentStatus: obligation.paymentStatus,
          foldable:
              owner == ForecastOwner.gmailBill ||
              owner == ForecastOwner.configuredContribution ||
              owner == ForecastOwner.recurringCommitment,
          isUserConfirmed:
              obligation.reviewStatus == ObligationReviewStatus.confirmed,
          obligationDedupeKey: obligation.dedupeKey,
        ),
      );
    }
    return owners;
  }

  bool _annualHeadsUpExpired(
    ObligationRecord obligation,
    DateTime targetMonth,
  ) {
    if (obligation.recurrence != ReconciliationRecurrence.annual) return false;
    final months =
        (targetMonth.year - obligation.updatedAt.year) * 12 +
        (targetMonth.month - obligation.updatedAt.month);
    return months > kAnnualHeadsUpExpiryMonths;
  }

  ForecastOwner _obligationOwner(
    ObligationRecord obligation,
    DateTime? dueDate,
  ) {
    if (obligation.paymentAccountScope == AccountScope.secondary) {
      return ForecastOwner.nonPrimaryAccountObligation;
    }
    final periodic =
        obligation.recurrence == ReconciliationRecurrence.annual ||
        obligation.recurrence == ReconciliationRecurrence.quarterly;
    if (periodic && dueDate == null) return ForecastOwner.annualUnscheduled;
    return switch (obligation.sourceType) {
      ObligationSourceType.gmail => ForecastOwner.gmailBill,
      ObligationSourceType.manual => ForecastOwner.gmailBill,
      ObligationSourceType.configuredPlan =>
        ForecastOwner.configuredContribution,
      ObligationSourceType.smsRecurring => ForecastOwner.recurringCommitment,
    };
  }

  String? _obligationMatchKey(
    ObligationRecord obligation,
    ForecastOwner owner,
  ) {
    if (owner == ForecastOwner.configuredContribution) {
      return obligation.dedupeKey;
    }
    if (obligation.merchantNorm.isNotEmpty) {
      return 'merch:${obligation.merchantNorm}:${obligation.recurrence.name}';
    }
    return null;
  }

  // ---- commitments --------------------------------------------------------

  List<_JoinOwner> _commitmentOwners(
    List<RecurringCommitment> commitments,
    DateTime targetMonth,
  ) {
    final owners = <_JoinOwner>[];
    for (var i = 0; i < commitments.length; i++) {
      final commitment = commitments[i];
      final recurrence = _mapCadence(commitment.cadence);
      final matchKey =
          commitment.configuredPlanKey ??
          (commitment.merchantNorm.isNotEmpty
              ? 'merch:${commitment.merchantNorm}:${recurrence.name}'
              : null);
      owners.add(
        _JoinOwner(
          id: 'commit:${commitment.merchantNorm}:${commitment.amountPaise}:$i',
          label: commitment.merchantNorm.isEmpty
              ? 'Recurring debit'
              : commitment.merchantNorm,
          owner: ForecastOwner.recurringCommitment,
          direction: LedgerDirection.outflow,
          amountPaise: commitment.amountPaise,
          amountStatus: AmountStatus.known,
          merchantNorm: commitment.merchantNorm,
          categoryKey: commitment.categoryKey,
          accountLast4: null,
          recurrence: recurrence,
          dueDate: commitment.nextExpected,
          matchKey: matchKey,
          accountScope: AccountScope.primary,
          confidence: commitment.confidence,
          source: ForecastItemSource.sms,
          refKeys: const {},
          paymentStatus: ReconciliationPaymentStatus.unpaid,
          foldable: true,
        ),
      );
    }
    return owners;
  }

  ReconciliationRecurrence _mapCadence(RecurringCadence cadence) =>
      switch (cadence) {
        RecurringCadence.monthly => ReconciliationRecurrence.monthly,
        RecurringCadence.quarterly => ReconciliationRecurrence.quarterly,
        // ReconciliationRecurrence has no halfYearly; a half-yearly commitment
        // is a large periodic obligation, bucketed with annual for planning.
        RecurringCadence.halfYearly => ReconciliationRecurrence.annual,
        RecurringCadence.annual => ReconciliationRecurrence.annual,
      };

  // ---- the join -----------------------------------------------------------

  void _foldActualsIntoOwners(
    List<ParsedTxn> debits,
    List<_JoinOwner> owners,
    DateTime targetMonth,
  ) {
    final foldable = owners.where((o) => o.foldable).toList();
    for (final debit in debits) {
      final matched = [
        for (final owner in foldable)
          if (_matches(debit, owner, targetMonth)) owner,
      ];
      if (matched.isEmpty) continue;

      final distinctKeys = matched.map((o) => o.matchKey ?? o.id).toSet();
      if (distinctKeys.length == 1) {
        // Same logical obligation (possibly described by multiple sources).
        for (final owner in matched) {
          owner.actualDate ??= debit.txnDate;
          owner.paymentStatus = ReconciliationPaymentStatus.paid;
        }
      } else {
        // Genuinely ambiguous: hold every candidate for review rather than
        // silently merging or double-subtracting.
        for (final owner in matched) {
          owner.paymentStatus = ReconciliationPaymentStatus.possiblyPaid;
        }
      }
    }
  }

  bool _matches(ParsedTxn debit, _JoinOwner owner, DateTime targetMonth) {
    if (owner.amountPaise == null) return false;
    // (1) source id / reference.
    if (debit.refNumber != null && owner.refKeys.contains(debit.refNumber)) {
      return true;
    }
    if (!_withinWindow(debit.txnDate, owner.dueDate ?? targetMonth)) {
      return false;
    }
    final amountOk = _withinJitter(debit.amountPaise, owner.amountPaise!);
    if (!amountOk) return false;

    if (owner.merchantNorm.isNotEmpty) {
      // (2) normalized merchant + amount-within-jitter + date window.
      return _norm(debit.merchant ?? debit.upiVpaNorm ?? debit.sender) ==
          owner.merchantNorm;
    }
    // (3) merchant-null fallback: amount + category + account.
    final accountOk =
        owner.accountLast4 == null || debit.accountLast4 == owner.accountLast4;
    return debit.categoryKey == owner.categoryKey && accountOk;
  }

  bool _withinWindow(DateTime actual, DateTime reference) =>
      actual.year == reference.year && actual.month == reference.month;

  bool _withinJitter(int actual, int expected) {
    final tolerance = math.max(
      (expected * kRecurringAmountJitterRatio).round(),
      kRecurringAmountJitterFloorPaise,
    );
    return (actual - expected).abs() <= tolerance;
  }

  // ---- cards --------------------------------------------------------------

  List<ReconciliationItem> _cardItems(
    List<CardCycleEstimate> cards,
    List<ParsedTxn> cardPayments,
  ) {
    final items = <ReconciliationItem>[];
    for (var i = 0; i < cards.length; i++) {
      final estimate = cards[i];
      if (estimate.needsCycleSetup) {
        items.add(
          ReconciliationItem(
            id: 'card:${estimate.cardCycleKey}:$i',
            label: 'Card ${estimate.cardLast4} spend',
            amountPaise: estimate.statementEventAmountPaise,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.cardPurchase,
            source: ForecastItemSource.sms,
            instrument: ReconciliationInstrument.card,
            amountStatus: AmountStatus.estimated,
            confidence: estimate.confidence,
          ),
        );
        continue;
      }
      items.add(
        ReconciliationItem(
          id: 'card:${estimate.cardCycleKey}:$i',
          label: 'Card ${estimate.cardLast4} statement',
          amountPaise: estimate.statementEventAmountPaise,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.cardStatement,
          source: ForecastItemSource.sms,
          dueDate: estimate.dueDate,
          instrument: ReconciliationInstrument.card,
          amountStatus: estimate.statementTotalPaise != null
              ? AmountStatus.known
              : AmountStatus.estimated,
          paymentStatus: estimate.paymentStatus,
          cardCycleKey: estimate.cardCycleKey,
          confidence: estimate.confidence,
        ),
      );
    }

    for (var i = 0; i < cardPayments.length; i++) {
      final payment = cardPayments[i];
      final cycleKey = _cardCycleKeyFor(payment, cards);
      items.add(
        ReconciliationItem(
          id: 'cardpay:${payment.smsId}',
          label: 'Card bill payment',
          amountPaise: payment.amountPaise,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.cardPayment,
          source: ForecastItemSource.sms,
          actualDate: payment.txnDate,
          instrument: ReconciliationInstrument.bank,
          paymentStatus: ReconciliationPaymentStatus.paid,
          cardCycleKey: cycleKey,
          confidence: payment.confidence,
        ),
      );
    }
    return items;
  }

  /// Card-bill payments (CRED/BillDesk) hide the issuer, so match by due-window
  /// (same statement month), not merchant text (spec §7 card-bill payment rule).
  String? _cardCycleKeyFor(ParsedTxn payment, List<CardCycleEstimate> cards) {
    CardCycleEstimate? best;
    for (final estimate in cards) {
      final due = estimate.dueDate;
      if (due == null) continue;
      if (due.year == payment.txnDate.year &&
          due.month == payment.txnDate.month) {
        if (best == null || estimate.statementEventAmountPaise > 0) {
          best = estimate;
        }
      }
    }
    return best?.cardCycleKey;
  }

  // ---- salary / seasonal --------------------------------------------------

  ReconciliationItem? _salaryItem(SalaryProfile salary, DateTime targetMonth) {
    if (salary.effectiveMonthSatisfied) return null;
    final base = salary.basePaise;
    if (base == null) return null;
    if (salary.confidence == SalaryConfidence.insufficientData ||
        salary.confidence == SalaryConfidence.unknown) {
      return null;
    }
    final day = salary.expectedDay ?? 1;
    return ReconciliationItem(
      id: 'salary',
      label: 'Salary',
      amountPaise: base,
      direction: LedgerDirection.inflow,
      owner: ForecastOwner.salary,
      source: ForecastItemSource.sms,
      dueDate: DateTime(targetMonth.year, targetMonth.month, day),
      confidence: salary.confidence == SalaryConfidence.detectedStable
          ? 0.9
          : 0.6,
    );
  }

  List<ReconciliationItem> _seasonalItems(
    SeasonalEstimate seasonal,
    DateTime targetMonth,
  ) {
    final items = <ReconciliationItem>[];
    for (final entry in seasonal.byCategory.values) {
      if (entry.amountPaise <= 0) continue;
      items.add(
        ReconciliationItem(
          id: 'seasonal:${entry.categoryKey}',
          label: entry.categoryKey,
          amountPaise: entry.amountPaise,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.discretionarySpend,
          source: ForecastItemSource.estimator,
          dueDate: DateTime(
            targetMonth.year,
            targetMonth.month,
            kSeasonalBufferDayOfMonth,
          ),
          amountStatus: AmountStatus.estimated,
          confidence: entry.confidence,
        ),
      );
    }
    return items;
  }

  // ---- refunds ------------------------------------------------------------

  List<ReconciliationItem> _refundItems(
    List<ParsedTxn> refunds,
    List<ParsedTxn> actuals,
  ) {
    final debits = [
      for (final txn in actuals)
        if (txn.direction == TransactionDirection.debit) txn,
    ];
    // Cumulative refunds per original debit are capped at the original amount.
    final grouped = <String, List<ParsedTxn>>{};
    for (final refund in refunds) {
      grouped.putIfAbsent(_refundGroupKey(refund), () => []).add(refund);
    }

    final items = <ReconciliationItem>[];
    for (final entry in grouped.entries) {
      final group = [...entry.value]
        ..sort((a, b) => a.txnDate.compareTo(b.txnDate));
      final original = _findOriginalDebit(group.first, debits);
      final cap = original?.amountPaise;
      var applied = 0;
      for (final refund in group) {
        var creditable = refund.amountPaise;
        if (cap != null) {
          final remaining = math.max(0, cap - applied);
          creditable = math.min(refund.amountPaise, remaining);
        }
        if (creditable > 0) {
          items.add(
            ReconciliationItem(
              id: 'refund:${refund.smsId}',
              label: refund.merchant ?? 'Refund',
              amountPaise: creditable,
              direction: LedgerDirection.inflow,
              owner: ForecastOwner.refund,
              source: ForecastItemSource.sms,
              actualDate: refund.txnDate,
              refundOfId: original == null ? null : 'actual:${original.smsId}',
              confidence: refund.confidence,
            ),
          );
          applied += creditable;
        }
        final excess = refund.amountPaise - creditable;
        if (excess > 0) {
          // Over-refund is reviewable income, never a negative expense.
          items.add(
            ReconciliationItem(
              id: 'refund-excess:${refund.smsId}',
              label: '${refund.merchant ?? 'Refund'} (over-refund)',
              amountPaise: excess,
              direction: LedgerDirection.inflow,
              owner: ForecastOwner.otherIncome,
              source: ForecastItemSource.sms,
              actualDate: refund.txnDate,
              userCadenceStatus: UserCadenceStatus.algorithmDetected,
              confidence: refund.confidence,
            ),
          );
        }
      }
    }
    return items;
  }

  String _refundGroupKey(ParsedTxn refund) =>
      refund.refNumber ?? _norm(refund.merchant ?? refund.sender);

  ParsedTxn? _findOriginalDebit(ParsedTxn refund, List<ParsedTxn> debits) {
    if (refund.refNumber != null) {
      for (final debit in debits) {
        if (debit.refNumber == refund.refNumber) return debit;
      }
    }
    final target = _norm(refund.merchant ?? '');
    if (target.isEmpty) return null;
    for (final debit in debits) {
      if (_norm(debit.merchant ?? '') == target) return debit;
    }
    return null;
  }

  // ---- atm / transfers ----------------------------------------------------

  List<ReconciliationItem> _atmItems(List<ParsedTxn> withdrawals) => [
    for (final txn in withdrawals)
      ReconciliationItem(
        id: 'atm:${txn.smsId}',
        label: 'ATM withdrawal',
        amountPaise: txn.amountPaise,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.atmCash,
        source: ForecastItemSource.sms,
        actualDate: txn.txnDate,
        confidence: txn.confidence,
      ),
  ];

  List<ReconciliationItem> _transferItems(List<ParsedTxn> transfers) => [
    for (final txn in transfers)
      ReconciliationItem(
        id: 'transfer:${txn.smsId}',
        label: 'Transfer',
        amountPaise: txn.amountPaise,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.transfer,
        source: ForecastItemSource.sms,
        actualDate: txn.txnDate,
        confidence: txn.confidence,
      ),
  ];

  // ---- classification helpers --------------------------------------------

  bool _isRefund(ParsedTxn txn) =>
      txn.direction == TransactionDirection.credit &&
      txn.instrument == PaymentInstrument.bank &&
      txn.categoryKey.toLowerCase().contains('refund');

  bool _isCardPayment(ParsedTxn txn) {
    if (txn.direction != TransactionDirection.debit) return false;
    if (txn.instrument != PaymentInstrument.bank) return false;
    if (txn.categoryKey.toLowerCase().contains('card_payment')) return true;
    final merchant = _norm(txn.merchant ?? '');
    return merchant.contains('cred') ||
        merchant.contains('billdesk') ||
        merchant.contains('cc payment') ||
        merchant.contains('card bill');
  }

  ForecastItemSource _sourceFor(ObligationSourceType type) => switch (type) {
    ObligationSourceType.gmail => ForecastItemSource.gmail,
    ObligationSourceType.manual => ForecastItemSource.manual,
    ObligationSourceType.configuredPlan => ForecastItemSource.configuredPlan,
    ObligationSourceType.smsRecurring => ForecastItemSource.sms,
  };

  String _norm(String value) =>
      value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Mutable owner accumulator used while joining actuals; converted to an
/// immutable [ReconciliationItem] once its paid/unpaid state is resolved.
class _JoinOwner {
  _JoinOwner({
    required this.id,
    required this.label,
    required this.owner,
    required this.direction,
    required this.amountPaise,
    required this.amountStatus,
    required this.merchantNorm,
    required this.categoryKey,
    required this.accountLast4,
    required this.recurrence,
    required this.dueDate,
    required this.matchKey,
    required this.accountScope,
    required this.confidence,
    required this.source,
    required this.refKeys,
    required this.paymentStatus,
    required this.foldable,
    this.isUserConfirmed = false,
    this.obligationDedupeKey,
  });

  final String id;
  final String label;
  final ForecastOwner owner;
  final LedgerDirection direction;
  final int? amountPaise;
  final AmountStatus amountStatus;
  final String merchantNorm;
  final String categoryKey;
  final String? accountLast4;
  final ReconciliationRecurrence recurrence;
  final DateTime? dueDate;
  final String? matchKey;
  final AccountScope accountScope;
  final double confidence;
  final ForecastItemSource source;
  final Set<String> refKeys;
  final bool foldable;
  final bool isUserConfirmed;
  final String? obligationDedupeKey;

  ReconciliationPaymentStatus paymentStatus;
  DateTime? actualDate;

  ReconciliationItem toItem() => ReconciliationItem(
    id: id,
    label: label,
    amountPaise: amountPaise,
    direction: direction,
    owner: owner,
    source: source,
    dueDate: dueDate,
    actualDate: actualDate,
    matchKey: matchKey,
    accountScope: accountScope,
    amountStatus: amountStatus,
    paymentStatus: paymentStatus,
    recurrence: recurrence,
    confidence: confidence,
    isUserConfirmed: isUserConfirmed,
    obligationDedupeKey: obligationDedupeKey,
  );
}
