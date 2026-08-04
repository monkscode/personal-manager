import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/sms_scan_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _state = const AppState().copyWith(
  nps: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'monthly',
    month: 'Feb',
  ),
  ppf: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'lumpsum',
    month: 'Feb',
  ),
  mf: const ContribPlan(
    enabled: false,
    amount: '0',
    frequency: 'monthly',
    month: 'Feb',
  ),
  currentBalance: '',
  salary: '',
);

RawSms sms(
  String body, {
  required String providerId,
  required DateTime at,
  String sender = 'VM-HDFCBK',
}) =>
    RawSms(providerId: providerId, sender: sender, body: body, receivedAt: at);

ObligationRecord netflixBill(DateTime due) => ObligationRecord(
  sourceType: ObligationSourceType.smsRecurring,
  sourceId: 'sms:netflix',
  dedupeKey: 'sms_recurring:netflix:monthly',
  merchant: 'Netflix',
  merchantNorm: 'netflix',
  categoryKey: 'subscriptions',
  amountPaise: 64900,
  amountStatus: AmountStatus.known,
  recurrence: ReconciliationRecurrence.monthly,
  dueDate: due,
  paymentAccountScope: AccountScope.unknown,
  paymentStatus: ReconciliationPaymentStatus.unpaid,
  nextExpectedSource: NextExpectedSource.lockedCadence,
  payeeType: PayeeType.merchant,
  userCadenceStatus: UserCadenceStatus.algorithmDetected,
  confidence: 0.9,
  reviewStatus: ObligationReviewStatus.confirmed,
  createdAt: due,
  updatedAt: due,
);

void main() {
  setUpAll(sqfliteFfiInit);

  late TransactionRepository txRepo;
  late ObligationRepository obliRepo;

  Future<void> openDb() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    txRepo = TransactionRepository(db);
    obliRepo = ObligationRepository(db);
  }

  setUp(openDb);

  Future<List<ParsedTxn>> reload(DateTime now) =>
      txRepo.allSince(DateTime(now.year - 2, now.month, 1));

  test(
    'scan -> parse -> dedup -> persist -> reload -> snapshot -> forecast reflects '
    'the persisted actual, and a paid recurring bill is owned exactly once (§7)',
    () async {
      final now = DateTime(2026, 8, 20, 12);
      final orchestrator = SmsScanOrchestrator(
        newScanBatchId: () => 'scan:e2e',
      );

      // A recurring bill paid this month, delivered twice by the scanner.
      const body =
          'HDFC Bank: Rs.649.00 debited from a/c XX1234 to netflix@okhdfcbank on 05-08-26. UPI Ref 111122223333.';
      final outcome = SmsScanOutcome.success([
        sms(body, providerId: 'netflix-aug', at: DateTime(2026, 8, 5, 20)),
        sms(
          body,
          providerId: 'netflix-aug',
          at: DateTime(2026, 8, 5, 20),
        ), // exact duplicate
      ]);

      final run = await orchestrator.run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'e2e-salt',
        now: now,
      );
      expect(run.isSuccess, isTrue);
      expect(run.parsed, 2);
      expect(run.skippedDuplicate, 1); // the second copy deduped away

      // The Gmail/recurring obligation for the same bill, persisted separately.
      await obliRepo.upsert(netflixBill(DateTime(2026, 8, 5)), now: now);

      // Cross the async boundary: reload from SQLite, then reduce + forecast.
      final history = await reload(now);
      final obligations = await obliRepo.allActive();
      expect(history, hasLength(1)); // dedup held across the round-trip

      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: obligations,
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );

      // The persisted actual survived the boundary into the snapshot.
      expect(snapshot.hasData, isTrue);
      expect(
        snapshot.currentMonthTxns.where((t) => t.merchant == 'netflix'),
        hasLength(1),
      );

      // One-owner reconciliation: the actual folds INTO the obligation (paid),
      // it is never a second standalone Netflix item — no double-subtraction.
      final netflixItems = snapshot.reconciliationItems
          .where((i) => i.label.toLowerCase().contains('netflix'))
          .toList();
      expect(netflixItems, hasLength(1));
      expect(
        netflixItems.single.paymentStatus,
        ReconciliationPaymentStatus.paid,
      );
      expect(netflixItems.single.amountPaise, 64900);

      // The forecast builds across the boundary from the persisted data.
      final outlook = const ForecastAdapter().build(_state, snapshot, now: now);
      expect(outlook.months, isNotEmpty);
    },
  );

  test('a stale balance anchor makes the forecast provisional', () async {
    final now = DateTime(2026, 8, 20, 12);
    // A bank-balance SMS 15 days old — past the stale threshold (6+ days).
    final balanceTxn = ParsedTxn(
      smsId: 'provider:bal-1',
      sender: 'VM-HDFCBK',
      direction: TransactionDirection.credit,
      instrument: PaymentInstrument.bank,
      type: TxnType.transfer,
      amountPaise: 8500000,
      txnDate: DateTime(2026, 8, 5, 9),
      accountLast4: '1234',
      balancePaise: 12000000,
      payeeType: PayeeType.unknown,
      categoryKey: 'salary',
      confidence: 0.95,
      reviewStatus: ReviewStatus.confirmed,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.anchorIncluded,
      rawBodyRedacted: 'redacted',
      bodyHash: 'h',
      scanBatchId: 'b',
    );
    await txRepo.upsertParsedTxn(balanceTxn);

    final history = await reload(now);
    final snapshot = SmsAnalysisSnapshot.reduce(
      history: history,
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: now,
    );

    expect(snapshot.anchor, isNotNull);
    expect(snapshot.isAnchorStale, isTrue);

    final outlook = const ForecastAdapter().build(_state, snapshot, now: now);
    expect(outlook.isProvisional, isTrue);
  });
}
