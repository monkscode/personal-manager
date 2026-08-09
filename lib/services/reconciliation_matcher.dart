import 'dart:math' as math;

import '../core/clamped_date.dart';
import '../data/card_models.dart';
import '../data/forecast_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_models.dart';
import 'card_settlement_pairer.dart';
import 'money_lens.dart';
import 'recurring_debit_detector.dart';
import 'salary_income_detector.dart';
import 'seasonal_estimator.dart';
import 'transfer_bridge_matcher.dart';

/// A known annual heads-up line expires (requires refresh) after this many
/// months without fresh evidence (D8 spec default).
const int kAnnualHeadsUpExpiryMonths = 15;

/// How far back a refund may reach for the purchase it reverses when it has no
/// reference number to match on. Not a spec value — chosen to be permissive
/// (merchant refunds land well inside it) while stopping a refund from binding
/// to an unrelated purchase months earlier. In production the matcher only ever
/// sees one month of actuals, so this bites only on longer windows.
const int kRefundLookbackDays = 90;

/// Retired. The discretionary residual used to be dropped on this day, which
/// fabricated the "you need ₹X by the 28th" headline and made the whole estimate
/// vanish on the 29th. It is now spread over the days still ahead of the anchor
/// (see `_remainingDays`). Kept only so the D3 default stays on record.
@Deprecated('Superseded by _remainingDays; no longer dates anything.')
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
    required Set<String> confirmedFronts,
    required Map<String, CardSettlementPair> settlementPairs,
  }) {
    final bands = _amountBands(obligations, commitments);
    final owners = <_JoinOwner>[];
    owners.addAll(_obligationOwners(obligations, targetMonth, bands));
    owners.addAll(_commitmentOwners(commitments, targetMonth, bands));

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
      } else if (referencesObligation) {
        // The reference wins: a debit naming a known obligation is that
        // obligation's payment, whatever rail carried it. Bills paid by NEFT
        // or IMPS used to skip the fold entirely and be subtracted twice —
        // once as an unpaid obligation, once as a standalone transfer.
        debits.add(txn);
      } else if (txn.type == TxnType.transfer &&
          txn.direction == TransactionDirection.debit) {
        // Try the fold first; only a transfer that settles nothing stays a
        // transfer outflow. The discriminator is whether it matches a known
        // obligation, not whether the body says "transfer".
        transfers.add(txn);
        debits.add(txn);
      } else if (MoneyLens.isCardSettlement(txn, confirmedFronts)) {
        // Ahead of the `instrument == card` drop below on purpose: a bank
        // writing its settlement debit as "towards your HDFC Credit Card" is
        // stored as a card row, and the old bank-only test let it fall through
        // to `continue`, so a real bank outflow had no owner at all.
        cardPayments.add(txn);
      } else if (txn.instrument == PaymentInstrument.card) {
        // Per-purchase card SMS is represented by the CardCycleEstimate, not as
        // an individual bank cash item.
        continue;
      } else if (txn.direction == TransactionDirection.debit) {
        debits.add(txn);
      }
    }

    final folded = _foldActualsIntoOwners(debits, owners, targetMonth);

    final items = <ReconciliationItem>[];
    items.addAll(owners.map((o) => o.toItem()));
    items.addAll(_cardItems(cards, cardPayments, settlementPairs));
    final salaryItem = _salaryItem(salary, targetMonth);
    if (salaryItem != null) items.add(salaryItem);
    final discretionary = _discretionaryActuals(debits, folded, targetMonth);
    items.addAll(_discretionaryActualItems(discretionary));
    items.addAll(
      _seasonalItems(seasonal, targetMonth, discretionary, anchor),
    );
    items.addAll(_refundItems(refunds, actuals));
    items.addAll(_atmItems(atmWithdrawals));
    final unfoldedTransfers = [
      for (final txn in transfers)
        if (!folded.contains(txn.smsId)) txn,
    ];
    items.addAll(
      _transferItems(
        unfoldedTransfers,
        _bridgeTargets(unfoldedTransfers, actuals, obligations),
      ),
    );
    return items;
  }

  /// Maps a transfer's `smsId` to the id of the secondary-account obligation it
  /// uniquely funds, so the engine counts the transfer and marks the obligation
  /// funded instead of subtracting both legs of one rupee movement (spec §7).
  ///
  /// Only a *unique* pairing is named. An ambiguous one leaves the transfer a
  /// plain outflow: the cash left the primary account either way, and the
  /// obligation still carries its own out-of-primary-scope coverage line, so
  /// nothing is silently excluded by declining to guess.
  Map<String, String> _bridgeTargets(
    List<ParsedTxn> transfers,
    List<ParsedTxn> actuals,
    List<ObligationRecord> obligations,
  ) {
    if (transfers.isEmpty) return const {};
    final primaryEvents = [
      ...transfers,
      // The direct-payment override needs the non-transfer primary debits too:
      // a bill observed leaving the primary account is resolved there, and a
      // coincident self-transfer must not bridge it.
      for (final txn in actuals)
        if (txn.instrument == PaymentInstrument.bank &&
            txn.type != TxnType.transfer &&
            txn.direction == TransactionDirection.debit)
          txn,
    ];
    final candidates = const TransferBridgeMatcher().match(
      primaryEvents,
      obligations,
    );
    return {
      for (final candidate in candidates)
        if (candidate.obligation != null)
          candidate.transfer.smsId: 'obl:${candidate.obligation!.dedupeKey}',
    };
  }

  // ---- obligations --------------------------------------------------------

  List<_JoinOwner> _obligationOwners(
    List<ObligationRecord> obligations,
    DateTime targetMonth,
    _AmountBands bands,
  ) {
    final owners = <_JoinOwner>[];
    for (final obligation in obligations) {
      // A retired obligation is one no scan can derive any more, so it must not
      // own a rupee in the target month either. The horizon path skips these in
      // `_projectCanonicalObligations`; without the same check here a retired
      // row kept appearing in the target month's why-log, which is where the
      // device's duplicates actually showed (TASK-37).
      if (obligation.isRetired) continue;
      if (_annualHeadsUpExpired(obligation, targetMonth)) continue;

      final dueDate =
          obligation.dueDate ??
          (obligation.dueDay != null
              ? clampedDate(
                  targetMonth.year,
                  targetMonth.month,
                  obligation.dueDay!,
                )
              : null);
      final owner = _obligationOwner(obligation, dueDate);
      final matchKey = _obligationMatchKey(obligation, owner, bands);
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
    _AmountBands bands,
  ) {
    if (owner == ForecastOwner.configuredContribution) {
      return obligation.dedupeKey;
    }
    if (obligation.merchantNorm.isNotEmpty) {
      return bands.matchKey(
        obligation.merchantNorm,
        obligation.recurrence,
        obligation.amountPaise,
      );
    }
    return null;
  }

  // ---- commitments --------------------------------------------------------

  List<_JoinOwner> _commitmentOwners(
    List<RecurringCommitment> commitments,
    DateTime targetMonth,
    _AmountBands bands,
  ) {
    final owners = <_JoinOwner>[];
    for (var i = 0; i < commitments.length; i++) {
      final commitment = commitments[i];
      final recurrence = _mapCadence(commitment.cadence);
      final matchKey =
          commitment.configuredPlanKey ??
          (commitment.merchantNorm.isNotEmpty
              ? bands.matchKey(
                  commitment.merchantNorm,
                  recurrence,
                  commitment.amountPaise,
                )
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

  /// Folds each debit into the owner(s) it settles. Returns the `smsId`s that
  /// reached an owner, so a transfer-typed debit that settled an obligation is
  /// not *also* emitted as a standalone transfer outflow.
  Set<String> _foldActualsIntoOwners(
    List<ParsedTxn> debits,
    List<_JoinOwner> owners,
    DateTime targetMonth,
  ) {
    final folded = <String>{};
    final foldable = owners.where((o) => o.foldable).toList();
    final byId = {for (final owner in foldable) owner.id: owner};
    // Resolved globally, then assigned — assigning as we go made the answer
    // depend on the order `actuals` happened to arrive in: an ambiguous debit
    // processed after a unique one downgraded the owner it had already settled
    // and dropped it from the ledger entirely.
    final settledBy = <String, List<ParsedTxn>>{};
    final contested = <String>{};

    for (final debit in debits) {
      final matched = [
        for (final owner in foldable)
          if (_matches(debit, owner, targetMonth)) owner,
      ];
      if (matched.isEmpty) continue;

      // The amount discriminates first. The reference lane in `_matches` skips
      // the amount check, so a ₹5,000 payment can reach a ₹45,000 obligation
      // that merely shares its reference; an owner this debit could not have
      // settled is not a candidate for it, however it was reached.
      final candidates = [
        for (final owner in matched)
          if (_amountCompatible(debit, owner)) owner,
      ];
      folded.add(debit.smsId);
      if (candidates.isEmpty) {
        // Reached by reference alone. The reference is evidence of a
        // relationship, not of payment — hold it for review.
        contested.addAll(matched.map((o) => o.id));
        continue;
      }

      final distinctKeys = candidates.map((o) => o.matchKey ?? o.id).toSet();
      if (distinctKeys.length == 1) {
        // Same logical obligation (possibly described by multiple sources).
        for (final owner in candidates) {
          settledBy.putIfAbsent(owner.id, () => []).add(debit);
        }
      } else {
        // Genuinely ambiguous: hold every candidate for review rather than
        // silently merging or double-subtracting.
        contested.addAll(candidates.map((o) => o.id));
      }
    }

    for (final entry in settledBy.entries) {
      final owner = byId[entry.key]!;
      final earliest = entry.value.reduce(
        (a, b) => a.txnDate.isBefore(b.txnDate) ? a : b,
      );
      owner.actualDate = earliest.txnDate;
      owner.paymentStatus = ReconciliationPaymentStatus.paid;
    }
    for (final id in contested) {
      // A confirmed unique match wins outright: an ambiguous debit may raise a
      // question about an owner, never overturn an answer another debit gave.
      if (settledBy.containsKey(id)) continue;
      byId[id]!.paymentStatus = ReconciliationPaymentStatus.possiblyPaid;
    }
    return folded;
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

  bool _withinJitter(int actual, int expected) =>
      _amountWithinJitter(actual, expected);

  /// True when [debit] could plausibly have settled [owner]'s amount. A
  /// reference match in [_matches] deliberately bypasses the amount check, so
  /// this is the separate question of whether the rupees line up.
  bool _amountCompatible(ParsedTxn debit, _JoinOwner owner) =>
      owner.amountPaise != null &&
      _withinJitter(debit.amountPaise, owner.amountPaise!);

  // ---- amount bands -------------------------------------------------------

  /// Bands the amounts present under each merchant+recurrence key so two
  /// obligations that merely share a merchant and cadence do not share a
  /// reconciliation group (and so cannot suppress one another).
  _AmountBands _amountBands(
    List<ObligationRecord> obligations,
    List<RecurringCommitment> commitments,
  ) {
    final amounts = <String, List<int>>{};
    final unbandable = <String>{};
    void record(String merchantNorm, ReconciliationRecurrence r, int? paise) {
      if (merchantNorm.isEmpty) return;
      final key = _AmountBands.groupKey(merchantNorm, r);
      if (paise == null) {
        // An unknown amount is not a *different* amount: banding the rest of
        // the key would stop a quantified sibling folding into it and the same
        // bill would be counted twice.
        unbandable.add(key);
        return;
      }
      amounts.putIfAbsent(key, () => []).add(paise);
    }

    for (final obligation in obligations) {
      record(
        obligation.merchantNorm,
        obligation.recurrence,
        obligation.amountPaise,
      );
    }
    for (final commitment in commitments) {
      record(
        commitment.merchantNorm,
        _mapCadence(commitment.cadence),
        commitment.amountPaise,
      );
    }

    return _AmountBands({
      for (final entry in amounts.entries)
        if (!unbandable.contains(entry.key)) entry.key: _clusterFloors(entry.value),
    });
  }

  /// The representative (lowest) amount of each jitter cluster, ascending.
  /// Compared against the cluster floor rather than the previous element so a
  /// long ladder of near amounts cannot chain into one enormous band.
  List<int> _clusterFloors(List<int> amounts) {
    final sorted = [...amounts]..sort();
    final floors = <int>[];
    for (final amount in sorted) {
      if (floors.isEmpty || !_amountWithinJitter(amount, floors.last)) {
        floors.add(amount);
      }
    }
    return floors;
  }

  // ---- cards --------------------------------------------------------------

  /// Names the gap Spec A Part 1 opened: card purchases now count as spend on
  /// the day they were made, and the bill that will actually leave the bank is
  /// still in nobody's plan (a `cardPurchase` item is routed to
  /// `quantifiedExcluded` and never becomes a dated event). The omission has to
  /// be quantified and named, per the no-silent-exclusion rule — but never
  /// dated, because nothing here knows the due date.
  ///
  /// The window is what makes the number honest. With a card-side payment
  /// credit in history the figure is one bill's worth; without one it is
  /// everything ever seen on the card, and saying "since its last payment"
  /// there would be a lie the user cannot check.
  String _cardSpendLabel(CardCycleEstimate estimate) =>
      estimate.windowStart == null
      ? "Card ${estimate.cardLast4} bills aren't planned yet — "
            'no bill payment seen, so this is everything'
      : "Card ${estimate.cardLast4} bills aren't planned yet — "
            'spent since its last payment';

  List<ReconciliationItem> _cardItems(
    List<CardCycleEstimate> cards,
    List<ParsedTxn> cardPayments,
    Map<String, CardSettlementPair> settlementPairs,
  ) {
    final items = <ReconciliationItem>[];
    for (var i = 0; i < cards.length; i++) {
      final estimate = cards[i];
      if (estimate.needsCycleSetup) {
        // Nothing bought since the bill was paid. Counting forward from the
        // last payment is what makes this reachable at all — the figure used to
        // be a lifetime total and was never zero — and a ₹0 line in "Needs your
        // attention" names an omission that is not there. This is not a silent
        // exclusion: there is no rupee to exclude.
        if (estimate.statementEventAmountPaise == 0) continue;
        items.add(
          ReconciliationItem(
            id: 'card:${estimate.cardCycleKey}:$i',
            label: _cardSpendLabel(estimate),
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
      final attribution = _cardCycleFor(payment, cards, settlementPairs);
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
          cardCycleKey: attribution.cardCycleKey,
          needsAttributionReview: attribution.ambiguous,
          confidence: payment.confidence,
        ),
      );
    }
    return items;
  }

  /// Which card cycle a bill payment settled.
  ///
  /// **The card's own acknowledgement answers this outright** when the payment
  /// paired with one. [CardSettlementPair.cardLast4] is the issuer confirming
  /// the bill was credited to that card, on that day, for those rupees — ground
  /// truth, not inference. It outranks everything below, including a matching
  /// amount: reward points routinely make the bank debit smaller than the bill,
  /// so the amount can look like a different card's statement than the one that
  /// was actually paid.
  ///
  /// **Once an acknowledgement has named a card, the guess never runs.** If
  /// exactly one cycle estimate carries that card the answer is that cycle;
  /// anything else — no estimate for it, or two cycles of it — goes to review.
  /// Falling back to the guess there would let the payment be attributed to a
  /// *different* card than the issuer named, which is worse than admitting the
  /// cycle is unknown: with one card due this month and an acknowledgement for
  /// a card the app has no cycle for, the guess hands the payment to the wrong
  /// one with no review flag at all. Both branches are unreachable through
  /// `SmsAnalysisSnapshot`, which groups estimates by `accountLast4` and feeds
  /// the pairer the same rows, so the acknowledgement's own card always has
  /// exactly one estimate; they are reachable by any other caller.
  ///
  /// Only with no pair at all, or an acknowledgement naming no card, is the
  /// issuer genuinely hidden — the normal shape of a payment made through CRED
  /// or Cheq: a plain savings-account debit carrying the *savings* account
  /// number. Then the cycle is guessed, by due-window (same statement month)
  /// and then by amount (spec §7 card-bill payment rule). Two cards a payment
  /// could equally have settled are **not** guessed between — an ambiguous
  /// attribution goes to review.
  ///
  /// **That guess is unreachable in the app as it ships** (checked 2026-08-09):
  /// a [CardCycleEstimate] only carries a `dueDate` when it was built from a
  /// configured [CardCycle], and nothing in `lib/` constructs one — the class
  /// has no call site outside its own declaration. So `inWindow` is always
  /// empty, and before the acknowledgement path above existed, every card-bill
  /// payment shipped with a null cycle and no review flag. The guess is kept
  /// because it is the correct behaviour the day cycle configuration lands, and
  /// it is covered by tests that supply a `dueDate` directly.
  _CardCycleAttribution _cardCycleFor(
    ParsedTxn payment,
    List<CardCycleEstimate> cards,
    Map<String, CardSettlementPair> settlementPairs,
  ) {
    final acknowledgedCard = settlementPairs[payment.smsId]?.cardLast4;
    if (acknowledgedCard != null) {
      final named = [
        for (final estimate in cards)
          if (estimate.cardLast4 == acknowledgedCard) estimate,
      ];
      if (named.length == 1) {
        return _CardCycleAttribution(named.single.cardCycleKey);
      }
      return const _CardCycleAttribution.none(ambiguous: true);
    }

    final inWindow = [
      for (final estimate in cards)
        if (estimate.dueDate != null &&
            estimate.dueDate!.year == payment.txnDate.year &&
            estimate.dueDate!.month == payment.txnDate.month)
          estimate,
    ];
    if (inWindow.isEmpty) return const _CardCycleAttribution.none();
    if (inWindow.length == 1) {
      // One card due this month owns it, whatever the amount — a partial
      // payment is still that card's payment.
      return _CardCycleAttribution(inWindow.single.cardCycleKey);
    }

    final plausible = [
      for (final estimate in inWindow)
        if (_amountWithinJitter(
          payment.amountPaise,
          estimate.statementEventAmountPaise,
        ))
          estimate,
    ];
    if (plausible.length == 1) return _CardCycleAttribution(plausible.single.cardCycleKey);
    // Either several cards match the amount or none does. Both are guesses.
    return const _CardCycleAttribution.none(ambiguous: true);
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
      dueDate: clampedDate(targetMonth.year, targetMonth.month, day),
      confidence: salary.confidence == SalaryConfidence.detectedStable
          ? 0.9
          : 0.6,
    );
  }

  /// Discretionary debits observed this month that no owner claimed. They are
  /// the `D_mtd` the seasonal estimate must be netted against: the estimate is
  /// a *whole-month* magnitude, so subtracting it in full alongside spend
  /// already observed counts those rupees twice, by a margin that grows every
  /// day of the month.
  List<ParsedTxn> _discretionaryActuals(
    List<ParsedTxn> debits,
    Set<String> folded,
    DateTime targetMonth,
  ) => [
    for (final txn in debits)
      if (!folded.contains(txn.smsId) &&
          txn.type != TxnType.transfer &&
          txn.type != TxnType.atm &&
          txn.instrument != PaymentInstrument.card &&
          _withinWindow(txn.txnDate, targetMonth))
        txn,
  ];

  /// Each already-spent discretionary transaction as its own item, so the
  /// why-log can name it (spec: "shown in the why-log for traceability"). The
  /// engine decides whether it is inside the anchor — spend before the balance
  /// reading is `alreadyInAnchor` and is *not* subtracted again, spend after it
  /// is real cash the ledger still owes.
  List<ReconciliationItem> _discretionaryActualItems(
    List<ParsedTxn> discretionary,
  ) => [
    for (final txn in discretionary)
      ReconciliationItem(
        id: 'spend:${txn.smsId}',
        label: txn.merchant ?? txn.categoryKey,
        amountPaise: txn.amountPaise,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.discretionarySpend,
        source: ForecastItemSource.sms,
        actualDate: txn.txnDate,
        confidence: txn.confidence,
      ),
  ];

  List<ReconciliationItem> _seasonalItems(
    SeasonalEstimate seasonal,
    DateTime targetMonth,
    List<ParsedTxn> discretionary,
    BalanceAnchor anchor,
  ) {
    final spentByCategory = <String, int>{};
    for (final txn in discretionary) {
      spentByCategory[txn.categoryKey] =
          (spentByCategory[txn.categoryKey] ?? 0) + txn.amountPaise;
    }

    final days = _remainingDays(targetMonth, anchor);
    final items = <ReconciliationItem>[];
    for (final entry in seasonal.byCategory.values) {
      if (entry.amountPaise <= 0) continue;
      // max(0, S − D_mtd): an over-run does not become negative spend.
      final residual =
          entry.amountPaise - (spentByCategory[entry.categoryKey] ?? 0);
      if (residual <= 0) continue;

      final shares = _spreadPaise(residual, days.length);
      for (var i = 0; i < days.length; i++) {
        if (shares[i] <= 0) continue;
        items.add(
          ReconciliationItem(
            id: 'seasonal:${entry.categoryKey}:${days[i].day}',
            label: entry.categoryKey,
            amountPaise: shares[i],
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.discretionarySpend,
            source: ForecastItemSource.estimator,
            dueDate: days[i],
            amountStatus: AmountStatus.estimated,
            confidence: entry.confidence,
            // The split below is for the ledger's daily minimum balance, not
            // for the user: a month of one category is one thing to confirm or
            // dismiss. The shared id says so, and the forecast collapses the
            // slices back into a single reviewable line.
            groupId: 'seasonal:${entry.categoryKey}',
          ),
        );
      }
    }
    return items;
  }

  /// The days of [targetMonth] still ahead of the anchor. Replaces the
  /// hardcoded [kSeasonalBufferDayOfMonth], which both fabricated the
  /// "you need ₹X by 28 Jul" headline date and made the whole estimate vanish
  /// on the 29th, when day 28 stopped being after the anchor.
  List<DateTime> _remainingDays(DateTime targetMonth, BalanceAnchor anchor) {
    final lastDay = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;
    var first = 1;
    if (_withinWindow(anchor.asOf, targetMonth)) first = anchor.asOf.day + 1;
    // At month end there is no window left; keep the last day so a residual is
    // still stated rather than silently disappearing.
    if (first > lastDay) first = lastDay;
    return [
      for (var day = first; day <= lastDay; day++)
        DateTime(targetMonth.year, targetMonth.month, day),
    ];
  }

  /// Splits [total] into [parts] integer-paise shares that sum back to [total];
  /// the remainder goes to the earliest days rather than being rounded away.
  List<int> _spreadPaise(int total, int parts) {
    if (parts <= 0) return const [];
    final base = total ~/ parts;
    final remainder = total % parts;
    return [
      for (var i = 0; i < parts; i++) base + (i < remainder ? 1 : 0),
    ];
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
    // The cap belongs to the *original debit*, not to a group. Two refunds for
    // one order carrying different reference numbers formed two groups, each
    // resolved to the same purchase, and each was capped at the full amount —
    // crediting up to twice the purchase as bank inflow.
    final sorted = [...refunds]..sort((a, b) => a.txnDate.compareTo(b.txnDate));
    final appliedByDebit = <String, int>{};

    final items = <ReconciliationItem>[];
    for (final refund in sorted) {
      final original = _findOriginalDebit(refund, debits);
      if (original == null) {
        // Nothing plausible to refund. A credit with no purchase behind it is
        // held for review rather than invented as income.
        items.add(
          ReconciliationItem(
            id: 'refund:${refund.smsId}',
            label: refund.merchant ?? 'Refund',
            amountPaise: refund.amountPaise,
            direction: LedgerDirection.inflow,
            owner: ForecastOwner.refund,
            source: ForecastItemSource.sms,
            actualDate: refund.txnDate,
            needsAttributionReview: true,
            confidence: refund.confidence,
          ),
        );
        continue;
      }

      final applied = appliedByDebit[original.smsId] ?? 0;
      final remaining = math.max(0, original.amountPaise - applied);
      final creditable = math.min(refund.amountPaise, remaining);
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
            refundOfId: 'actual:${original.smsId}',
            confidence: refund.confidence,
          ),
        );
        appliedByDebit[original.smsId] = applied + creditable;
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
    return items;
  }

  /// The purchase a refund plausibly reverses. A reference number is an exact
  /// identifier and stands on its own; a merchant-name match must additionally
  /// be large enough to have produced the refund and close enough in time —
  /// without those, a ₹3,000 refund capped against a ₹200 same-merchant debit
  /// manufactured ₹2,800 of "over-refund income".
  ParsedTxn? _findOriginalDebit(ParsedTxn refund, List<ParsedTxn> debits) {
    if (refund.refNumber != null) {
      for (final debit in debits) {
        if (debit.refNumber == refund.refNumber) return debit;
      }
    }
    final target = _norm(refund.merchant ?? '');
    if (target.isEmpty) return null;
    ParsedTxn? best;
    for (final debit in debits) {
      if (_norm(debit.merchant ?? '') != target) continue;
      if (debit.amountPaise < refund.amountPaise) continue;
      if (debit.txnDate.isAfter(refund.txnDate)) continue;
      if (refund.txnDate.difference(debit.txnDate).inDays >
          kRefundLookbackDays) {
        continue;
      }
      // The most recent qualifying purchase is the likeliest source.
      if (best == null || debit.txnDate.isAfter(best.txnDate)) best = debit;
    }
    return best;
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

  List<ReconciliationItem> _transferItems(
    List<ParsedTxn> transfers,
    Map<String, String> bridgeTargets,
  ) => [
    for (final txn in transfers)
      ReconciliationItem(
        id: 'transfer:${txn.smsId}',
        label: 'Transfer',
        amountPaise: txn.amountPaise,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.transfer,
        source: ForecastItemSource.sms,
        actualDate: txn.txnDate,
        transferBridgeToId: bridgeTargets[txn.smsId],
        confidence: txn.confidence,
      ),
  ];

  // ---- classification helpers --------------------------------------------

  bool _isRefund(ParsedTxn txn) =>
      txn.direction == TransactionDirection.credit &&
      txn.instrument == PaymentInstrument.bank &&
      txn.categoryKey.toLowerCase().contains('refund');

  ForecastItemSource _sourceFor(ObligationSourceType type) => switch (type) {
    ObligationSourceType.gmail => ForecastItemSource.gmail,
    ObligationSourceType.manual => ForecastItemSource.manual,
    ObligationSourceType.configuredPlan => ForecastItemSource.configuredPlan,
    ObligationSourceType.smsRecurring => ForecastItemSource.sms,
  };

  String _norm(String value) =>
      value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
}

/// Which card cycle a bill payment settles, or that it cannot be told.
class _CardCycleAttribution {
  const _CardCycleAttribution(this.cardCycleKey) : ambiguous = false;
  const _CardCycleAttribution.none({this.ambiguous = false})
    : cardCycleKey = null;

  final String? cardCycleKey;
  final bool ambiguous;
}

/// The jitter tolerance the whole reconciliation slice shares: the larger of a
/// ratio of the expected amount and a flat floor (spec §3).
bool _amountWithinJitter(int actual, int expected) {
  final tolerance = math.max(
    (expected * kRecurringAmountJitterRatio).round(),
    kRecurringAmountJitterFloorPaise,
  );
  return (actual - expected).abs() <= tolerance;
}

/// Amount bands per merchant+recurrence key, so a match key answers "same
/// merchant, same cadence, **and** an amount a single payment could settle"
/// rather than only the first two.
class _AmountBands {
  const _AmountBands(this._floorsByKey);

  final Map<String, List<int>> _floorsByKey;

  static String groupKey(String merchantNorm, ReconciliationRecurrence r) =>
      'merch:$merchantNorm:${r.name}';

  /// The match key for one record, or null when the merchant is unknown.
  String? matchKey(
    String merchantNorm,
    ReconciliationRecurrence recurrence,
    int? amountPaise,
  ) {
    if (merchantNorm.isEmpty) return null;
    final key = groupKey(merchantNorm, recurrence);
    final floors = _floorsByKey[key];
    if (floors == null || floors.isEmpty || amountPaise == null) {
      // Unbanded: this key has a member whose amount is unknown, so amounts
      // cannot separate its members and the pre-band behaviour stands.
      return key;
    }
    var floor = floors.first;
    for (final candidate in floors) {
      if (amountPaise >= candidate) floor = candidate;
    }
    return '$key:$floor';
  }
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
