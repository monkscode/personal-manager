import 'dart:convert';

import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn txn({
  required String smsId,
  required int amountPaise,
  required DateTime date,
  required String scanBatchId,
  String? accountLast4,
  String? refNumber,
  String? merchant,
  double confidence = 0.95,
}) {
  return ParsedTxn(
    smsId: smsId,
    sender: 'VM-HDFCBK',
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    type: TxnType.upi,
    amountPaise: amountPaise,
    txnDate: date,
    accountLast4: accountLast4,
    merchant: merchant,
    payeeType: PayeeType.merchant,
    categoryKey: 'other',
    confidence: confidence,
    reviewStatus: ReviewStatus.autoAdded,
    source: TxnSource.sms,
    refNumber: refNumber,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'redacted',
    bodyHash: 'hash',
    scanBatchId: scanBatchId,
  );
}

void main() {
  group('SmsIngestionPolicy.classify', () {
    test(
      'drops exact provider-id duplicates without creating review noise',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
        );
        final incoming = txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'new',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'routes same amount/day/account/direction with no distinguishing signal to a collision set',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          accountLast4: '1234',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          accountLast4: '1234',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.queueReview);
        expect(decision.transaction.reviewStatus, ReviewStatus.needsReview);
        expect(decision.transaction.reviewReason, ReviewReason.dedupCollision);
        expect(decision.transaction.collisionSetId, isNotNull);
        expect(decision.existingToFlag, isNotNull);
        expect(decision.existingToFlag!.smsId, 'provider:1');
        expect(decision.existingToFlag!.reviewStatus, ReviewStatus.needsReview);
        expect(
          decision.existingToFlag!.collisionSetId,
          decision.transaction.collisionSetId,
        );
      },
    );

    test(
      'skips strong reference-number duplicates tied to the same account and instrument',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          accountLast4: '1234',
          refNumber: '123456789012',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          accountLast4: '1234',
          refNumber: '123456789012',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'first scan reviews all rows and later high confidence rows are auto-added with audit time',
      () {
        final candidate = txn(
          smsId: 'provider:3',
          amountPaise: 90000,
          date: DateTime(2026, 7, 9),
          scanBatchId: 'new',
          refNumber: '987654321098',
          merchant: 'merchant',
        );

        final firstScan = SmsIngestionPolicy.classify(
          incoming: candidate,
          existing: const [],
          isFirstScan: true,
          now: DateTime(2026, 7, 10),
        );
        final laterScan = SmsIngestionPolicy.classify(
          incoming: candidate,
          existing: const [],
          isFirstScan: false,
          now: DateTime(2026, 7, 10),
        );

        expect(firstScan.action, IngestionAction.queueReview);
        expect(firstScan.transaction.reviewReason, ReviewReason.firstScan);
        expect(laterScan.action, IngestionAction.upsert);
        expect(laterScan.transaction.reviewStatus, ReviewStatus.autoAdded);
        expect(laterScan.transaction.autoAddedAt, DateTime(2026, 7, 10));
      },
    );

    test(
      'treats same-ref resends as duplicates without an account last4',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          refNumber: 'RRN12345',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          refNumber: 'RRN12345',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'same ref with a different amount is not a duplicate (RRN reused across legs)',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          refNumber: 'RRN12345',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 75000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          refNumber: 'RRN12345',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, isNot(IngestionAction.skipDuplicate));
      },
    );

    test('collision set ids hash UTF-8 text consistently', () {
      final existing = txn(
        smsId: 'provider:पुराना',
        amountPaise: 50000,
        date: DateTime(2026, 7, 9, 9),
        scanBatchId: 'old',
        accountLast4: '1234',
      );
      final incoming = txn(
        smsId: 'provider:नया',
        amountPaise: 50000,
        date: DateTime(2026, 7, 9, 18),
        scanBatchId: 'new',
        accountLast4: '1234',
      );

      final decision = SmsIngestionPolicy.classify(
        incoming: incoming,
        existing: [existing],
        isFirstScan: false,
      );
      final raw = [
        incoming.amountPaise,
        incoming.txnLocalDate,
        incoming.accountLast4,
        incoming.direction.storageValue,
        existing.smsId,
        incoming.smsId,
      ].join('|');

      expect(
        decision.transaction.collisionSetId,
        'collision:${sha256.convert(utf8.encode(raw))}',
      );
    });
  });
}
