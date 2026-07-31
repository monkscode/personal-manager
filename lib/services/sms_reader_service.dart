import 'dart:io';

import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/sms_models.dart';

/// Default number of inbox messages read per batch during a scan.
///
/// Batching keeps memory bounded and lets the scan forward progress and honor
/// cancellation between reads instead of blocking on one large query.
const int kSmsReadBatchSize = 250;

/// Runtime `READ_SMS` permission outcome, decoupled from `permission_handler`
/// so the reader service can be unit-tested without platform channels.
enum SmsPermissionState { granted, denied, permanentlyDenied }

/// Injectable seam over the runtime SMS permission so tests never touch the
/// real `permission_handler` platform channel.
abstract class SmsPermissionPort {
  /// Requests the `READ_SMS` permission and reports the resulting state.
  Future<SmsPermissionState> ensureGranted();

  /// Deep-links the user to the app settings screen (used when the permission
  /// is permanently denied and can no longer be requested in-app).
  Future<void> openSettings();
}

/// Injectable seam over the SMS inbox so tests never touch the real
/// `flutter_sms_inbox` platform channel.
abstract class SmsInboxPort {
  /// Number of inbox messages received at/after [since] (all messages when
  /// [since] is null). Used to compute scan progress totals.
  Future<int> count({DateTime? since});

  /// Reads a batch of inbox messages, newest first, over the half-open range
  /// `[offset, offset + limit)` of the messages received at/after [since].
  Future<List<RawSms>> read({
    DateTime? since,
    required int offset,
    required int limit,
  });
}

/// Android-only SMS reader that turns the inbox into a typed [SmsScanOutcome].
///
/// The platform plugin and runtime permission are injected behind
/// [SmsInboxPort] / [SmsPermissionPort] so the whole state machine
/// (unsupported platform, permission denied / permanently denied, batched
/// success, cancellation, failure) is unit-testable without a device.
class SmsReaderService {
  SmsReaderService({
    required this.inbox,
    required this.permission,
    bool? isAndroid,
    this.batchSize = kSmsReadBatchSize,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
    }
  }

  final SmsInboxPort inbox;
  final SmsPermissionPort permission;
  final int batchSize;
  final bool _isAndroid;

  /// Scans the inbox and returns a typed outcome.
  ///
  /// - Non-Android platforms short-circuit to
  ///   [SmsScanStatus.unsupportedPlatform] before any permission or plugin call.
  /// - Permission denied / permanently denied map to the corresponding typed
  ///   statuses; the permanently-denied path deep-links to app settings.
  /// - On success, messages are read in batches of the configured size,
  ///   [onProgress] is invoked as `(done, total)`, and [isCancelled] is polled
  ///   before each batch so a cancelled scan stops early and returns the
  ///   partial results collected so far.
  Future<SmsScanOutcome> scan({
    DateTime? since,
    void Function(int done, int total)? onProgress,
    Future<bool> Function()? isCancelled,
  }) async {
    if (!_isAndroid) {
      return SmsScanOutcome.failure(
        SmsScanStatus.unsupportedPlatform,
        message: 'SMS reading is only supported on Android.',
      );
    }

    switch (await permission.ensureGranted()) {
      case SmsPermissionState.granted:
        break;
      case SmsPermissionState.denied:
        return SmsScanOutcome.failure(SmsScanStatus.permissionDenied);
      case SmsPermissionState.permanentlyDenied:
        await permission.openSettings();
        return SmsScanOutcome.failure(
          SmsScanStatus.permissionPermanentlyDenied,
        );
    }

    try {
      final total = await inbox.count(since: since);
      final collected = <RawSms>[];
      onProgress?.call(0, total);

      var offset = 0;
      while (offset < total) {
        if (await isCancelled?.call() ?? false) break;
        final batch = await inbox.read(
          since: since,
          offset: offset,
          limit: batchSize,
        );
        if (batch.isEmpty) break;
        collected.addAll(batch);
        offset += batch.length;
        onProgress?.call(collected.length, total);
      }

      return SmsScanOutcome.success(collected);
    } catch (error) {
      return SmsScanOutcome.failure(
        SmsScanStatus.failed,
        message: error.toString(),
      );
    }
  }
}

/// Production [SmsInboxPort] backed by `flutter_sms_inbox`.
///
/// `flutter_sms_inbox` exposes neither a cheap count nor a native date filter,
/// so [count] pages through inbox metadata and [read] pages via `start`/`count`
/// and filters by [since] in Dart. Because the inbox is ordered newest-first,
/// a [since] lower bound selects a contiguous newest prefix, keeping batch
/// offsets aligned with [count].
class FlutterSmsInboxAdapter implements SmsInboxPort {
  FlutterSmsInboxAdapter({SmsQuery? query, this.pageSize = 1000})
    : _query = query ?? SmsQuery();

  static const List<SmsQueryKind> _inboxKind = [SmsQueryKind.inbox];

  final SmsQuery _query;
  final int pageSize;

  @override
  Future<int> count({DateTime? since}) async {
    var total = 0;
    var start = 0;
    while (true) {
      final page = await _query.querySms(
        start: start,
        count: pageSize,
        kinds: _inboxKind,
      );
      if (page.isEmpty) break;
      total += since == null
          ? page.length
          : page.where((m) => _afterSince(m, since)).length;
      if (page.length < pageSize) break;
      start += page.length;
    }
    return total;
  }

  @override
  Future<List<RawSms>> read({
    DateTime? since,
    required int offset,
    required int limit,
  }) async {
    final page = await _query.querySms(
      start: offset,
      count: limit,
      kinds: _inboxKind,
    );
    final selected = since == null
        ? page
        : page.where((m) => _afterSince(m, since));
    return selected.map(_map).toList();
  }

  static bool _afterSince(SmsMessage message, DateTime since) {
    final date = message.date;
    return date != null && !date.isBefore(since);
  }

  static RawSms _map(SmsMessage message) => RawSms(
    sender: message.address ?? '',
    body: message.body ?? '',
    receivedAt: message.date ?? DateTime.fromMillisecondsSinceEpoch(0),
    providerId: message.id?.toString(),
  );
}

/// Production [SmsPermissionPort] backed by `permission_handler`.
class PermissionHandlerSmsAdapter implements SmsPermissionPort {
  const PermissionHandlerSmsAdapter();

  @override
  Future<SmsPermissionState> ensureGranted() async {
    final status = await Permission.sms.request();
    if (status.isGranted) return SmsPermissionState.granted;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return SmsPermissionState.permanentlyDenied;
    }
    return SmsPermissionState.denied;
  }

  @override
  Future<void> openSettings() async {
    await openAppSettings();
  }
}
