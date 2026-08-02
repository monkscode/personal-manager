import '../data/known_accounts_store.dart';
import '../data/sms_models.dart';

/// Minimum P2P outflow occurrences before it may be promoted to a recurring
/// commitment without explicit user confirmation (decision D5).
const int kP2pOutflowMinOccurrences = 4;

/// UPI handles that denote a wallet top-up (money leaving into a wallet becomes
/// untracked cash for coverage purposes).
///
/// The handle alone is not sufficient evidence — see [kMerchantVpaPrefixes].
const Set<String> kWalletVpaHandles = {
  'paytm',
  'freecharge',
  'mobikwik',
  'amazonpay',
  'olamoney',
};

/// VPA local-part prefixes that name a merchant collection account rather than
/// a consumer wallet, even on a wallet handle.
///
/// Every shop QR code in India is `paytmqr<digits>@paytm`, so matching on the
/// handle alone reports a kirana store, a chai stall or a petrol pump as a
/// wallet top-up. Those rows then carry [PayeeClassification.untrackedCashCaveat]
/// and drop out of tracked coverage — a user who pays for most things by QR sees
/// their perfectly trackable spend reported as untracked cash, and the coverage
/// metrics that drive confidence messaging are wrong.
final RegExp kMerchantVpaPrefixes = RegExp(r'^(?:paytmqr|merchant)');

/// The person-to-merchant tag banks stamp on a UPI alert (`UPI/P2M/...`).
///
/// Unambiguous where the handle is not, and present in many Axis and ICICI
/// formats. It survives redaction — only the numeric reference beside it is
/// replaced — so it can be read off the stored redacted body. Its counterpart
/// `UPI/P2A` (person-to-account) carries no merchant claim and is not consulted.
final RegExp kP2mTag = RegExp(r'\bupi[/\-]p2m\b', caseSensitive: false);

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

  /// Ambiguous P2P **outflow** that must be user-confirmed before it counts.
  /// Always false for an inflow — money arriving from an individual is income
  /// to classify, not a commitment to gate.
  final bool needsConfirmation;

  /// Wallet **top-up** whose spend is untracked and should carry a cash caveat.
  /// Always false for an inflow — money coming back out of a wallet is landing
  /// in a tracked account, so it is the opposite of untracked cash.
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
    // Merchant evidence outranks the wallet handle but never the user's own
    // account: money moving between the holder's accounts is a self-transfer
    // whichever VPA it lands on.
    final isMerchant =
        !isSelf &&
        (_isMerchantVpa(txn.upiVpaNorm) || kP2mTag.hasMatch(txn.rawBodyRedacted));
    final isWallet =
        !isSelf &&
        !isMerchant &&
        (txn.payeeType == PayeeType.wallet || _isWalletVpa(txn.upiVpaNorm));

    final PayeeType payeeType;
    if (isSelf) {
      payeeType = PayeeType.selfTransfer;
    } else if (isMerchant) {
      payeeType = PayeeType.merchant;
    } else if (isWallet) {
      payeeType = PayeeType.wallet;
    } else {
      payeeType = txn.payeeType;
    }

    // Both flags describe money *leaving*, so they are gated on direction here
    // rather than left for each caller to remember — the counterparty is
    // classified the same way either way, but an inflow neither needs P2P
    // confirmation nor becomes untracked cash.
    final isOutflow = txn.direction == TransactionDirection.debit;

    return PayeeClassification(
      payeeType: payeeType,
      isSelfTransfer: isSelf,
      needsConfirmation: isOutflow && payeeType == PayeeType.p2pIndividual,
      untrackedCashCaveat: isOutflow && payeeType == PayeeType.wallet,
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

  bool _isMerchantVpa(String? vpaNorm) {
    if (vpaNorm == null) return false;
    final at = vpaNorm.lastIndexOf('@');
    if (at <= 0) return false;
    return kMerchantVpaPrefixes.hasMatch(vpaNorm.substring(0, at).toLowerCase());
  }
}
