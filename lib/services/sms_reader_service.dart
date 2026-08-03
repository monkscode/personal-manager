import 'dart:io';

import 'package:flutter/services.dart';
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

      // Whatever the loop stopped on — a cancellation, or a page that came back
      // empty before [total] was reached — the messages it never read are named
      // rather than absorbed into a plain success (TASK-33).
      final skipped = total - collected.length;
      return SmsScanOutcome.success(
        collected,
        skippedCount: skipped > 0 ? skipped : 0,
      );
    } catch (error) {
      return SmsScanOutcome.failure(
        SmsScanStatus.failed,
        message: error.toString(),
      );
    }
  }
}

/// Largest page the `flutter_sms_inbox` native handler will return from one
/// call: `SmsQueryHandler.MAX_FALLBACK_QUERY_COUNT`, which clamps `count` to
/// 1,000 rows. Asking for more silently yields 1,000, so the adapter pages at
/// this size and never above it.
const int kSmsNativePageLimit = 1000;

/// Production [SmsInboxPort] backed by the `flutter_sms_inbox` **platform
/// channel**, deliberately bypassing that package's `SmsQuery` Dart wrapper.
///
/// The wrapper cannot page. It never forwards `start` to the platform at all —
/// it asks the native side for `(start + count)` messages from the newest end
/// and slices the first `start` off in Dart, having first clamped that request
/// to its own `_maxQueryWindow = 1000`. Every call therefore addresses only the
/// newest 1,000 messages, and any `start >= 1000` comes back empty no matter
/// how large the inbox is. That is TASK-33: an 11,596-message inbox read as
/// 1,000 messages, reported as a complete success.
///
/// The native handler behind the channel *does* implement `start` — it skips
/// that many rows of the provider's newest-first cursor — so talking to it
/// directly restores real paging. The channel name and argument shape are
/// `flutter_sms_inbox` internals; the package is pinned in `pubspec.lock`, and
/// a rename would surface as a `MissingPluginException` and a failed scan
/// rather than as another silent truncation.
///
/// The plugin exposes neither a cheap count nor a native date filter, so
/// [count] pages the whole inbox and [read] filters by [since] in Dart. Because
/// the inbox is ordered newest-first, a [since] lower bound selects a
/// contiguous newest prefix, keeping batch offsets aligned with [count].
class FlutterSmsInboxAdapter implements SmsInboxPort {
  FlutterSmsInboxAdapter({int pageSize = kSmsNativePageLimit})
    : pageSize = pageSize <= 0 || pageSize > kSmsNativePageLimit
          ? kSmsNativePageLimit
          : pageSize;

  /// The `flutter_sms_inbox` query channel. Its codec must match the plugin's
  /// (`JSONMethodCodec`) or the platform side cannot decode the arguments.
  static const MethodChannel _channel = MethodChannel(
    'plugins.juliusgithaiga.com/querySMS',
    JSONMethodCodec(),
  );

  final int pageSize;

  @override
  Future<int> count({DateTime? since}) async {
    var total = 0;
    var start = 0;
    int? previousFirstId;
    while (true) {
      final page = await _queryInbox(start: start, count: pageSize);
      if (page.isEmpty) break;

      // A page that opens on the same message as the last one means `start` was
      // not applied and this loop would never end. That is precisely the
      // regression this adapter exists to undo, so it fails the scan rather
      // than hanging or quietly counting the same window forever.
      final firstId = page.first.id;
      if (firstId != null && firstId == previousFirstId) {
        throw PlatformException(
          code: 'paging_unsupported',
          message:
              'getInbox ignored start=$start and returned the same page again; '
              'the inbox cannot be paged and a scan would be silently partial.',
        );
      }
      previousFirstId = firstId;

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
    final page = await _queryInbox(
      start: offset,
      count: limit > kSmsNativePageLimit ? kSmsNativePageLimit : limit,
    );
    final selected = since == null
        ? page
        : page.where((m) => _afterSince(m, since));
    return selected.map(_map).toList();
  }

  /// One `getInbox` call: rows `[start, start + count)` of the inbox, newest
  /// first. Both arguments reach the platform, which is the whole point.
  Future<List<SmsMessage>> _queryInbox({
    required int start,
    required int count,
  }) async {
    if (count <= 0) return const [];
    final response = await _channel.invokeMethod<dynamic>('getInbox', {
      'start': start < 0 ? 0 : start,
      'count': count,
    });
    if (response is! List) {
      throw PlatformException(
        code: 'invalid_response',
        message: 'Expected a list of SMS rows from getInbox, got $response',
      );
    }
    return [
      for (final row in response)
        if (row is Map)
          SmsMessage.fromJson(row)
        else
          throw PlatformException(
            code: 'invalid_response',
            message: 'Expected each SMS row to be a map, got $row',
          ),
    ];
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
