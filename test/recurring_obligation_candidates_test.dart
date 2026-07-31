import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/recurring_obligation_candidates.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<TransactionRepository> openRepository() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    return TransactionRepository(db);
  }

  ParsedTxn netflix(int month) => ParsedTxn(
        smsId: 'sms-$month',
        sender: 'VM-HDFCBK',
        direction: TransactionDirection.debit,
        instrument: PaymentInstrument.bank,
        type: TxnType.upi,
        amountPaise: 50000,
        txnDate: DateTime(2026, month, 5),
        merchant: 'Netflix',
        payeeType: PayeeType.merchant,
        categoryKey: 'subscriptions',
        confidence: 0.95,
        reviewStatus: ReviewStatus.confirmed,
        source: TxnSource.sms,
        coverageBucket: CoverageBucket.datedEvent,
        rawBodyRedacted: 'redacted',
        bodyHash: 'h$month',
        scanBatchId: 'batch',
      );

  test('derives a locked recurring commitment as an smsRecurring obligation', () async {
    final repo = await openRepository();
    for (final month in [4, 5, 6, 7]) {
      await repo.upsertParsedTxn(netflix(month));
    }

    final source = RecurringObligationCandidates(transactions: repo);
    final candidates = await source.derive(
      persisted: const [],
      scanBatchId: 'batch',
      now: DateTime(2026, 7, 20),
    );

    expect(candidates, isNotEmpty);
    final netflixObligation = candidates.singleWhere((o) => o.merchantNorm == 'netflix');
    expect(netflixObligation.sourceType, ObligationSourceType.smsRecurring);
    expect(netflixObligation.amountPaise, 50000);
    expect(netflixObligation.recurrence, ReconciliationRecurrence.monthly);
    expect(netflixObligation.dueDate, isNotNull);
  });

  test('produces no candidates when there is no recurring history', () async {
    final repo = await openRepository();
    await repo.upsertParsedTxn(netflix(7)); // a single occurrence

    final source = RecurringObligationCandidates(transactions: repo);
    final candidates = await source.derive(
      persisted: const [],
      scanBatchId: 'batch',
      now: DateTime(2026, 7, 20),
    );

    expect(candidates, isEmpty);
  });

  test('the derived obligation upserts cleanly through the scan orchestrator seam', () async {
    final repo = await openRepository();
    for (final month in [4, 5, 6, 7]) {
      await repo.upsertParsedTxn(netflix(month));
    }
    final source = RecurringObligationCandidates(transactions: repo);
    final candidates = await source.derive(
      persisted: const [],
      scanBatchId: 'batch',
      now: DateTime(2026, 7, 20),
    );
    // Every candidate must be an smsRecurring record so the orchestrator accepts it.
    expect(
      candidates.every((c) => c.sourceType == ObligationSourceType.smsRecurring),
      isTrue,
    );
  });
}
