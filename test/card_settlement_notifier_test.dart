// The answer has to reach the snapshot, and reach it without a rescan. The
// predicates are re-derived at read time, so a confirmation corrects rows
// already on disk on the very next build -- no migration, no re-parse.
import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/card_settlement_front_store.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Database db;
  late ProviderContainer container;

  final credDebit = ParsedTxn(
    smsId: 'cred-debit',
    sender: 'VM-HDFCBK-S',
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    type: TxnType.upi,
    amountPaise: 228200,
    txnDate: DateTime(2026, 8, 1),
    accountLast4: '4501',
    merchant: 'CRED Club',
    payeeType: PayeeType.merchant,
    categoryKey: 'other',
    confidence: 0.9,
    reviewStatus: ReviewStatus.autoAdded,
    source: TxnSource.sms,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'Sent [amount] From HDFC Bank A/C [account] To CRED Club',
    bodyHash: 'h1',
    scanBatchId: 'b',
  );

  setUp(() async {
    db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    await TransactionRepository(db).ingestParsedTxn(credDebit, isFirstScan: true);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        smsDatabaseProvider.overrideWithValue(db),
        analysisClockProvider.overrideWithValue(() => DateTime(2026, 8, 8)),
      ],
    );
    addTearDown(container.dispose);
  });

  test('with no answer the payment is still counted as spend', () async {
    final snapshot = await container.read(transactionsNotifierProvider.future);

    expect(
      snapshot.spendLensTxns.map((t) => t.smsId),
      contains('cred-debit'),
    );
  });

  test('a recorded answer reaches the snapshot without a rescan', () async {
    await container
        .read(transactionsNotifierProvider.notifier)
        .recordSettlementFront(
          merchantNorm: 'cred club',
          confirmed: true,
          exampleDebitSmsId: 'cred-debit',
        );

    final snapshot = await container.read(transactionsNotifierProvider.future);

    expect(snapshot.confirmedSettlementFronts, contains('cred club'));
    expect(
      snapshot.spendLensTxns.map((t) => t.smsId),
      isNot(contains('cred-debit')),
    );
    expect((await CardSettlementFrontStore(db).all()).isConfirmed('cred club'),
        isTrue);
  });
}
