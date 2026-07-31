import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/insights.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _now = DateTime(2026, 8, 15);

ParsedTxn _debit() => ParsedTxn(
  smsId: 'sms',
  sender: 'VM-ICICIB',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: 500000,
  txnDate: DateTime(2026, 8, 4),
  merchant: 'BigBasket',
  payeeType: PayeeType.merchant,
  categoryKey: 'groceries',
  confidence: 0.95,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h',
  scanBatchId: 'b',
);

SmsAnalysisSnapshot _liveSnapshot() => SmsAnalysisSnapshot.reduce(
  history: [_debit()],
  obligations: const [],
  riskDecisions: const [],
  configuredPlans: const [],
  now: _now,
);

void main() {
  group('Insights.isLiveMode predicate', () {
    test('sample mode when no manualTx, no Gmail, no SMS data', () {
      expect(Insights.isLiveMode(const AppState()), isFalse);
    });

    test('an SMS-only user exits sample mode', () {
      expect(Insights.isLiveMode(const AppState(), hasSmsData: true), isTrue);
    });

    test('manual transactions or Gmail still trigger live mode', () {
      expect(
        Insights.isLiveMode(const AppState(gmailEmail: 'a@b.com')),
        isTrue,
      );
    });
  });

  group('insightsProvider', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'recomputes when the snapshot changes, not only when AppState changes',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final fake = _FakeTransactionsNotifier(SmsAnalysisSnapshot.empty(_now));
        final container = ProviderContainer(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            transactionsNotifierProvider.overrideWith(() => fake),
          ],
        );
        addTearDown(container.dispose);

        // Settle the async notifier to its initial (empty) snapshot.
        await container.read(transactionsNotifierProvider.future);

        var rebuilds = 0;
        container.listen(insightsProvider, (_, next) => rebuilds++);

        final sample = container.read(insightsProvider);
        final expectedSample = Insights.compute(
          const AppState(),
          hasSmsData: false,
        );
        expect(sample.heroLabel, expectedSample.heroLabel);

        // Snapshot gains data — AppState is unchanged.
        fake.emit(_liveSnapshot());
        await Future<void>.microtask(() {});

        final live = container.read(insightsProvider);
        final expectedLive = Insights.compute(
          const AppState(),
          snapshot: _liveSnapshot(),
        );
        expect(rebuilds, greaterThanOrEqualTo(1));
        expect(live.heroLabel, expectedLive.heroLabel);
        // The two modes are genuinely different renders.
        expect(expectedSample.heroLabel == expectedLive.heroLabel, isFalse);
      },
    );
  });
}

/// A [TransactionsNotifier] whose snapshot is driven directly by the test,
/// bypassing the database so the live-mode wiring can be exercised in isolation.
class _FakeTransactionsNotifier extends TransactionsNotifier {
  _FakeTransactionsNotifier(this._snapshot);

  SmsAnalysisSnapshot _snapshot;

  @override
  Future<SmsAnalysisSnapshot> build() async => _snapshot;

  void emit(SmsAnalysisSnapshot snapshot) {
    _snapshot = snapshot;
    state = AsyncData(snapshot);
  }
}
