import '../data/known_accounts_store.dart';
import '../data/sms_models.dart';

/// Minimum P2P outflow occurrences before it may be promoted to a recurring
/// commitment without explicit user confirmation (decision D5).
const int kP2pOutflowMinOccurrences = 4;

/// UPI handles that denote a wallet top-up (money leaving into a wallet becomes
/// untracked cash for coverage purposes).
const Set<String> kWalletVpaHandles = {
  'paytm',
  'freecharge',
  'mobikwik',
  'amazonpay',
  'olamoney',
};

/// The classification of a transaction's counterparty.
class PayeeClassification {
  const PayeeClassification({
    required this.payeeType,
    required this.isSelfTransfer,
    required this.needsConfirmation,
    required this.untrackedCashCaveat,
  });

  final PayeeType payeeType;
  final bool isSelfTransfer;

  /// Ambiguous P2P outflow that must be user-confirmed before it counts.
  final bool needsConfirmation;

  /// Wallet top-up whose spend is untracked and should carry a cash caveat.
  final bool untrackedCashCaveat;
}

/// Classifies a transaction's counterparty against the known-accounts allow-list
/// (self-transfer / P2P / wallet / merchant) and gates P2P promotion (spec §7,
/// decision D5).
class PayeeClassifier {
  const PayeeClassifier();

  PayeeClassification classify(ParsedTxn txn, {required KnownAccounts known}) {
    final isSelf = known.containsVpa(txn.upiVpaNorm) ||
        txn.payeeType == PayeeType.selfTransfer;
    final isWallet =
        !isSelf &&
        (txn.payeeType == PayeeType.wallet || _isWalletVpa(txn.upiVpaNorm));

    final PayeeType payeeType;
    if (isSelf) {
      payeeType = PayeeType.selfTransfer;
    } else if (isWallet) {
      payeeType = PayeeType.wallet;
    } else {
      payeeType = txn.payeeType;
    }

    return PayeeClassification(
      payeeType: payeeType,
      isSelfTransfer: isSelf,
      needsConfirmation: payeeType == PayeeType.p2pIndividual,
      untrackedCashCaveat: payeeType == PayeeType.wallet,
    );
  }

  /// Whether a P2P outflow may be promoted to a recurring commitment: never for
  /// a self-transfer (own money movement), otherwise only after user
  /// confirmation or once it reaches [kP2pOutflowMinOccurrences] (D5).
  bool shouldPromoteP2pOutflow(
    PayeeClassification classification, {
    required int occurrences,
    required bool userConfirmed,
  }) {
    if (classification.isSelfTransfer) return false;
    if (classification.payeeType != PayeeType.p2pIndividual) return true;
    return userConfirmed || occurrences >= kP2pOutflowMinOccurrences;
  }

  bool _isWalletVpa(String? vpaNorm) {
    if (vpaNorm == null) return false;
    final at = vpaNorm.lastIndexOf('@');
    if (at < 0 || at + 1 >= vpaNorm.length) return false;
    return kWalletVpaHandles.contains(vpaNorm.substring(at + 1).toLowerCase());
  }
}
