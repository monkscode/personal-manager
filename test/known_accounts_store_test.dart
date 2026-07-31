import 'package:expense_insight/data/known_accounts_store.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late KnownAccountsStore store;

  setUp(() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    store = KnownAccountsStore(db);
  });

  test('round-trips own accounts by last4 and vpa', () async {
    await store.addOwnAccount(
      last4: '1234',
      label: 'Salary A/c',
      origin: 'salary_anchor',
    );
    await store.addOwnAccount(
      vpaNorm: 'me@ybl',
      label: 'My UPI',
      origin: 'user_marked',
    );

    final known = await store.load();

    expect(known.isOwn(last4: '1234'), isTrue);
    expect(known.isOwn(vpaNorm: 'me@ybl'), isTrue);
    expect(known.isOwn(last4: '9999'), isFalse);
    expect(known.isOwn(vpaNorm: 'someone@okhdfc'), isFalse);
  });

  test('a user-marked own account persists for a later scan', () async {
    await store.addOwnAccount(
      last4: '4321',
      label: 'Secondary',
      origin: 'user_marked',
    );

    // Simulate a later scan re-reading the store.
    final reloaded = await store.load();

    expect(reloaded.isOwn(last4: '4321'), isTrue);
  });

  test('does not duplicate the same account on repeated adds', () async {
    await store.addOwnAccount(
      last4: '1234',
      label: 'Salary A/c',
      origin: 'salary_anchor',
    );
    await store.addOwnAccount(
      last4: '1234',
      label: 'Salary A/c (again)',
      origin: 'user_marked',
    );

    final known = await store.load();

    expect(known.accounts.where((a) => a.last4 == '1234'), hasLength(1));
  });

  test('normalizes VPA case so matching is case-insensitive', () async {
    await store.addOwnAccount(
      vpaNorm: 'Me@YBL',
      label: 'My UPI',
      origin: 'user_marked',
    );

    final known = await store.load();

    expect(known.isOwn(vpaNorm: 'me@ybl'), isTrue);
  });

  test('remove deletes a stored own account', () async {
    await store.addOwnAccount(
      last4: '1234',
      label: 'Salary A/c',
      origin: 'salary_anchor',
    );

    await store.remove(last4: '1234');

    expect((await store.load()).isOwn(last4: '1234'), isFalse);
  });

  test('rejects an unknown origin', () async {
    expect(
      () => store.addOwnAccount(
        last4: '1234',
        label: 'x',
        origin: 'not_a_real_origin',
      ),
      throwsArgumentError,
    );
  });

  test('rejects an entry with neither last4 nor vpa', () async {
    expect(
      () => store.addOwnAccount(label: 'x', origin: 'user_marked'),
      throwsArgumentError,
    );
  });
}
