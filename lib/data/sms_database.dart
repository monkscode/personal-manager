import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'sms_storage_schema.dart';

class SmsDatabase {
  const SmsDatabase._();

  static const databaseName = 'transactions.db';
  static const schemaVersion = 5;

  static Future<Database> open() async {
    final path = p.join(await getDatabasesPath(), databaseName);
    return databaseFactory.openDatabase(path, options: openOptions);
  }

  /// Opens against an injected [factory]. Used by tests, which all pass
  /// `inMemoryDatabasePath`.
  ///
  /// `singleInstance` is off here. sqflite defaults it to true and caches by
  /// path, so two handles opened on `:memory:` would be the *same* database —
  /// a test that opened a second one to check isolation would pass for the
  /// wrong reason, and closing either would close both (TASK-27 M4).
  static Future<Database> openWithFactory({
    required DatabaseFactory factory,
    required String path,
  }) {
    final base = openOptions;
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: base.version,
        onCreate: base.onCreate,
        onUpgrade: base.onUpgrade,
        onDowngrade: base.onDowngrade,
        singleInstance: false,
      ),
    );
  }

  /// The open configuration shared by [open] and [openWithFactory].
  ///
  /// There is deliberately no `onConfigure` enabling `PRAGMA foreign_keys`.
  /// This schema declares no foreign keys at all — every cross-table link
  /// (`dedupe_key`, `owner_key`, `sms_id`) is a logical key resolved in Dart,
  /// not a `REFERENCES` clause — so the pragma would have nothing to enforce.
  /// **If a real foreign key is ever added, enable it in the same change**, or
  /// SQLite will accept violating writes silently (TASK-27 M6).
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
