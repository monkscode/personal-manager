import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/recurring_obligation_candidates.dart';
import '../services/sms_reader_service.dart';
import '../services/sms_scan_orchestrator.dart';
import 'app_controller.dart';
import 'obligation_repository.dart';
import 'sms_meta_store.dart';
import 'transaction_repository.dart';
import 'transactions_notifier.dart';

/// Whether the SMS "Scan messages" entry point is shown at all. Android-only —
/// iOS, web and desktop hide it entirely (the SMS layer is Android-only per the
/// spec). Overridden in tests so the wiring is exercisable off-device.
final smsScanSupportedProvider = Provider<bool>((ref) {
  if (kIsWeb) return false;
  return Platform.isAndroid;
});

/// The injectable inbox reader. Production adapters are wired here; tests
/// override this with a fake inbox so no physical device or permission dialog
/// is required.
final smsReaderServiceProvider = Provider<SmsReaderService>((ref) {
  return SmsReaderService(
    inbox: FlutterSmsInboxAdapter(),
    permission: PermissionHandlerSmsAdapter(),
  );
});

/// Drives an on-demand SMS scan: read the inbox, parse → dedup → persist through
/// the [SmsScanOrchestrator] (with the real [RecurringObligationCandidates]
/// source), then reload the reduced analysis snapshot so the whole app reflects
/// the newly stored actuals. Exposes the [ScanRunResult] (or `null` when the DB
/// is unavailable / the platform is unsupported).
class ScanController extends AsyncNotifier<ScanRunResult?> {
  @override
  FutureOr<ScanRunResult?> build() => null;

  Future<ScanRunResult?> scan() async {
    final db = ref.read(smsDatabaseProvider);
    if (db == null) return null;

    state = const AsyncValue.loading();
    try {
      final now = ref.read(analysisClockProvider)();
      final reader = ref.read(smsReaderServiceProvider);
      final txRepo = TransactionRepository(db);
      final obliRepo = ObligationRepository(db);
      final salt = await SmsMetaStore(db).bodyHashSalt();
      final appState = ref.read(appControllerProvider);

      // A first scan auto-adds high-confidence rows; subsequent scans are
      // incremental. Emptiness of the stored history is the honest signal.
      final existing = await txRepo.allSince(DateTime(now.year - 5, 1, 1));
      final isFirstScan = existing.isEmpty;

      final outcome = await reader.scan();
      final orchestrator = SmsScanOrchestrator(
        candidateSource: RecurringObligationCandidates(
          transactions: txRepo,
          configuredPlans: TransactionsNotifier.configuredPlansFor(appState),
        ),
      );
      final result = await orchestrator.run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: isFirstScan,
        bodyHashSalt: salt,
        now: now,
      );

      // Refresh the reduced snapshot (single async pass) so live mode updates.
      await ref.read(transactionsNotifierProvider.notifier).reload();
      state = AsyncValue.data(result);
      return result;
    } catch (error, stack) {
      state = AsyncValue.error(error, stack);
      return null;
    }
  }
}

final scanControllerProvider =
    AsyncNotifierProvider<ScanController, ScanRunResult?>(ScanController.new);
