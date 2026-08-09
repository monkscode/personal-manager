import 'package:sqflite/sqflite.dart';

/// The user's answers to "is this merchant how you pay a card bill?", keyed by
/// the normalised merchant string.
///
/// Keyed by merchant and not by `sms_id` — the one deliberate departure from
/// [SelfTransferDecisionStore], and the reason this design works. One answer
/// for `cheq digital privat` settles all 11 of its payments, whether or not
/// any individual payment happens to pair with a card acknowledgement —
/// that is the point of keying on the merchant rather than the payment.
///
/// This docstring used to put a number on the ones pairing cannot reach ("the
/// 8 with no card acknowledgement to pair against"). Re-measured 2026-08-09
/// against `.private/transactions.db`, it is 2 of the 11, not 8 — see
/// `sms_storage_schema.dart`'s `createCardSettlementFrontsTable` docstring for
/// the figures and `card_settlement_pairer.dart`'s module docstring for why
/// the spec's pairing counts do not reproduce. The design does not depend on
/// which number is right.
///
/// [isDecided] is what stops a merchant being proposed twice; [isConfirmed] is
/// what stops the money being counted as spend. A rejected merchant is decided
/// but not confirmed, and the difference is load-bearing: `shree arbuda statio`
/// paired once by coincidence and must never be asked about again, nor ever
/// excluded.
class CardSettlementFronts {
  const CardSettlementFronts(this._byMerchantNorm);

  /// No answers yet — every merchant is undecided and nothing is excluded.
  static const empty = CardSettlementFronts(<String, bool>{});

  final Map<String, bool> _byMerchantNorm;

  /// Whether the user has answered for this merchant, either way.
  bool isDecided(String merchantNorm) =>
      _byMerchantNorm.containsKey(merchantNorm);

  /// Whether the user said payments to this merchant settle a card bill.
  bool isConfirmed(String merchantNorm) =>
      _byMerchantNorm[merchantNorm] ?? false;

  /// Every merchant the user confirmed. This is the only set the spend lens
  /// consults.
  Set<String> get confirmed => {
    for (final entry in _byMerchantNorm.entries)
      if (entry.value) entry.key,
  };
}

/// Local persistence for card-settlement front answers, in the
/// backup-excluded `transactions.db` beside the rows they decide about.
///
/// Deliberately dumb: it stores the key it is given and normalises nothing.
/// Normalisation is [merchantFrontKey]'s job, in `money_lens.dart`, so the
/// lens and the store cannot drift apart on what a key is.
class CardSettlementFrontStore {
  const CardSettlementFrontStore(this._db);

  final DatabaseExecutor _db;

  Future<CardSettlementFronts> all() async {
    final rows = await _db.query('card_settlement_fronts');
    return CardSettlementFronts({
      for (final row in rows)
        row['merchant_norm']! as String: (row['confirmed']! as int) == 1,
    });
  }

  /// Records the user's answer. Keyed on the merchant, so re-answering replaces
  /// the previous decision instead of stacking a second one.
  ///
  /// [exampleAckSmsId] is null for a merchant proposed by string adjacency: it
  /// has no acknowledgement behind it, only a resemblance to a confirmed front.
  /// Both ids are evidence rather than keys — they let a later reader
  /// reconstruct why a front was confirmed.
  Future<void> record({
    required String merchantNorm,
    required bool confirmed,
    required String exampleDebitSmsId,
    String? exampleAckSmsId,
    DateTime? now,
  }) => _db.insert('card_settlement_fronts', {
    'merchant_norm': merchantNorm,
    'confirmed': confirmed ? 1 : 0,
    'example_debit_sms_id': exampleDebitSmsId,
    'example_ack_sms_id': exampleAckSmsId,
    'decided_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
