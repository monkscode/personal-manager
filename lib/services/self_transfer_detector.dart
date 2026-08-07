import '../data/sms_models.dart';

/// A debit and the credit that received it, proposed as one movement between
/// two accounts the user holds.
class SelfTransferCandidate {
  const SelfTransferCandidate({required this.debit, required this.credit});

  final ParsedTxn debit;
  final ParsedTxn credit;
}

/// Finds bank debits that were met by a matching credit on another of the
/// user's own accounts.
class SelfTransferDetector {
  const SelfTransferDetector();

  List<SelfTransferCandidate> candidates(List<ParsedTxn> txns) {
    final credits = [
      for (final t in txns)
        if (t.direction == TransactionDirection.credit && _isBank(t)) t,
    ];
    final out = <SelfTransferCandidate>[];
    for (final debit in txns) {
      if (debit.direction != TransactionDirection.debit) continue;
      if (!_isBank(debit)) continue;
      for (final credit in credits) {
        if (credit.amountPaise != debit.amountPaise) continue;
        if (_dayGap(debit.txnDate, credit.txnDate) > 1) continue;
        if (!_differentOwnAccounts(debit, credit)) continue;
        out.add(SelfTransferCandidate(debit: debit, credit: credit));
        break;
      }
    }
    return out;
  }

  /// A credit-card bill settlement is one event the bank announces twice — the
  /// debit leaving the account and the card acknowledging the same rupees —
  /// so it agrees on amount, day and "different account" by construction. It
  /// is the single biggest source of false pairs: requiring both legs to be
  /// bank rows takes the owner's device from 119 matches to 4.
  bool _isBank(ParsedTxn t) => t.instrument == PaymentInstrument.bank;

  /// Both legs must name an account, and they must not be the same one: a
  /// transfer that starts and ends in one account is not a transfer.
  bool _differentOwnAccounts(ParsedTxn debit, ParsedTxn credit) {
    final from = debit.accountLast4?.trim() ?? '';
    final to = credit.accountLast4?.trim() ?? '';
    return from.isNotEmpty && to.isNotEmpty && from != to;
  }

  int _dayGap(DateTime a, DateTime b) => DateTime(a.year, a.month, a.day)
      .difference(DateTime(b.year, b.month, b.day))
      .inDays
      .abs();
}
