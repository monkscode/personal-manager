import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_reader_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plugin's own platform channel, reproduced here so the test can stand in
/// for the native side.
const _channel = MethodChannel(
  'plugins.juliusgithaiga.com/querySMS',
  JSONMethodCodec(),
);

/// A faithful Dart model of `SmsQueryHandler.java` in `flutter_sms_inbox`
/// 1.0.5 — the code that actually answers `getInbox` on a device.
///
/// It reproduces the two behaviours the fix depends on:
///  * `start` is honoured by skipping that many rows of a newest-first cursor;
///  * `count` is clamped to `MAX_FALLBACK_QUERY_COUNT = 1000` per call.
///
/// Without this stand-in the 1,000-message ceiling is unreachable from a test,
/// which is exactly why TASK-33 survived four source reviews.
class FakeSmsProvider {
  FakeSmsProvider(this.inboxSize);

  static const int maxFallbackQueryCount = 1000;

  final int inboxSize;

  /// Every argument map the "native" side was handed, in order.
  final List<Map<String, Object?>> calls = [];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = (call.arguments as Map).cast<String, Object?>();
          calls.add({'method': call.method, ...args});

          var start = (args['start'] as num?)?.toInt() ?? 0;
          var count = (args['count'] as num?)?.toInt() ?? -1;
          if (start < 0) start = 0;
          if (count < 0 || count > maxFallbackQueryCount) {
            count = maxFallbackQueryCount;
          }
          if (count == 0) return const <Object>[];

