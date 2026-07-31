import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/scan_controller.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:expense_insight/services/sms_reader_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _now = DateTime(2026, 7, 9, 12);

class _StubInbox implements SmsInboxPort {
  @override
  Future<int> count({DateTime? since}) async => 0;
  @override
  Future<List<RawSms>> read({DateTime? since, required int offset, required int limit}) async => const [];
}

class _StubPermission implements SmsPermissionPort {
  @override
  Future<SmsPermissionState> ensureGranted() async => SmsPermissionState.granted;
  @override
  Future<void> openSettings() async {}
}

/// A reader that skips the platform inbox entirely and returns a fixed outcome.
class _FakeReader extends SmsReaderService {
  _FakeReader(this._outcome)
      : super(inbox: _StubInbox(), permission: _StubPermission(), isAndroid: true);

  final SmsScanOutcome _outcome;

  @override
  Future<SmsScanOutcome> scan({
    DateTime? since,
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async =>
      _outcome;
}

Future<ProviderContainer> _container(SmsScanOutcome outcome) async {
  sqfliteFfiInit();
  final db = await SmsDatabase.openWithFactory(
    factory: databaseFactoryFfi,
    path: inMemoryDatabasePath,
  );
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      smsDatabaseProvider.overrideWithValue(db),
      analysisClockProvider.overrideWithValue(() => _now),
      smsScanSupportedProvider.overrideWithValue(true),
      smsReaderServiceProvider.overrideWithValue(_FakeReader(outcome)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return container;
}

void main() {
  test('scan parses, persists and reloads the snapshot', () async {
    final container = await _container(
      SmsScanOutcome.success([
        RawSms(
          providerId: 'sms-1',
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: Rs.1250.00 debited from a/c XX1234 to swiggy@okhdfcbank UPI ref 123456789012. Avl Bal Rs.10000.00',
          receivedAt: _now,
        ),
      ]),
    );

    // Settle the initial (empty) snapshot.
    await container.read(transactionsNotifierProvider.future);

    final result = await container.read(scanControllerProvider.notifier).scan();

    expect(result, isNotNull);
    expect(result!.isSuccess, isTrue);
    expect(result.parsed, greaterThanOrEqualTo(1));

    // The row landed in the DB.
    final db = container.read(smsDatabaseProvider)!;
    final stored = await TransactionRepository(db).allSince(DateTime(2026, 1, 1));
    expect(stored, isNotEmpty);

    // The snapshot was reloaded and now reports data.
    final snapshot = await container.read(transactionsNotifierProvider.future);
    expect(snapshot.hasData, isTrue);
  });

  test('an unsupported/failed outcome yields a no-op result and no rows', () async {
    final container = await _container(
      SmsScanOutcome.failure(SmsScanStatus.permissionDenied),
    );
    await container.read(transactionsNotifierProvider.future);

    final result = await container.read(scanControllerProvider.notifier).scan();

    expect(result, isNotNull);
    expect(result!.isSuccess, isFalse);

    final db = container.read(smsDatabaseProvider)!;
    final stored = await TransactionRepository(db).allSince(DateTime(2026, 1, 1));
    expect(stored, isEmpty);
  });

  test('scan returns null when no database is available', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        smsDatabaseProvider.overrideWithValue(null),
        analysisClockProvider.overrideWithValue(() => _now),
        smsReaderServiceProvider.overrideWithValue(
          _FakeReader(SmsScanOutcome.success(const [])),
        ),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(scanControllerProvider.notifier).scan();
    expect(result, isNull);
  });
}
