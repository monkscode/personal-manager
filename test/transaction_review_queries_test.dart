import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ParsedTxn row({
  required String smsId,
  required String scanBatchId,
  required DateTime date,
  ReviewStatus reviewStatus = ReviewStatus.needsReview,
  ReviewReason? reviewReason = ReviewReason.firstScan,
  DateTime? autoAddedAt,
  double confidence = 0.95,
  int amountPaise = 10000,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: date,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: confidence,
  reviewStatus: reviewStatus,
  reviewReason: reviewReason,
  autoAddedAt: autoAddedAt,
  source: TxnSource.sms,
  coverageBucket: reviewStatus == ReviewStatus.needsReview
      ? CoverageBucket.reviewPending
      : CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'hash-$smsId',
  scanBatchId: scanBatchId,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late TransactionRepository repo;

  setUp(() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    repo = TransactionRepository(db);
  });

  test('queryByScanBatch returns only that batch, oldest first', () async {
    await repo.upsertParsedTxn(
      row(smsId: 'a', scanBatchId: 'b1', date: DateTime(2026, 7, 5, 9)),
    );
    await repo.upsertParsedTxn(
      row(smsId: 'b', scanBatchId: 'b1', date: DateTime(2026, 7, 5, 8)),
    );
    await repo.upsertParsedTxn(
      row(smsId: 'c', scanBatchId: 'b2', date: DateTime(2026, 7, 5, 7)),
    );

    final batch = await repo.queryByScanBatch('b1');

    expect(batch.map((t) => t.smsId).toList(), ['b', 'a']);
  });

  test('queryByReviewStatus filters by status', () async {
    await repo.upsertParsedTxn(
      row(smsId: 'a', scanBatchId: 'b1', date: DateTime(2026, 7, 5)),
    );
    await repo.upsertParsedTxn(
      row(
        smsId: 'b',
        scanBatchId: 'b1',
        date: DateTime(2026, 7, 6),
        reviewStatus: ReviewStatus.autoAdded,
        reviewReason: null,
        autoAddedAt: DateTime(2026, 7, 6),
      ),
    );

    final review = await repo.queryByReviewStatus(ReviewStatus.needsReview);
    final auto = await repo.queryByReviewStatus(ReviewStatus.autoAdded);

    expect(review.map((t) => t.smsId), ['a']);
    expect(auto.map((t) => t.smsId), ['b']);
  });

  test('recentlyAutoAdded returns auto-added rows newest first', () async {
    await repo.upsertParsedTxn(
      row(
        smsId: 'old',
        scanBatchId: 'b1',
        date: DateTime(2026, 7, 1),
        reviewStatus: ReviewStatus.autoAdded,
        reviewReason: null,
        autoAddedAt: DateTime(2026, 7, 1, 10),
      ),
    );
    await repo.upsertParsedTxn(
      row(
        smsId: 'new',
        scanBatchId: 'b1',
        date: DateTime(2026, 7, 2),
        reviewStatus: ReviewStatus.autoAdded,
        reviewReason: null,
        autoAddedAt: DateTime(2026, 7, 2, 10),
      ),
    );
    await repo.upsertParsedTxn(
      row(smsId: 'review', scanBatchId: 'b1', date: DateTime(2026, 7, 3)),
    );

    final recent = await repo.recentlyAutoAdded();

    expect(recent.map((t) => t.smsId).toList(), ['new', 'old']);
  });

  test('dismiss keeps the row queryable for audit but out of active statuses', () async {
    await repo.upsertParsedTxn(
      row(smsId: 'a', scanBatchId: 'b1', date: DateTime(2026, 7, 5)),
    );

    await repo.updateReviewStatus('a', ReviewStatus.dismissed);

    expect(await repo.queryByReviewStatus(ReviewStatus.needsReview), isEmpty);
    final dismissed = await repo.queryByReviewStatus(ReviewStatus.dismissed);
    expect(dismissed.single.smsId, 'a');
  });

  test('confirm clears needs_review and marks the row confirmed', () async {
    await repo.upsertParsedTxn(
      row(smsId: 'a', scanBatchId: 'b1', date: DateTime(2026, 7, 5)),
    );

    await repo.updateReviewStatus(
      'a',
      ReviewStatus.confirmed,
      coverageBucket: CoverageBucket.datedEvent,
    );

    final confirmed = await repo.queryByReviewStatus(ReviewStatus.confirmed);
    expect(confirmed.single.smsId, 'a');
    expect(confirmed.single.needsReview, isFalse);
    expect(confirmed.single.coverageBucket, CoverageBucket.datedEvent);
  });
}