          final rows = <Map<String, Object>>[];
          for (var i = 0; i < inboxSize; i++) {
            if (start > 0) {
              start--;
              continue;
            }
            rows.add(_row(i));
            count--;
            if (count == 0) break;
          }
          return rows;
        });
  }

  void remove() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  /// Newest-first, matching the SMS provider's `date DESC` default sort order.
  /// Index 0 is the newest message; ids run [inboxSize] down to 1, one minute
  /// apart.
  Map<String, Object> _row(int index) => {
    '_id': inboxSize - index,
    'thread_id': 1,
    'address': 'AD-HDFCBK',
    'body': 'message ${inboxSize - index}',
    'read': 1,
    'date': _dateOf(index).millisecondsSinceEpoch,
    'date_sent': _dateOf(index).millisecondsSinceEpoch,
    'sub_id': 1,
  };

  static DateTime _dateOf(int index) =>
      DateTime(2026, 8, 3, 12).subtract(Duration(minutes: index));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSmsProvider provider;

  void useInboxOf(int size) {
    provider = FakeSmsProvider(size)..install();
    addTearDown(provider.remove);
  }

  group('reading past the newest 1,000 messages (TASK-33)', () {
    test('count() reports the whole inbox, not the newest 1,000', () async {
      useInboxOf(2500);

      expect(await FlutterSmsInboxAdapter().count(), 2500);
    });

    test('read() reaches the messages beyond offset 1,000', () async {
      useInboxOf(2500);

      final page = await FlutterSmsInboxAdapter().read(offset: 1000, limit: 250);

      expect(page, hasLength(250));
      // Index 1000 of a newest-first inbox of 2,500 is id 1500.
      expect(page.first.providerId, '1500');
      expect(page.last.providerId, '1251');
    });

    test('paging read() to exhaustion yields every message exactly once', () async {
      useInboxOf(2500);
      final adapter = FlutterSmsInboxAdapter();

      final seen = <String>[];
      var offset = 0;
      while (true) {
        final page = await adapter.read(offset: offset, limit: 1000);
        if (page.isEmpty) break;
        seen.addAll(page.map((m) => m.providerId!));
        offset += page.length;
      }

      expect(seen, hasLength(2500));
      expect(seen.toSet(), hasLength(2500));
      expect(seen.first, '2500');
      expect(seen.last, '1');
    });

    test('count() and a full paged read agree on the same population', () async {
      useInboxOf(2500);
      final adapter = FlutterSmsInboxAdapter();
      final since = FakeSmsProvider._dateOf(1499);

      final total = await adapter.count(since: since);
      final collected = <RawSms>[];
      var offset = 0;
      while (offset < total) {
        final page = await adapter.read(since: since, offset: offset, limit: 1000);
        if (page.isEmpty) break;
        collected.addAll(page);
        offset += page.length;
      }

      expect(total, 1500);
      expect(collected, hasLength(total));
    });

    test('the adapter tells the platform which offset it wants', () async {
      useInboxOf(2500);

      await FlutterSmsInboxAdapter().read(offset: 1000, limit: 250);

      expect(provider.calls, hasLength(1));
      expect(provider.calls.single['start'], 1000);
      expect(provider.calls.single['count'], 250);
    });
  });

  group('a whole scan through the real adapter', () {
    test('scan() returns all 2,500 messages, not the newest 1,000', () async {
      useInboxOf(2500);
      final service = SmsReaderService(
        inbox: FlutterSmsInboxAdapter(),
        permission: _GrantedPermission(),
        isAndroid: true,
      );

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.success);
      expect(outcome.messages, hasLength(2500));
      expect(outcome.messages.map((m) => m.providerId).toSet(), hasLength(2500));
    });
  });

  group('a platform that stops honouring start fails loudly', () {
    test(
      'count() refuses to page forever over the same newest window',
      () async {
        // Exactly the old `SmsQuery.querySms` behaviour: `start` is dropped and
        // every page is the newest window again. Paging that is an infinite
        // loop, and absorbing it is how TASK-33 stayed invisible — so it must
        // surface as a failed scan instead.
        provider = _StartIgnoringProvider(2500)..install();
        addTearDown(provider.remove);

        await expectLater(
          FlutterSmsInboxAdapter().count(),
          throwsA(isA<PlatformException>()),
        );
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'the scan reports failure rather than a truncated success',
      () async {
        provider = _StartIgnoringProvider(2500)..install();
        addTearDown(provider.remove);
        final service = SmsReaderService(
          inbox: FlutterSmsInboxAdapter(),
          permission: _GrantedPermission(),
          isAndroid: true,
        );

        final outcome = await service.scan();

        expect(outcome.status, SmsScanStatus.failed);
        expect(outcome.messages, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });

  group('smaller inboxes still terminate', () {
    test('an inbox under the page size is read in one call', () async {
      useInboxOf(40);
      final adapter = FlutterSmsInboxAdapter();

      expect(await adapter.count(), 40);
      expect(await adapter.read(offset: 0, limit: 1000), hasLength(40));
    });

    test('an empty inbox counts zero and reads nothing', () async {
      useInboxOf(0);
      final adapter = FlutterSmsInboxAdapter();

      expect(await adapter.count(), 0);
      expect(await adapter.read(offset: 0, limit: 1000), isEmpty);
    });
  });
}

/// A platform that silently drops `start` — the failure mode this whole task
/// exists to remove, reproduced so the guard against its return has something
/// to catch.
class _StartIgnoringProvider extends FakeSmsProvider {
  _StartIgnoringProvider(super.inboxSize);

  @override
  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          final args = (call.arguments as Map).cast<String, Object?>();
          calls.add({'method': call.method, ...args});
          var count = (args['count'] as num?)?.toInt() ?? -1;
          if (count < 0 || count > FakeSmsProvider.maxFallbackQueryCount) {
            count = FakeSmsProvider.maxFallbackQueryCount;
          }
          final take = count > inboxSize ? inboxSize : count;
          return [for (var i = 0; i < take; i++) _row(i)];
        });
  }
}

class _GrantedPermission implements SmsPermissionPort {
  @override
  Future<SmsPermissionState> ensureGranted() async =>
      SmsPermissionState.granted;

  @override
  Future<void> openSettings() async {}
}
