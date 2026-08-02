import '../data/forecast_models.dart';
import '../data/obligation_models.dart';
import '../data/sms_models.dart';

/// Amount band (in paise, ±₹50) within which a primary-account transfer may
/// fund a secondary-account obligation (D7 spec default).
const int kTransferBridgeAmountBandPaise = 5000;

/// Days a funding transfer may precede the obligation's due date (D7 default).
const int kTransferBridgeDaysBeforeDue = 5;

/// Days a funding transfer may follow the obligation's due date (D7 default).
const int kTransferBridgeDaysAfterDue = 2;

/// How a candidate transfer resolves against secondary obligations.
enum TransferBridgeResolution {
  /// Exactly one transfer uniquely funds exactly one obligation.
  funded,

  /// More than one plausible pairing; must not auto-link — routes to review.
  ambiguous,
}

/// A primary-account transfer that plausibly funds one or more secondary-account
/// obligations (spec §7 "Primary-to-secondary transfer bridge").
class TransferBridgeCandidate {
  const TransferBridgeCandidate({
    required this.transfer,
    required this.obligations,
    required this.resolution,
  });

  final ParsedTxn transfer;
  final List<ObligationRecord> obligations;
  final TransferBridgeResolution resolution;

  /// The uniquely funded obligation, or null when [resolution] is ambiguous.
  ObligationRecord? get obligation =>
      resolution == TransferBridgeResolution.funded ? obligations.single : null;
}

/// Matches primary-account transfers to secondary-account obligations so a
/// transfer that merely funds a bill is not double-counted against the bill
/// (spec §7). A unique pairing funds the obligation (kept out of the primary
/// ledger); multiple plausible pairings are held for review rather than
/// auto-linked. A directly-observed primary debit of the bill overrides a stale
/// secondary hint and suppresses any bridge.
class TransferBridgeMatcher {
  const TransferBridgeMatcher();

  List<TransferBridgeCandidate> match(
    List<ParsedTxn> primaryTransfers,
    List<ObligationRecord> secondaryObligations,
  ) {
    // Obligations whose bill was paid directly on the primary account are
    // resolved there; a stale secondary hint (and any coincident transfer) must
    // not create a bridge for them.
    final directlyPaid = _directlyPaidOnPrimary(
      primaryTransfers,
      secondaryObligations,
    );

    final obligations = [
      for (final obligation in secondaryObligations)
        if (obligation.paymentAccountScope == AccountScope.secondary &&
            obligation.dueDate != null &&
            obligation.amountPaise != null &&
            !directlyPaid.contains(obligation.dedupeKey))
          obligation,
    ];

    final transfers = [
      for (final txn in primaryTransfers)
        if (txn.type == TxnType.transfer &&
            txn.direction == TransactionDirection.debit)
          txn,
    ];

    // Bipartite adjacency: which obligations each transfer can fund. Keyed by
    // `smsId`/`dedupeKey` rather than by the model instances — neither has
    // value equality, so a `copyWith` anywhere between the two passes would
    // have silently broken the pairing.
    final matchesByTransfer = <String, List<ObligationRecord>>{};
    final transfersByObligation = <String, List<ParsedTxn>>{};
    final transferById = <String, ParsedTxn>{};
    for (final transfer in transfers) {
      final matched = [
        for (final obligation in obligations)
          if (_bridges(transfer, obligation)) obligation,
      ];
      if (matched.isEmpty) continue;
      matchesByTransfer[transfer.smsId] = matched;
      transferById[transfer.smsId] = transfer;
      for (final obligation in matched) {
        transfersByObligation
            .putIfAbsent(obligation.dedupeKey, () => [])
            .add(transfer);
      }
    }

    final candidates = <TransferBridgeCandidate>[];
    for (final entry in matchesByTransfer.entries) {
      final transfer = transferById[entry.key]!;
      final matched = entry.value;
      // Unique iff this transfer maps to a single obligation AND that
      // obligation is contested by no other transfer.
      final unique = matched.length == 1 &&
          transfersByObligation[matched.single.dedupeKey]!.length == 1;
      candidates.add(
        TransferBridgeCandidate(
          transfer: transfer,
          obligations: matched,
          resolution: unique
              ? TransferBridgeResolution.funded
              : TransferBridgeResolution.ambiguous,
        ),
      );
    }
    return candidates;
  }

  /// The `dedupeKey`s of obligations observed being paid directly on the
  /// primary account. Keyed by value, not by instance — `ObligationRecord` has
  /// no `==`, so a set of records only works while the identical instances flow
  /// through both passes.
  Set<String> _directlyPaidOnPrimary(
    List<ParsedTxn> primaryEvents,
    List<ObligationRecord> obligations,
  ) {
    final directDebits = [
      for (final txn in primaryEvents)
        if (txn.type != TxnType.transfer &&
            txn.direction == TransactionDirection.debit)
          txn,
    ];
    final resolved = <String>{};
    for (final obligation in obligations) {
      final amount = obligation.amountPaise;
      final due = obligation.dueDate;
      if (amount == null || due == null) continue;
      for (final debit in directDebits) {
        // Bounded to the same due window `_bridges` uses. Unbounded, a matching
        // debit from eleven months ago vetoed this month's bridge forever, and
        // the obligation was then counted separately — reintroducing the exact
        // double count this module exists to stop.
        if (!_withinDueWindow(debit.txnDate, due)) continue;
        if ((debit.amountPaise - amount).abs() > kTransferBridgeAmountBandPaise) {
          continue;
        }
        if (_merchantNorm(debit.merchant) == obligation.merchantNorm) {
          resolved.add(obligation.dedupeKey);
          break;
        }
      }
    }
    return resolved;
  }

  bool _bridges(ParsedTxn transfer, ObligationRecord obligation) {
    final amount = obligation.amountPaise!;
    if ((transfer.amountPaise - amount).abs() > kTransferBridgeAmountBandPaise) {
      return false;
    }
    return _withinDueWindow(transfer.txnDate, obligation.dueDate!);
  }

  /// Inclusive on both edges, normalised to dates first so a time-of-day
  /// component cannot push an in-window payment out of it.
  bool _withinDueWindow(DateTime date, DateTime due) {
    final earliest = due.subtract(
      const Duration(days: kTransferBridgeDaysBeforeDue),
    );
    final latest = due.add(const Duration(days: kTransferBridgeDaysAfterDue));
    final day = DateTime(date.year, date.month, date.day);
    final lo = DateTime(earliest.year, earliest.month, earliest.day);
    final hi = DateTime(latest.year, latest.month, latest.day);
    return !day.isBefore(lo) && !day.isAfter(hi);
  }

  String _merchantNorm(String? merchant) =>
      (merchant ?? '').toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
}
