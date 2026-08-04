import 'package:expense_insight/data/sms_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  group('SmsDatabase', () {
    test('uses the database name excluded by Android backup rules', () {
      expect(SmsDatabase.databaseName, 'transactions.db');
      // Pinned so a bump is always a deliberate act: it is what makes every
      // existing install re-open through `onUpgrade`.
      expect(SmsDatabase.schemaVersion, 5);
    });

    test('creates transactions, obligations, and indexes', () async {
      final db = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);

      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name;",
      );
      final tableNames = tables.map((row) => row['name']).toSet();

      expect(tableNames, contains('transactions'));
      expect(tableNames, contains('obligations'));

      final indexes = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name;",
      );
      final indexNames = indexes.map((row) => row['name']).toSet();

      expect(indexNames, contains('idx_transactions_txn_month'));
      expect(indexNames, contains('idx_transactions_scan_batch_id'));
      expect(indexNames, contains('idx_obligations_dedupe_key'));
    });

    // TASK-27 M4 — sqflite's `singleInstance` defaults to true, so two handles
    // opened on the same path are the same database. Every test in this repo
    // uses `:memory:`, so any test opening a second handle would silently share
    // state with the first and pass for the wrong reason.
    test('two in-memory handles are independent databases', () async {
      final first = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(first.close);
      final second = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(second.close);

      await first.insert('meta', {'key': 'probe', 'value': 'first'});

      expect(await second.query('meta'), isEmpty);
    });
  });
}
