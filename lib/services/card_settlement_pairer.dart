import '../data/sms_models.dart';
import 'card_cycle_estimator.dart';

/// One card-bill payment as the phone actually receives it: the savings-account
/// debit, and the card's own acknowledgement of the same bill.
class CardSettlementPair {
  const CardSettlementPair({required this.debit, required this.ack});

  final ParsedTxn debit;
  final ParsedTxn ack;

  /// What the bill exceeded the bank debit by — reward points spent at the
  /// payment app. Measured over the owner's device: 19 of 31 pairs carry one,
  /// min Rs.1, median Rs.4, max Rs.44, totalling 0.170% of what was billed.
  int get pointsPaise => ack.amountPaise - debit.amountPaise;

  /// The card the bill belonged to. The bank debit never carries this — its
  /// `accountLast4` is the *savings* account — so the acknowledgement is the
  /// only side that can answer.
  String? get cardLast4 => ack.accountLast4;
}

/// Joins a bank debit to the card acknowledgement it settled.
///
/// One payment, two rails, and each rail knows something the other does not.
/// The debit knows how much money actually left the bank; the acknowledgement
/// knows which card it was for and what the bill came to. Pairing them yields
/// the card, the points, and — for a merchant the app has never met — evidence
/// that this merchant is a card-bill payment front at all. That last one is
/// what found Cheq Digital, Rs.5,35,438 the app counted as ordinary shopping.
///
/// **The window is fixed by measurement, not by taste.** Over the owner's 1,026
/// bank debits:
///
///     window     gap cap    paired  correct  wrong  precision
///     same day   exact          11       11      0     100.0%
///     same day   <= Rs.500      37       37      0     100.0%   <- this
///     +-2 days   <= Rs.500      40       38      2      95.0%
///     +-3 days   <= Rs.10,000   48       23     25      47.9%
///
/// Widening either dimension starts erasing real purchases — at +-2 days it
/// swallows Corner Store Rs.65 and a private payee Rs.30. A wrong
/// exclusion silently deletes money from the user's spend total, so the setting
/// with no false positives is the only defensible one. Do not widen without
/// re-running that measurement.
///
/// **Matching is global, not first-debit-wins.** Every legal (debit,
/// acknowledgement) combination — same local day, gap within the cap — is a
/// candidate; the smallest gap wins, claiming both sides out of the pool, and
/// only then does the next-smallest gap get to claim from what is left. Two
/// same-day debits can each sit within the cap of one acknowledgement, and
/// deciding that by which debit happened to be listed first is deciding it by
/// nothing — the input order is an accident of how the caller assembled the
/// list, not a fact about which payment the ack actually settled. A tie in the
/// gap itself is broken on the debit's, then the acknowledgement's, `smsId` so
/// the result never depends on hash order or input order either.
///
/// This class decides nothing about the user's money. It reports a
/// correspondence; `CardSettlementCandidateFinder` turns that into a question,
/// and only a stored answer excludes anything.
class CardSettlementPairer {
  const CardSettlementPairer();

  /// The largest bill-minus-debit difference still read as reward points.
  /// Rs.500 in paise.
  static const maxPointsGapPaise = 50000;

  /// How far apart two acknowledgements of the same payment may sit, in days.
  /// HDFC sends "RECEIVED TOWARDS" on the day and "was credited to your card
  /// ... value Date" the day after — one payment, two messages.
  static const _ackDedupeWindowDays = 2;

  List<CardSettlementPair> pairs(List<ParsedTxn> txns) {
    final acks = _dedupedAcks(txns);
    final debits = [
      for (final txn in txns)
        if (txn.direction == TransactionDirection.debit &&
            txn.instrument == PaymentInstrument.bank)
          txn,
    ];

    // Every legal combination, smallest gap first. Ties broken on the
    // debit's then the ack's smsId so the order never depends on how the
    // caller happened to list the transactions.
    final candidates = <(ParsedTxn debit, ParsedTxn ack, int gap)>[];
    for (final debit in debits) {
      for (final ack in acks) {
        if (ack.txnLocalDate != debit.txnLocalDate) continue;
        final gap = ack.amountPaise - debit.amountPaise;
        if (gap < 0 || gap > maxPointsGapPaise) continue;
        candidates.add((debit, ack, gap));
      }
    }
    candidates.sort((a, b) {
      final byGap = a.$3.compareTo(b.$3);
      if (byGap != 0) return byGap;
      final byDebit = a.$1.smsId.compareTo(b.$1.smsId);
      if (byDebit != 0) return byDebit;
      return a.$2.smsId.compareTo(b.$2.smsId);
    });

    final claimedDebits = <String>{};
    final claimedAcks = <String>{};
    final out = <CardSettlementPair>[];
    for (final (debit, ack, _) in candidates) {
      if (claimedDebits.contains(debit.smsId)) continue;
      if (claimedAcks.contains(ack.smsId)) continue;
      claimedDebits.add(debit.smsId);
      claimedAcks.add(ack.smsId);
      out.add(CardSettlementPair(debit: debit, ack: ack));
    }

    out.sort((a, b) {
      final byDate = a.debit.txnDate.compareTo(b.debit.txnDate);
      if (byDate != 0) return byDate;
      return a.debit.smsId.compareTo(b.debit.smsId);
    });
    return out;
  }

  /// Card-side payment acknowledgements, with an issuer's duplicate collapsed.
  ///
  /// Collapsed on card and amount rather than on body wording: the two HDFC
  /// messages describe the same rupees on the same card and differ only in
  /// phrasing, and a rule keyed on phrasing breaks the next time an issuer
  /// rewords one.
  List<ParsedTxn> _dedupedAcks(List<ParsedTxn> txns) {
    final acks = [
      for (final txn in txns)
        if (txn.instrument == PaymentInstrument.card &&
            txn.direction == TransactionDirection.credit &&
            isCardBillPayment(txn))
          txn,
    ]..sort((a, b) => a.txnDate.compareTo(b.txnDate));

    final kept = <ParsedTxn>[];
    for (final ack in acks) {
      final duplicate = kept.any(
        (seen) =>
            seen.accountLast4 == ack.accountLast4 &&
            seen.amountPaise == ack.amountPaise &&
            _dayGap(seen.txnDate, ack.txnDate) <= _ackDedupeWindowDays,
      );
      if (!duplicate) kept.add(ack);
    }
    return kept;
  }

  int _dayGap(DateTime a, DateTime b) => DateTime(a.year, a.month, a.day)
      .difference(DateTime(b.year, b.month, b.day))
      .inDays
      .abs();
}
