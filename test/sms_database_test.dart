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
      expect(SmsDatabase.schemaVersion, 4);
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
  });
}
