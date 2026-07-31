import 'dart:io';

import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_storage_schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A minimal, schema-valid v1 `transactions` row (all NOT NULL columns set,
/// satisfying the review_status/needs_review CHECK constraint).
const Map<String, Object?> _seedRow = {
  'sms_id': 'provider:seed-1',
  'sender': 'VM-HDFCBK',
  'direction': 'debit',
  'instrument': 'bank',
  'type': 'upi',
  'amount_paise': 125000,
  'txn_date': 1751000000000,
  'txn_local_date': '2025-06-27',
  'txn_month': '2025-06',
  'payee_type': 'merchant',
  'category_key': 'groceries',
  'confidence': 0.95,
  'needs_review': 0,
  'review_status': 'auto_added',
  'scan_batch_id': 'seed-batch',
  'source': 'sms',
  'coverage_bucket': 'dated_event',
  'raw_body_redacted': 'redacted',
  'body_hash': 'seedhash',
  'created_at': 1751000000000,
};

void main() {
  setUpAll(sqfliteFfiInit);

  test(
    'upgrades a seeded v1 database to the current schema, preserving data',
    () async {
      final dir = await Directory.systemTemp.createTemp('sms_migration_test');
      addTearDown(() => dir.delete(recursive: true));
      final path = p.join(dir.path, 'transactions.db');

      // Seed a realistic v1 database: transactions + obligations only. The A2
      // `meta` table, the D4 `known_accounts` table, and the A5 ref index are all
      // added in v2, so they must be absent here for the migration to prove them.
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(SmsStorageSchema.createTransactionsTable);
            await db.execute(_createV1ObligationsTable);
            await db.execute(
              'CREATE INDEX IF NOT EXISTS idx_transactions_txn_month ON transactions(txn_month);',
            );
          },
        ),
      );
      await v1.insert('transactions', _seedRow);
      await v1.close();

      // Reopen through the production options — this runs the real onUpgrade.
      final upgraded = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: path,
      );
      addTearDown(upgraded.close);

      expect(await upgraded.getVersion(), SmsDatabase.schemaVersion);

      // Seeded data survives the migration.
      final rows = await upgraded.query('transactions');
      expect(rows, hasLength(1));
      expect(rows.single['sms_id'], 'provider:seed-1');
      expect(rows.single['amount_paise'], 125000);

      // The v2 tables now exist.
      final tables = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table';",
      )).map((r) => r['name']).toSet();
      expect(tables, containsAll(<String>['meta', 'known_accounts']));

      // The v2 indexes now exist.
      final indexes = (await upgraded.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index';",
      )).map((r) => r['name']).toSet();
      expect(indexes, contains('idx_transactions_ref'));
      expect(indexes, contains('idx_known_accounts_last4'));

      // The migrated meta table is writable (the A2 body-hash salt store needs it).
      await upgraded.insert('meta', {'key': 'schema_probe', 'value': 'ok'});
      final meta = await upgraded.query(
        'meta',
        where: 'key = ?',
        whereArgs: ['schema_probe'],
      );
      expect(meta.single['value'], 'ok');
    },
  );

  test(
    're-running the migration is idempotent (already-current DB is untouched)',
    () async {
      // A fresh install lands directly on the current version via onCreate; a
      // second open must not fail or duplicate anything.
      final db = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(db.close);
      expect(await db.getVersion(), SmsDatabase.schemaVersion);

      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table';",
      )).map((r) => r['name']).toSet();
      expect(
        tables,
        containsAll(<String>[
          'transactions',
          'obligations',
          'meta',
          'known_accounts',
        ]),
      );
    },
  );

  test(
    'every version up to the current one has a registered migration path',
    () {
      for (var v = 2; v <= SmsDatabase.schemaVersion; v++) {
        expect(
          SmsStorageSchema.migrations.containsKey(v),
          isTrue,
          reason: 'missing migration to schema version $v',
        );
      }
    },
  );

  test('upgrades v2 obligations with reserve and risk planning state', () async {
    final dir = await Directory.systemTemp.createTemp('sms_v3_migration_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = p.join(dir.path, 'transactions.db');
    final v2 = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute(SmsStorageSchema.createTransactionsTable);
          await db.execute(_createV2ObligationsTable);
          await db.execute(SmsStorageSchema.createMetaTable);
          await db.execute(SmsStorageSchema.createKnownAccountsTable);
        },
      ),
    );
    await v2.insert('obligations', _seedV2Obligation);
    await v2.close();

    final upgraded = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: path,
    );
    addTearDown(upgraded.close);

    final columns = await upgraded.rawQuery('PRAGMA table_info(obligations)');
    final names = columns.map((row) => row['name']).toSet();
    expect(names, containsAll(['reserve_enabled', 'reserve_funded_paise']));
    expect((await upgraded.query('obligations')).single['merchant'], 'LIC');
    final tables = await upgraded.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'forecast_risk_decisions'",
    );
    expect(tables, hasLength(1));
  });
}

