import 'package:expense_insight/data/sms_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmsScanOutcome', () {
    test(
      'success may contain an empty message list without implying failure',
      () {
        final outcome = SmsScanOutcome.success(const []);

        expect(outcome.status, SmsScanStatus.success);
        expect(outcome.isSuccess, isTrue);
        expect(outcome.messages, isEmpty);
      },
    );

    test(
      'non-success outcomes carry status and never expose parsed messages',
      () {
        final outcome = SmsScanOutcome.failure(
          SmsScanStatus.permissionPermanentlyDenied,
          message: 'Open Settings to allow SMS access.',
        );

        expect(outcome.isSuccess, isFalse);
        expect(outcome.status.storageValue, 'permissionPermanentlyDenied');
        expect(outcome.messages, isEmpty);
        expect(outcome.message, 'Open Settings to allow SMS access.');
      },
    );
  });

  group('ParsedTxn', () {
    test('captures local date and month fields at ingest time', () {
      final txn = ParsedTxn(
        smsId: 'provider:42',
        sender: 'VM-HDFCBK',
        direction: TransactionDirection.debit,
        instrument: PaymentInstrument.bank,
        type: TxnType.upi,
        amountPaise: 12345,
        txnDate: DateTime(2026, 7, 9, 18, 45),
        payeeType: PayeeType.merchant,
        categoryKey: 'groceries',
        confidence: 0.95,
        reviewStatus: ReviewStatus.needsReview,
        source: TxnSource.sms,
        coverageBucket: CoverageBucket.reviewPending,
        rawBodyRedacted: 'debited rs. [amount]',
        bodyHash: 'abc',
        scanBatchId: 'scan-1',
      );

      expect(txn.txnLocalDate, '2026-07-09');
      expect(txn.txnMonth, '2026-07');
      expect(txn.needsReview, isTrue);
    });

    test('enum storage values match the SQLite contract', () {
      expect(TransactionDirection.debit.storageValue, 'debit');
      expect(PaymentInstrument.card.storageValue, 'card');
      expect(TxnType.transfer.storageValue, 'transfer');
      expect(PayeeType.p2pIndividual.storageValue, 'p2p_individual');
      expect(ReviewStatus.autoAdded.storageValue, 'auto_added');
      expect(
        CoverageBucket.quantifiedExcluded.storageValue,
        'quantified_excluded',
      );
    });
  });
}
