import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_meta_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<SmsMetaStore> openStore() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    return SmsMetaStore(db);
  }

  group('SmsMetaStore.bodyHashSalt', () {
    test('creates a 64-hex-char salt on first read', () async {
      final store = await openStore();

      final salt = await store.bodyHashSalt();

      expect(salt, hasLength(64));
      expect(salt, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('returns the same salt on subsequent reads', () async {
      final store = await openStore();

      final first = await store.bodyHashSalt();
      final second = await store.bodyHashSalt();

      expect(second, first);
    });

    test('concurrent first reads resolve to a single stored salt', () async {
      final store = await openStore();

      final results = await Future.wait([
        store.bodyHashSalt(),
        store.bodyHashSalt(),
        store.bodyHashSalt(),
      ]);

      expect(results.toSet(), hasLength(1));
    });
  });
}
