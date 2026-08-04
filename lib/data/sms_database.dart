import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'sms_storage_schema.dart';

class SmsDatabase {
  const SmsDatabase._();

  static const databaseName = 'transactions.db';
  static const schemaVersion = 4;

  static Future<Database> open() async {
    final path = p.join(await getDatabasesPath(), databaseName);
    return databaseFactory.openDatabase(path, options: openOptions);
  }

  static Future<Database> openWithFactory({
    required DatabaseFactory factory,
    required String path,
  }) {
    return factory.openDatabase(path, options: openOptions);
  }

  /// The open configuration shared by [open] and [openWithFactory].
  ///
  /// [OpenDatabaseOptions.onDowngrade] must never be left null. This code calls
  /// `databaseFactory.openDatabase` directly, which bypasses the
  /// `onDowngrade ??= onDatabaseVersionChangeError` default that the top-level
  /// `openDatabase()` helper applies — and with a null handler sqflite makes no
  /// schema change but still writes the version *down*, leaving a database that
  /// reports an old version while physically being new.
  static OpenDatabaseOptions get openOptions => OpenDatabaseOptions(
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
        await SmsStorageSchema.applyMigration(db, version);
      }
      // Then converge on the declared index set. Without this an upgraded
      // database could only ever have the indexes its original `onCreate` gave
      // it plus whatever a migration happened to add, so a missing index could
      // never heal — including `idx_obligations_dedupe_key`, the only
      // database-level guard behind `ObligationRepository`'s read-then-write.
      // Every statement is `IF NOT EXISTS`, so this is idempotent (TASK-25).
      for (final statement in SmsStorageSchema.indexStatements) {
        await db.execute(statement);
      }
    },
    onDowngrade: refuseDowngrade,
  );

  /// Refuses to open a database written by a newer build.
  ///
  /// The alternative sqflite offers is `onDatabaseDowngradeDelete`, which wipes
  /// the database. This one is deliberately excluded from Android backup
  /// (`allowBackup="false"`), so a wipe is an unrecoverable loss of the user's
  /// whole transaction history. Throwing instead keeps the data and the stored
  /// version intact and makes a rollback fail comprehensibly at the moment it
  /// happens.
  static Future<void> refuseDowngrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    throw SmsDatabaseDowngradeException(
      storedVersion: oldVersion,
      supportedVersion: newVersion,
    );
  }
}

/// Thrown when the database on disk was written by a newer build than the one
/// running. See [SmsDatabase.refuseDowngrade].
class SmsDatabaseDowngradeException implements Exception {
  const SmsDatabaseDowngradeException({
    required this.storedVersion,
    required this.supportedVersion,
  });

  /// The schema version already on disk.
  final int storedVersion;

  /// The highest schema version this build understands.
  final int supportedVersion;

  @override
  String toString() =>
      'SmsDatabaseDowngradeException: the transactions database is at schema '
      'version $storedVersion but this build only supports $supportedVersion. '
      'Downgrading would require deleting the database, which is excluded from '
      'backup and cannot be restored. Install the newer build again.';
}
