import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'sms_storage_schema.dart';

class SmsDatabase {
  const SmsDatabase._();

  static const databaseName = 'transactions.db';
  static const schemaVersion = 3;

  static Future<Database> open() async {
    final path = p.join(await getDatabasesPath(), databaseName);
    return databaseFactory.openDatabase(path, options: _openOptions);
  }

  static Future<Database> openWithFactory({
    required DatabaseFactory factory,
    required String path,
  }) {
    return factory.openDatabase(path, options: _openOptions);
  }

  static OpenDatabaseOptions get _openOptions => OpenDatabaseOptions(
    version: schemaVersion,
    onCreate: (db, version) async {
      await db.execute(SmsStorageSchema.createTransactionsTable);
      await db.execute(SmsStorageSchema.createObligationsTable);
      await db.execute(SmsStorageSchema.createMetaTable);
      await db.execute(SmsStorageSchema.createKnownAccountsTable);
      await db.execute(SmsStorageSchema.createForecastRiskDecisionsTable);
      for (final statement in SmsStorageSchema.indexStatements) {
        await db.execute(statement);
      }
    },
    onUpgrade: (db, oldVersion, newVersion) async {
      // Apply each registered migration in ascending order. A missing step
      // fails loudly rather than leaving the schema half-migrated.
      for (var version = oldVersion + 1; version <= newVersion; version++) {
        final steps = SmsStorageSchema.migrations[version];
        if (steps == null) {
          throw StateError(
            'No SMS database migration is registered for schema version $version.',
          );
        }
        for (final statement in steps) {
          await db.execute(statement);
        }
      }
    },
  );
}
