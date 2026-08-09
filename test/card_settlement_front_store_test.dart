// The pairer only ever proposes. What makes a merchant a card-bill payment
// front is the user saying so, and that answer has to outlive the next scan.
//
// Keyed on the merchant, not on an sms_id — which is the whole point. One
// answer for `cheq digital privat` settles all 11 of its payments, including
// the 8 that carry no card acknowledgement to pair against (spec fact 9,
// Rs.3,17,559). A rejection is stored just as durably: `shree arbuda statio`
// paired once by coincidence, and without a stored "no" it would be re-proposed
// after every scan and could never be safely acted on.
import 'package:expense_insight/data/card_settlement_front_store.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late CardSettlementFrontStore store;

  setUp(() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    store = CardSettlementFrontStore(db);
  });

  test('a confirmed front is remembered', () async {
    await store.record(
      merchantNorm: 'cred club',
      confirmed: true,
      exampleDebitSmsId: 'debit-1',
      exampleAckSmsId: 'ack-1',
    );

    final fronts = await store.all();

    expect(fronts.isConfirmed('cred club'), isTrue);
    expect(fronts.isDecided('cred club'), isTrue);
    expect(fronts.confirmed, {'cred club'});
  });

  test('a rejection is decided but never confirmed', () async {
    await store.record(
      merchantNorm: 'shree arbuda statio',
      confirmed: false,
      exampleDebitSmsId: 'debit-2',
      exampleAckSmsId: 'ack-2',
    );

    final fronts = await store.all();

    expect(fronts.isDecided('shree arbuda statio'), isTrue);
    expect(fronts.isConfirmed('shree arbuda statio'), isFalse);
    expect(fronts.confirmed, isEmpty);
  });

  test('an unanswered merchant is neither decided nor confirmed', () async {
    final fronts = await store.all();

    expect(fronts.isDecided('cheq'), isFalse);
    expect(fronts.isConfirmed('cheq'), isFalse);
  });

  test('an adjacency-sourced answer stores no acknowledgement', () async {
    // A source-2 candidate is proposed by string adjacency and has no ack
    // behind it. A NOT NULL column would have had nothing honest to store.
    await store.record(
      merchantNorm: 'cheq',
      confirmed: true,
      exampleDebitSmsId: 'debit-3',
    );

    expect((await store.all()).isConfirmed('cheq'), isTrue);
  });

  test('re-answering replaces rather than stacks', () async {
    await store.record(
      merchantNorm: 'cred store',
      confirmed: true,
      exampleDebitSmsId: 'debit-4',
    );
    await store.record(
      merchantNorm: 'cred store',
      confirmed: false,
      exampleDebitSmsId: 'debit-4',
    );

    final fronts = await store.all();

    expect(fronts.isDecided('cred store'), isTrue);
    expect(fronts.isConfirmed('cred store'), isFalse);
  });

  test('empty is a usable zero value', () {
    expect(CardSettlementFronts.empty.isDecided('anything'), isFalse);
    expect(CardSettlementFronts.empty.confirmed, isEmpty);
  });
}
