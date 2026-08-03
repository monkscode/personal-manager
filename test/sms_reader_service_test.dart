import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_reader_service.dart';
import 'package:flutter_test/flutter_test.dart';

RawSms _sms(String body, {DateTime? at, String sender = 'AD-SBIINB'}) => RawSms(
  sender: sender,
  body: body,
  receivedAt: at ?? DateTime(2026, 7, 1),
);

class _FakeInbox implements SmsInboxPort {
  _FakeInbox(this.messages);

  final List<RawSms> messages;
  final List<int> readOffsets = [];
  DateTime? sinceSeen;
  bool sinceObserved = false;
  Object? throwOnRead;

  List<RawSms> _filtered(DateTime? since) => messages
      .where((m) => since == null || !m.receivedAt.isBefore(since))
      .toList();

  @override
  Future<int> count({DateTime? since}) async {
    sinceSeen = since;
    sinceObserved = true;
    return _filtered(since).length;
  }

  @override
  Future<List<RawSms>> read({
    DateTime? since,
    required int offset,
    required int limit,
  }) async {
    if (throwOnRead != null) throw throwOnRead!;
    readOffsets.add(offset);
    final filtered = _filtered(since);
    if (offset >= filtered.length) return const [];
    final end = (offset + limit) > filtered.length ? filtered.length : offset + limit;
    return filtered.sublist(offset, end);
  }
}

/// A port whose [count] sees the whole inbox but whose [read] goes empty after
/// [servable] messages — the shape of any platform-side window the reader
/// cannot page past. Stands in for a truncation the reader must *name* rather
/// than absorb into a plain success (TASK-33).
class _TruncatingInbox implements SmsInboxPort {
  _TruncatingInbox({required this.total, required this.servable});

  final int total;
  final int servable;

  @override
  Future<int> count({DateTime? since}) async => total;

  @override
  Future<List<RawSms>> read({
    DateTime? since,
    required int offset,
    required int limit,
  }) async {
    if (offset >= servable) return const [];
    final end = (offset + limit) > servable ? servable : offset + limit;
    return [for (var i = offset; i < end; i++) _sms('m$i')];
  }
}

class _FakePermission implements SmsPermissionPort {
  _FakePermission(this.state);

  final SmsPermissionState state;
  int ensureCalls = 0;
  int openSettingsCalls = 0;

  @override
  Future<SmsPermissionState> ensureGranted() async {
    ensureCalls++;
    return state;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCalls++;
  }
}

SmsReaderService _service({
  required _FakeInbox inbox,
  required _FakePermission permission,
  bool isAndroid = true,
  int batchSize = 2,
}) => SmsReaderService(
  inbox: inbox,
  permission: permission,
  isAndroid: isAndroid,
  batchSize: batchSize,
);

