import 'package:sqflite/sqflite.dart';

/// The user's answers to "is this a transfer between your own accounts?",
/// keyed by the debit leg's `sms_id`.
///
/// A rejection is held as firmly as a confirmation. `isDecided` is what stops a
/// pair being proposed twice, and `isConfirmed` is what stops the money being
/// counted as spend — a rejected pair is decided but not confirmed.
class SelfTransferDecisions {
  const SelfTransferDecisions(this._byDebitSmsId);

  final Map<String, SelfTransferDecision> _byDebitSmsId;

  /// Whether the user has answered for this debit, either way.
  bool isDecided(String debitSmsId) => _byDebitSmsId.containsKey(debitSmsId);

  /// Whether the user said this debit is money moving between their accounts.
  bool isConfirmed(String debitSmsId) =>
      _byDebitSmsId[debitSmsId]?.confirmed ?? false;

  /// Every `sms_id` on a confirmed pair — **both** legs.
  ///
  /// The credit is included deliberately: it is the same rupees arriving on the
  /// user's other account, and an unmarked inbound leg is read as income.
  Set<String> get confirmedSmsIds => {
    for (final entry in _byDebitSmsId.entries)
      if (entry.value.confirmed) ...[entry.key, entry.value.creditSmsId],
  };
}

/// One stored answer: the credit leg it was paired against, and the verdict.
class SelfTransferDecision {
  const SelfTransferDecision({
    required this.creditSmsId,
    required this.confirmed,
  });

  final String creditSmsId;
  final bool confirmed;
}

/// Local persistence for self-transfer confirmations, in the backup-excluded
/// `transactions.db` beside the rows it decides about.
class SelfTransferDecisionStore {
  const SelfTransferDecisionStore(this._db);

  final DatabaseExecutor _db;

  Future<SelfTransferDecisions> all() async {
    final rows = await _db.query('self_transfer_decisions');
    return SelfTransferDecisions({
      for (final row in rows)
        row['debit_sms_id']! as String: SelfTransferDecision(
          creditSmsId: row['credit_sms_id']! as String,
          confirmed: (row['confirmed']! as int) == 1,
        ),
    });
  }

  /// Records the user's answer. Keyed on the debit leg, so re-answering
  /// replaces the previous decision instead of stacking a second one.
  Future<void> record({
    required String debitSmsId,
    required String creditSmsId,
    required bool confirmed,
    DateTime? now,
  }) => _db.insert('self_transfer_decisions', {
    'debit_sms_id': debitSmsId,
    'credit_sms_id': creditSmsId,
    'confirmed': confirmed ? 1 : 0,
    'decided_at': (now ?? DateTime.now()).millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}
