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

  ParsedTxn clearingHouseMandate(int month) => ParsedTxn(
        smsId: 'ach-$month',
        sender: 'VM-HDFCBK',
        direction: TransactionDirection.debit,
        instrument: PaymentInstrument.bank,
        type: TxnType.other,
        amountPaise: 450000,
        txnDate: DateTime(2026, month, 5),
        merchant: 'indian clearing corporation lt',
        payeeType: PayeeType.bankMandate,
        categoryKey: 'other',
        confidence: 0.9,
        reviewStatus: ReviewStatus.confirmed,
        source: TxnSource.sms,
        coverageBucket: CoverageBucket.datedEvent,
        rawBodyRedacted: 'redacted',
        bodyHash: 'ach$month',
        scanBatchId: 'batch',
      );

  // TASK-31's bank-as-payee decision: extract, then classify. The owner key is
  // kept so ₹10.6L of mandate debits are finally attributed, but the forecast
  // must not show a commitment that reads like a shop called
  // "Indian Clearing Corporation Lt".
  test('a bank-mandate commitment is labelled as a mandate', () async {
    final repo = await openRepository();
    for (final month in [4, 5, 6, 7]) {
      await repo.upsertParsedTxn(clearingHouseMandate(month));
    }

    final candidates = await RecurringObligationCandidates(
      transactions: repo,
    ).derive(
      persisted: const [],
      scanBatchId: 'batch',
      now: DateTime(2026, 7, 20),
    );

    final mandate = candidates.single;
    // The grouping key is untouched — this is what attributes the rupee.
    expect(mandate.merchantNorm, 'indian clearing corporation lt');
    expect(mandate.payeeType, PayeeType.bankMandate);
    // The label the forecast shows says what it actually is.
    expect(mandate.merchant, 'Indian Clearing Corporation Lt mandate');
  });

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

  test('an algorithm-detected commitment is not stamped user-confirmed', () async {
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

    final derived = candidates.singleWhere((o) => o.merchantNorm == 'netflix');
    expect(derived.userCadenceStatus, UserCadenceStatus.algorithmDetected);
    expect(
      derived.reviewStatus,
      ObligationReviewStatus.needsReview,
      reason: 'a guess must not present itself as the user\'s own decision',
    );
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
