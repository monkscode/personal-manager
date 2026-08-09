import '../data/card_settlement_front_store.dart';
import '../data/sms_models.dart';
import 'card_settlement_pairer.dart';
import 'money_lens.dart';

/// Why a merchant is being asked about.
enum CardSettlementCandidateSource {
  /// A debit to this merchant paired with a card's payment acknowledgement.
  paired,

  /// This merchant is a truncation of, or is truncated by, a confirmed front.
  adjacent,
}

/// One question: *is this merchant how you pay a card bill?*
class CardSettlementCandidate {
  const CardSettlementCandidate({
    required this.merchantNorm,
    required this.displayMerchant,
    required this.source,
    required this.debit,
    this.ack,
    this.adjacentTo,
  });

  final String merchantNorm;

  /// The merchant as the bank wrote it, for the question on screen.
  final String displayMerchant;
  final CardSettlementCandidateSource source;

  /// The payment being shown as evidence.
  final ParsedTxn debit;

  /// The acknowledgement that paired with [debit]. Null for [adjacent].
  final ParsedTxn? ack;

  /// The confirmed front this merchant resembles. Null for [paired].
  final String? adjacentTo;

  int? get pointsPaise {
    final acknowledgement = ack;
    if (acknowledgement == null) return null;
    return acknowledgement.amountPaise - debit.amountPaise;
  }

  String? get cardLast4 => ack?.accountLast4;
}

/// Decides which merchants to ask the user about, and never decides anything
/// about their money.
///
/// **Two sources, one gate.**
///
/// *Paired* — a debit that matched a card's own acknowledgement
/// ([CardSettlementPairer]). Strong evidence: the card confirmed the rupees
/// arrived. This is what surfaced Cheq Digital, a payment app the app had never
/// heard of carrying Rs.5,35,438.
///
/// *Adjacent* — the merchant is a prefix of a confirmed front, or is prefixed
/// by one. Weak evidence, kept for a design reason: the bank really does
/// truncate the same payee at four different lengths (`cheq`,
/// `cheq digital privat`, `cheq digital private limi`,
/// `cheq digital private limited`), and a spelling that genuinely never pairs
/// on its own could only ever be reached by resemblance to one that does.
///
/// **This paragraph used to claim more than that, and the claim was wrong.**
/// It said "the truncations do not all pair" and that `cheq` — Rs.1,90,417,
/// the largest single card payment on the device — "pairs with nothing," so a
/// pairing-only design would leave 25% of all card-bill money counted as
/// shopping. `test/card_settlement_corpus_test.dart` disproves it: round 1
/// (`CardSettlementFronts.empty`) returns 12 candidates, every single one via
/// `paired`, and its asserted set includes all four `cheq` spellings —
/// `cheq`'s own Rs.1,90,417 debit pairs directly with an ICICI Bank
/// acknowledgement. On this corpus adjacency contributed zero of the 12;
/// pairing alone reached everything, including the row this paragraph said it
/// couldn't. Kept retracted-but-visible rather than quietly deleted, the way
/// `CardSettlementPairer`'s window correction is (see that file's module
/// docstring) — the design reason above still holds on its own logic, it
/// currently just has no measured example proving it was ever needed.
///
/// Adjacency is emphatically **not** the auto-prefix rule that was measured and
/// rejected. Letting pairing learn names unsupervised reached 20 of 21 leaked
/// rows and newly erased 11 innocent ones: `amazon` came in behind
/// `amazon pay credit c`, and `shree arbuda statio` — a stationery shop that
/// paired once by coincidence — took four real purchases with it. Here
/// adjacency only ever produces a question. Nothing is excluded until the user
/// answers, which is why `amazon`, `amazon pay` and `cred store` are all
/// proposed and all declined.
///
/// Adjacency is computed once per snapshot build against the already-confirmed
/// set. There is no fixed-point loop, and there should not be: answering a
/// candidate reloads the snapshot, so confirming `cheq digital privat` surfaces
/// `cheq` on the very next build. The fixed point is reached across builds,
/// driven by the user's answers — the only place it can honestly be driven
/// from.
class CardSettlementCandidateFinder {
  const CardSettlementCandidateFinder();

  /// The shortest merchant that may take part in an adjacency comparison.
  /// Without a floor a two-character payee is a prefix of half the corpus.
  static const minAdjacencyPrefixLength = 4;

  List<CardSettlementCandidate> find(
    List<ParsedTxn> active,
    CardSettlementFronts decisions,
  ) {
    final out = <CardSettlementCandidate>[];
    final proposed = <String>{};

    for (final pair in const CardSettlementPairer().pairs(active)) {
      final key = merchantFrontKey(pair.debit);
      if (key == null) continue;
      if (decisions.isDecided(key) || !proposed.add(key)) continue;
      out.add(
        CardSettlementCandidate(
          merchantNorm: key,
          displayMerchant: pair.debit.merchant!,
          source: CardSettlementCandidateSource.paired,
          debit: pair.debit,
          ack: pair.ack,
        ),
      );
    }

    final confirmed = decisions.confirmed;
    if (confirmed.isEmpty) return out;

    for (final txn in active) {
      if (txn.direction != TransactionDirection.debit) continue;
      if (txn.instrument != PaymentInstrument.bank) continue;
      final key = merchantFrontKey(txn);
      if (key == null) continue;
      if (decisions.isDecided(key) || proposed.contains(key)) continue;
      final front = _adjacentFront(key, confirmed);
      if (front == null) continue;
      proposed.add(key);
      out.add(
        CardSettlementCandidate(
          merchantNorm: key,
          displayMerchant: txn.merchant!,
          source: CardSettlementCandidateSource.adjacent,
          debit: txn,
          adjacentTo: front,
        ),
      );
    }
    return out;
  }

  /// The confirmed front [key] is a truncation of, or is truncated by. Prefix
  /// in either direction, because the bank truncates at an arbitrary length and
  /// which spelling gets confirmed first depends only on which payment paired.
  String? _adjacentFront(String key, Set<String> confirmed) {
    for (final front in confirmed) {
      final shorter = key.length <= front.length ? key : front;
      final longer = key.length <= front.length ? front : key;
      if (shorter.length < minAdjacencyPrefixLength) continue;
      if (longer.startsWith(shorter)) return front;
    }
    return null;
  }
}
