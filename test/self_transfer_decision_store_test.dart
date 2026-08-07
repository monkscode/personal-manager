// The detector only ever proposes. What makes a pair a self-transfer is the
// user saying so, and that answer has to survive the next scan — otherwise the
// same four rows come back every time and the user re-answers them forever.
//
// A rejection is stored just as durably as a confirmation. Two of the owner's
// five own-name debits are genuine payments to someone who shares their name,
// and the 2022 Flipkart pair is a coincidence; if "no" were not persisted,
// those three would be re-proposed on every scan.
import 'package:expense_insight/data/self_transfer_decision_store.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late SelfTransferDecisionStore store;

  setUp(() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    store = SelfTransferDecisionStore(db);
  });

  test('a confirmed pair is remembered', () async {
    await store.record(
      debitSmsId: 'debit-hdfc',
      creditSmsId: 'credit-axis',
      confirmed: true,
    );

    final decisions = await store.all();

    expect(decisions.isConfirmed('debit-hdfc'), isTrue);
    expect(decisions.isDecided('debit-hdfc'), isTrue);
  });

  test('a rejected pair is remembered as rejected, not as unknown', () async {
    await store.record(
      debitSmsId: 'debit-6000',
      creditSmsId: 'credit-none',
      confirmed: false,
    );

    final decisions = await store.all();

    expect(decisions.isConfirmed('debit-6000'), isFalse);
    expect(
      decisions.isDecided('debit-6000'),
      isTrue,
      reason: 'a rejected pair must never be proposed again',
    );
  });

  test('an undecided pair is neither confirmed nor decided', () async {
    final decisions = await store.all();

    expect(decisions.isConfirmed('never-seen'), isFalse);
    expect(decisions.isDecided('never-seen'), isFalse);
  });

  test('changing an answer replaces it rather than adding a second', () async {
    await store.record(
      debitSmsId: 'debit-hdfc',
      creditSmsId: 'credit-axis',
      confirmed: true,
    );
    await store.record(
      debitSmsId: 'debit-hdfc',
      creditSmsId: 'credit-axis',
      confirmed: false,
    );

    final decisions = await store.all();

    expect(decisions.isConfirmed('debit-hdfc'), isFalse);
    expect(decisions.isDecided('debit-hdfc'), isTrue);
  });
}
