import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import 'app_controller.dart';
import 'app_state.dart';
import 'forecast_risk_decision_store.dart';
import 'forecast_risk_models.dart';
import 'models.dart';
import 'obligation_repository.dart';
import 'self_transfer_decision_store.dart';
import 'sms_analysis_snapshot.dart';
import 'transaction_repository.dart';
import '../services/sms_live_normalizer.dart';

/// The opened SMS/transactions [Database], or null when unavailable (iOS, a
/// failed open, or before the first scan). Overridden in `main()` with the real
/// database and in tests with an in-memory one. When null the snapshot is empty
/// and the app continues with any manual or Gmail data already available.
final smsDatabaseProvider = Provider<Database?>((ref) => null);

/// Injectable clock so the reduced snapshot is deterministic in tests.
final analysisClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The reduced SMS analysis snapshot. Crosses the async SQLite boundary **once**
/// on build (app-load / after a scan), runs D1–D8 + the estimator, and caches
/// the reduced value; the synchronous UI reads it without re-scanning.
final transactionsNotifierProvider =
    AsyncNotifierProvider<TransactionsNotifier, SmsAnalysisSnapshot>(
      TransactionsNotifier.new,
    );

class TransactionsNotifier extends AsyncNotifier<SmsAnalysisSnapshot> {
  @override
  Future<SmsAnalysisSnapshot> build() async {
    final now = ref.read(analysisClockProvider)();
    final db = ref.read(smsDatabaseProvider);
    if (db == null) return SmsAnalysisSnapshot.empty(now);

    // Three indexed reads started concurrently, then awaited.
    final txRepo = TransactionRepository(db);
    final obliRepo = ObligationRepository(db);
    final riskStore = ForecastRiskDecisionStore(db);
    final lookbackStart = DateTime(
      now.year,
      now.month - kAnalysisLookbackMonths,
      1,
    );
    final selfTransferStore = SelfTransferDecisionStore(db);
    final historyFuture = txRepo.allSince(lookbackStart);
    final obligationsFuture = obliRepo.allActive();
    final decisionsFuture = riskStore.all();
    final selfTransfersFuture = selfTransferStore.all();
    final history = await historyFuture;
    final obligations = await obligationsFuture;
    final riskDecisions = await decisionsFuture;
    final selfTransfers = await selfTransfersFuture;

    // Dedup re-delivered bank alerts and fill readable merchant/category for
    // rows the on-device parser left blank, before the pure reduction. This
    // gives recurring-detection a stable payee owner key (not the volatile DLT
    // sender) so monthly commitments lock and the forecast is populated.
    // The self-transfer decisions ride along here for the same reason the
    // dedup does: they correct rows already on disk at read time, with no
    // rescan and no migration.
    final normalized = const SmsLiveNormalizer().normalize(
      history,
      selfTransfers: selfTransfers,
    );

    final appState = ref.read(appControllerProvider);
    return SmsAnalysisSnapshot.reduce(
      history: normalized,
      obligations: obligations,
      riskDecisions: riskDecisions,
      configuredPlans: configuredPlansFor(appState),
      configuredSalaryRupees: appState.salary,
      now: now,
    );
  }

  /// Re-runs the reduction (e.g. after a scan persists new rows). It refreshes
  /// in place — deliberately *not* emitting a bare loading state first — so the
  /// previously reduced snapshot stays readable through `asData` while the
  /// single async pass repeats. Dependents (e.g. `insightsProvider`) therefore
  /// keep rendering the last real forecast instead of momentarily falling back
  /// to the manual/empty path, which otherwise flashed a stale placeholder
  /// number during a pull-to-refresh.
  Future<void> reload() async {
    state = await AsyncValue.guard(build);
  }

  /// Updates the reserve progress for an obligation and reloads the snapshot.
  Future<void> updateReserveProgress({
    required String dedupeKey,
    required bool enabled,
    required int fundedPaise,
  }) async {
    final db = ref.read(smsDatabaseProvider);
    if (db == null) {
      throw StateError('Reserve progress database is unavailable.');
    }
    await ObligationRepository(db).updateReserveProgress(
      dedupeKey,
      enabled: enabled,
      fundedPaise: fundedPaise,
      now: ref.read(analysisClockProvider)(),
    );
    await reload();
  }

  /// Saves a risk decision and reloads the snapshot.
  Future<void> saveRiskDecision(ForecastRiskDecision decision) async {
    final db = ref.read(smsDatabaseProvider);
    if (db == null) throw StateError('Forecast risk database is unavailable.');
    await ForecastRiskDecisionStore(
      db,
    ).upsert(decision, now: ref.read(analysisClockProvider)());
    await reload();
  }

  /// The enabled contribution plans fed to the recurring-debit detector so an
  /// SMS auto-debit can be reinforced by (and deduped against) a user-configured
  /// NPS/PPF/MF or custom plan (D8). Custom plans are always active.
  static List<ContribPlan> configuredPlansFor(AppState appState) => [
    appState.nps,
    appState.ppf,
    appState.mf,
    for (final plan in appState.customPlans)
      ContribPlan(
        enabled: true,
        amount: plan.amount.toString(),
        frequency: plan.frequency,
        month: plan.month,
      ),
  ].where((plan) => plan.enabled).toList();
}
