import 'package:expense_insight/data/known_accounts_store.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/payee_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn outflow({
  String? upiVpaNorm,
  PayeeType payeeType = PayeeType.unknown,
  String? accountLast4 = '1111',
}) => ParsedTxn(
  smsId: 'sms:${upiVpaNorm ?? payeeType.name}',
  sender: 'VM-HDFCBK',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: 50000,
  txnDate: DateTime(2026, 7, 5),
  accountLast4: accountLast4,
  upiVpaNorm: upiVpaNorm,
  payeeType: payeeType,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'r',
  bodyHash: 'h',
  scanBatchId: 'b',
);

KnownAccounts knownWith({List<String> vpas = const [], List<String> last4s = const []}) {
  return KnownAccounts([
    for (final v in vpas)
      KnownAccount(vpaNorm: v, label: 'own', origin: 'user_marked', createdAt: DateTime(2026)),
    for (final l in last4s)
      KnownAccount(last4: l, label: 'own', origin: 'user_marked', createdAt: DateTime(2026)),
  ]);
}

void main() {
  const classifier = PayeeClassifier();

  group('classify', () {
    test('a transfer to a known own VPA is a self-transfer', () {
      final result = classifier.classify(
        outflow(upiVpaNorm: 'me@ybl', payeeType: PayeeType.p2pIndividual),
        known: knownWith(vpas: ['me@ybl']),
      );

      expect(result.isSelfTransfer, isTrue);
      expect(result.payeeType, PayeeType.selfTransfer);
      expect(result.needsConfirmation, isFalse);
    });

    test('an unknown P2P outflow is held for confirmation', () {
      final result = classifier.classify(
        outflow(upiVpaNorm: 'rahul@oksbi', payeeType: PayeeType.p2pIndividual),
        known: knownWith(),
      );

      expect(result.isSelfTransfer, isFalse);
      expect(result.payeeType, PayeeType.p2pIndividual);
      expect(result.needsConfirmation, isTrue);
    });

    test('a wallet top-up emits an untracked-cash caveat', () {
      final result = classifier.classify(
        outflow(upiVpaNorm: 'user@paytm'),
        known: knownWith(),
      );

      expect(result.payeeType, PayeeType.wallet);
      expect(result.untrackedCashCaveat, isTrue);
    });

    test('a normal merchant is neither self, P2P, nor wallet', () {
      final result = classifier.classify(
        outflow(upiVpaNorm: 'swiggy@okhdfc', payeeType: PayeeType.merchant),
        known: knownWith(),
      );

      expect(result.payeeType, PayeeType.merchant);
      expect(result.isSelfTransfer, isFalse);
      expect(result.needsConfirmation, isFalse);
      expect(result.untrackedCashCaveat, isFalse);
    });
  });

  group('shouldPromoteP2pOutflow (D5)', () {
    PayeeClassification p2p() => classifier.classify(
      outflow(upiVpaNorm: 'rahul@oksbi', payeeType: PayeeType.p2pIndividual),
      known: knownWith(),
    );

    test('does not promote below the occurrence threshold', () {
      expect(
        classifier.shouldPromoteP2pOutflow(p2p(), occurrences: 3, userConfirmed: false),
        isFalse,
      );
    });

    test('promotes at or above the occurrence threshold', () {
      expect(
        classifier.shouldPromoteP2pOutflow(p2p(), occurrences: 4, userConfirmed: false),
        isTrue,
      );
    });

    test('promotes immediately when the user confirms', () {
      expect(
        classifier.shouldPromoteP2pOutflow(p2p(), occurrences: 1, userConfirmed: true),
        isTrue,
      );
    });

    test('never promotes a self-transfer as a P2P commitment', () {
      final self = classifier.classify(
        outflow(upiVpaNorm: 'me@ybl'),
        known: knownWith(vpas: ['me@ybl']),
      );
      expect(
        classifier.shouldPromoteP2pOutflow(self, occurrences: 10, userConfirmed: true),
        isFalse,
      );
    });
  });

  group('named constants', () {
    test('encode the D5 default', () {
      expect(kP2pOutflowMinOccurrences, 4);
    });
  });
}