void main() {
  group('platform gate', () {
    test('non-Android returns unsupportedPlatform without touching plugin', () async {
      final inbox = _FakeInbox([_sms('body')]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(
        inbox: inbox,
        permission: permission,
        isAndroid: false,
      );

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.unsupportedPlatform);
      expect(outcome.messages, isEmpty);
      expect(permission.ensureCalls, 0);
      expect(inbox.readOffsets, isEmpty);
    });
  });

  group('permission handling', () {
    test('denied maps to permissionDenied and never opens settings', () async {
      final inbox = _FakeInbox([_sms('body')]);
      final permission = _FakePermission(SmsPermissionState.denied);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.permissionDenied);
      expect(outcome.messages, isEmpty);
      expect(permission.openSettingsCalls, 0);
      expect(inbox.readOffsets, isEmpty);
    });

    test('permanently denied deep-links to settings', () async {
      final inbox = _FakeInbox([_sms('body')]);
      final permission = _FakePermission(SmsPermissionState.permanentlyDenied);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.permissionPermanentlyDenied);
      expect(outcome.messages, isEmpty);
      expect(permission.openSettingsCalls, 1);
      expect(inbox.readOffsets, isEmpty);
    });
  });

  group('successful scan', () {
    test('empty inbox is a valid success and reports (0,0) progress', () async {
      final inbox = _FakeInbox([]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission);
      final progress = <List<int>>[];

      final outcome = await service.scan(
        onProgress: (done, total) => progress.add([done, total]),
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.messages, isEmpty);
      expect(progress, [
        [0, 0],
      ]);
    });

    test('reads all messages in order across batches with progress', () async {
      final inbox = _FakeInbox([
        _sms('a'),
        _sms('b'),
        _sms('c'),
        _sms('d'),
        _sms('e'),
      ]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission, batchSize: 2);
      final progress = <List<int>>[];

      final outcome = await service.scan(
        onProgress: (done, total) => progress.add([done, total]),
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.messages.map((m) => m.body).toList(), ['a', 'b', 'c', 'd', 'e']);
      expect(inbox.readOffsets, [0, 2, 4]);
      expect(progress.first, [0, 5]);
      expect(progress.last, [5, 5]);
    });

    test('forwards the since bound to the inbox port', () async {
      final since = DateTime(2026, 6, 1);
      final inbox = _FakeInbox([
        _sms('old', at: DateTime(2026, 5, 1)),
        _sms('new', at: DateTime(2026, 6, 15)),
      ]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan(since: since);

      expect(inbox.sinceSeen, since);
      expect(outcome.messages.map((m) => m.body).toList(), ['new']);
    });
  });

  group('truncated reads are named, never absorbed (TASK-33)', () {
    test('a page that goes empty before total reports the shortfall', () async {
      final inbox = _TruncatingInbox(total: 2500, servable: 1000);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = SmsReaderService(
        inbox: inbox,
        permission: permission,
        isAndroid: true,
        batchSize: 250,
      );

      final outcome = await service.scan();

      expect(outcome.messages, hasLength(1000));
      expect(outcome.skippedCount, 1500);
      expect(outcome.isComplete, isFalse);
    });

    test('a complete read reports no shortfall', () async {
      final inbox = _FakeInbox([_sms('a'), _sms('b'), _sms('c')]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan();

      expect(outcome.messages, hasLength(3));
      expect(outcome.skippedCount, 0);
      expect(outcome.isComplete, isTrue);
    });

    test('a failure carries no shortfall to mistake for a partial read', () async {
      final inbox = _FakeInbox([_sms('a')])..throwOnRead = StateError('boom');
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.failed);
      expect(outcome.skippedCount, 0);
    });
  });

  group('cancellation', () {
    test('stops early and reports partial progress', () async {
      final inbox = _FakeInbox([
        _sms('a'),
        _sms('b'),
        _sms('c'),
        _sms('d'),
        _sms('e'),
        _sms('f'),
      ]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission, batchSize: 2);
      final progress = <List<int>>[];
      var checks = 0;

      final outcome = await service.scan(
        onProgress: (done, total) => progress.add([done, total]),
        isCancelled: () async => checks++ >= 1,
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.messages.map((m) => m.body).toList(), ['a', 'b']);
      expect(inbox.readOffsets, [0]);
      expect(progress.last, [2, 6]);
    });

    test('a cancelled scan names the messages it never read', () async {
      final inbox = _FakeInbox([
        _sms('a'),
        _sms('b'),
        _sms('c'),
        _sms('d'),
        _sms('e'),
        _sms('f'),
      ]);
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission, batchSize: 2);
      var checks = 0;

      final outcome = await service.scan(isCancelled: () async => checks++ >= 1);

      expect(outcome.messages, hasLength(2));
      expect(outcome.skippedCount, 4);
      expect(outcome.isComplete, isFalse);
    });
  });

  group('failure handling', () {
    test('an inbox error maps to failed with a message', () async {
      final inbox = _FakeInbox([_sms('a')])..throwOnRead = StateError('boom');
      final permission = _FakePermission(SmsPermissionState.granted);
      final service = _service(inbox: inbox, permission: permission);

      final outcome = await service.scan();

      expect(outcome.status, SmsScanStatus.failed);
      expect(outcome.message, isNotNull);
      expect(outcome.messages, isEmpty);
    });
  });

  group('construction', () {
    test('rejects a non-positive batch size', () {
      expect(
        () => SmsReaderService(
          inbox: _FakeInbox([]),
          permission: _FakePermission(SmsPermissionState.granted),
          isAndroid: true,
          batchSize: 0,
        ),
        throwsArgumentError,
      );
    });

    test('exposes the default batch-size constant', () {
      expect(kSmsReadBatchSize, greaterThan(0));
    });
  });
}