/// v1 obligations table (before reserve columns and before meta/known_accounts).
const _createV1ObligationsTable = '''
CREATE TABLE IF NOT EXISTS obligations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type TEXT NOT NULL,
  source_id TEXT,
  dedupe_key TEXT NOT NULL,
  merchant TEXT NOT NULL,
  merchant_norm TEXT NOT NULL,
  category_key TEXT NOT NULL,
  amount_paise INTEGER,
  amount_status TEXT NOT NULL,
  recurrence TEXT NOT NULL,
  due_date INTEGER,
  due_day INTEGER,
  due_month INTEGER,
  payment_account_hint_last4 TEXT,
  payment_account_scope TEXT NOT NULL,
  amount_paid_paise INTEGER,
  outstanding_paise INTEGER,
  payment_status TEXT NOT NULL,
  next_expected_source TEXT NOT NULL,
  upi_vpa_norm TEXT,
  payee_type TEXT NOT NULL,
  user_cadence_status TEXT NOT NULL,
  confidence REAL NOT NULL,
  review_status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

/// v2 obligations table (before reserve columns).
const _createV2ObligationsTable = '''
CREATE TABLE IF NOT EXISTS obligations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source_type TEXT NOT NULL,
  source_id TEXT,
  dedupe_key TEXT NOT NULL,
  merchant TEXT NOT NULL,
  merchant_norm TEXT NOT NULL,
  category_key TEXT NOT NULL,
  amount_paise INTEGER,
  amount_status TEXT NOT NULL,
  recurrence TEXT NOT NULL,
  due_date INTEGER,
  due_day INTEGER,
  due_month INTEGER,
  payment_account_hint_last4 TEXT,
  payment_account_scope TEXT NOT NULL,
  amount_paid_paise INTEGER,
  outstanding_paise INTEGER,
  payment_status TEXT NOT NULL,
  next_expected_source TEXT NOT NULL,
  upi_vpa_norm TEXT,
  payee_type TEXT NOT NULL,
  user_cadence_status TEXT NOT NULL,
  confidence REAL NOT NULL,
  review_status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
''';

/// A minimal v2 obligation row.
const _seedV2Obligation = {
  'source_type': 'gmail',
  'source_id': 'gmail-msg-1',
  'dedupe_key': 'lic:annual',
  'merchant': 'LIC',
  'merchant_norm': 'lic',
  'category_key': 'insurance',
  'amount_paise': 4700000,
  'amount_status': 'known',
  'recurrence': 'annual',
  'payment_account_scope': 'unknown',
  'payment_status': 'unpaid',
  'next_expected_source': 'explicit_due_date',
  'payee_type': 'merchant',
  'user_cadence_status': 'user_confirmed',
  'confidence': 0.95,
  'review_status': 'confirmed',
  'created_at': 1751000000000,
  'updated_at': 1751000000000,
};
