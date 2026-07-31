import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'sms_storage_schema.dart';

/// Per-install metadata backed by the `meta` key/value table in
/// [SmsStorageSchema]. Currently the home of the body-hash salt (§8): a random,
/// per-install secret that prevents precomputed rainbow tables against the
/// small space of templated bank-SMS bodies. It does not protect against a
/// local attacker who already holds the database file (out of v1 scope —
/// SQLCipher is deferred until key management is designed).
class SmsMetaStore {
  const SmsMetaStore(this._db);

  final Database _db;

  static const bodyHashSaltKey = 'body_hash_salt';

  /// Number of random bytes in the salt. 32 bytes => 64 lowercase hex chars.
  static const saltByteLength = 32;

  /// Returns the per-install body-hash salt, generating and persisting it once
  /// on first use. The read-then-write is wrapped in a transaction and uses
  /// `INSERT OR IGNORE`, so concurrent first callers all resolve to the same
  /// stored value.
  Future<String> bodyHashSalt() async {
    return _db.transaction((txn) async {
      await txn.insert(
        'meta',
        {'key': bodyHashSaltKey, 'value': _generateSaltHex()},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      final rows = await txn.query(
        'meta',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [bodyHashSaltKey],
        limit: 1,
      );
      return rows.single['value']! as String;
    });
  }

  static String _generateSaltHex() {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < saltByteLength; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
