import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn txn({required double confidence, String smsId = 'provider:1'}) {
  return ParsedTxn(
    smsId: smsId,
    sender: 'VM-HDFCBK',
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    type: TxnType.upi,
    amountPaise: 10000,
    txnDate: DateTime(2026, 7, 9, 9),
    payeeType: PayeeType.merchant,
    categoryKey: 'other',
    confidence: confidence,
    reviewStatus: ReviewStatus.autoAdded,
    source: TxnSource.sms,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'redacted',
    bodyHash: 'hash',
    scanBatchId: 'batch',
  );
}

void main() {
  group('D9 auto-add threshold', () {
    test('is the interim 0.8 pending the Phase I golden corpus', () {
      expect(kAutoAddConfidenceThreshold, 0.8);
    });

    test('confidence at the threshold auto-adds on a later scan', () {
      final decision = SmsIngestionPolicy.classify(
        incoming: txn(confidence: kAutoAddConfidenceThreshold),
        existing: const [],
        isFirstScan: false,
      );

      expect(decision.action, IngestionAction.upsert);
      expect(decision.transaction.reviewStatus, ReviewStatus.autoAdded);
    });

    test('confidence just below the threshold is queued for review', () {
      final decision = SmsIngestionPolicy.classify(
        incoming: txn(confidence: kAutoAddConfidenceThreshold - 0.01),
        existing: const [],
        isFirstScan: false,
      );

      expect(decision.action, IngestionAction.queueReview);
      expect(decision.transaction.reviewReason, ReviewReason.lowConfidence);
    });
  });
}
