import 'package:expense_insight/data/app_controller.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/data/transactions_notifier.dart';
import 'package:expense_insight/data/app_state.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/forecast_explorer.dart';
import 'package:expense_insight/services/money_lens.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

ParsedTxn txn({
  required int amountPaise,
  required DateTime date,
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.upi,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String? merchant = 'ICICI Pru MF',
  String categoryKey = 'investment',
  String? accountLast4,
  int? balancePaise,
  ReviewStatus reviewStatus = ReviewStatus.confirmed,
  String? smsId,
  String rawBodyRedacted = 'redacted',
  String? supersededBySmsId,
}) => ParsedTxn(
  smsId: smsId ?? 'sms:${date.toIso8601String()}:$amountPaise',
  sender: 'VM-ICICIB',
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: amountPaise,
  txnDate: date,
  merchant: merchant,
  accountLast4: accountLast4,
  balancePaise: balancePaise,
  payeeType: PayeeType.merchant,
  categoryKey: categoryKey,
  confidence: 0.95,
  reviewStatus: reviewStatus,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: rawBodyRedacted,
  bodyHash: 'h',
  scanBatchId: 'b',
  supersededBySmsId: supersededBySmsId,
);

List<ParsedTxn> monthlySip({required int count, int day = 10}) => [
  for (var i = 0; i < count; i++)
    txn(
      amountPaise: 1000000,
      date: DateTime(2026, 3 + i, day),
      smsId: 'sip:$i',
    ),
];

void main() {
  _task21Horizon();
  _task41NoticeLeak();
  _specASpendLens();
  _specACardIdentity();
  final now = DateTime(2026, 8, 15);

  group('kAnalysisLookbackMonths', () {
    test('covers year-over-year plus the trailing window', () {
      expect(kAnalysisLookbackMonths, 13);
    });
  });

  group('SmsAnalysisSnapshot.reduce (pure)', () {
    test('empty history yields a no-data snapshot (sample mode stays)', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: const [],
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );
      expect(snapshot.hasData, isFalse);
      expect(snapshot.commitments, isEmpty);
      expect(snapshot.reconciliationItems, isEmpty);
      expect(snapshot.anchor, isNull);
    });

    test('a monthly SIP becomes a detected commitment and owned item', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: monthlySip(count: 5),
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );
      expect(snapshot.hasData, isTrue);
      expect(snapshot.commitments, hasLength(1));
      expect(snapshot.commitments.single.cadence, RecurringCadence.monthly);
      expect(
        snapshot.reconciliationItems.where(
          (i) => i.owner == ForecastOwner.recurringCommitment,
        ),
        isNotEmpty,
      );
    });

    test('derives a bank balance anchor and its freshness', () {
      final history = [
        txn(
          amountPaise: 5000000,
          date: DateTime(2026, 8, 14),
          direction: TransactionDirection.credit,
          accountLast4: '1234',
          balancePaise: 20000000,
          categoryKey: 'salary',
          merchant: null,
        ),
      ];
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );
      expect(snapshot.anchor, isNotNull);
      expect(snapshot.anchor!.amountPaise, 20000000);
      expect(snapshot.anchor!.accountLast4, '1234');
      expect(snapshot.anchorFreshness, AnchorFreshness.current); // 1 day old
    });

    test('excludes dismissed rows from the reduction', () {
      final history = [
        ...monthlySip(count: 5),
        txn(
          amountPaise: 9999999,
          date: DateTime(2026, 8, 1),
          reviewStatus: ReviewStatus.dismissed,
          merchant: 'DISMISSED',
          categoryKey: 'shopping',
          smsId: 'dismissed',
        ),
      ];
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );
      expect(
        snapshot.currentMonthTxns.any((t) => t.smsId == 'dismissed'),
        isFalse,
      );
    });

    test('computes same-month year-over-year per category', () {
      final history = [
        txn(
          amountPaise: 500000,
          date: DateTime(2025, 8, 5),
          merchant: 'BigBasket',
          categoryKey: 'groceries',
          smsId: 'ly',
        ),
        txn(
          amountPaise: 800000,
          date: DateTime(2026, 8, 5),
          merchant: 'BigBasket',
          categoryKey: 'groceries',
          smsId: 'ty',
        ),
      ];
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history,
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );
      final yoy = snapshot.yearOverYear['groceries'];
      expect(yoy, isNotNull);
      expect(yoy!.lastYearPaise, 500000);
      expect(yoy.currentPaise, 800000);
      expect(yoy.deltaPaise, 300000);
    });

    test(
      'reduction creates reserve schedule without adding database work to Home',
      () {
        final lic = ObligationRecord(
          sourceType: ObligationSourceType.manual,
          sourceId: 'lic-policy-123',
          dedupeKey: 'lic:annual',
          merchant: 'LIC Premium',
          merchantNorm: 'lic premium',
          categoryKey: 'insurance',
          amountPaise: 5000000,
          amountStatus: AmountStatus.known,
          recurrence: ReconciliationRecurrence.annual,
          dueDate: DateTime(2027, 2, 12),
          dueDay: 12,
          dueMonth: 2,
          paymentAccountScope: AccountScope.unknown,
          paymentStatus: ReconciliationPaymentStatus.unpaid,
          nextExpectedSource: NextExpectedSource.userEntered,
          payeeType: PayeeType.merchant,
          userCadenceStatus: UserCadenceStatus.userConfirmed,
          confidence: 1.0,
          reviewStatus: ObligationReviewStatus.confirmed,
          reserveEnabled: true,
          reserveFundedPaise: 0,
          createdAt: now,
          updatedAt: now,
        );
        final snapshot = SmsAnalysisSnapshot.reduce(
          history: const [],
          obligations: [lic],
          riskDecisions: const [],
          configuredPlans: const [],
          now: DateTime(2026, 7, 22),
        );
        expect(snapshot.reservePlan.schedules.single.dedupeKey, 'lic:annual');
        expect(snapshot.obligations, hasLength(1));
        expect(snapshot.riskDecisions, isEmpty);
      },
    );

    test('snapshot carries immutable obligations and risk decisions', () {
      final decision = ForecastRiskDecision(
        ownerKey: 'test:key',
        targetMonth: '2026-08',
        status: ForecastRiskDecisionStatus.confirmed,
      );
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: const [],
        obligations: const [],
        riskDecisions: [decision],
        configuredPlans: const [],
        now: now,
      );
      expect(snapshot.riskDecisions, hasLength(1));
      expect(snapshot.riskDecisions.first.ownerKey, 'test:key');
    });

    test(
      'empty snapshot defaults obligations, reservePlan, riskDecisions to empty',
      () {
        final snapshot = SmsAnalysisSnapshot.empty(now);
        expect(snapshot.obligations, isEmpty);
        expect(snapshot.reservePlan.schedules, isEmpty);
        expect(snapshot.riskDecisions, isEmpty);
      },
    );
  });

  group('TransactionsNotifier async boundary', () {
    setUpAll(sqfliteFfiInit);

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'crosses the SQLite boundary exactly once and caches the reduction',
      () async {
        final realDb = await SmsDatabase.openWithFactory(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(realDb.close);

        final repo = TransactionRepository(realDb);
        for (final sip in monthlySip(count: 5)) {
          await repo.upsertParsedTxn(sip);
        }

        final counting = _CountingDatabase(realDb);
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            smsDatabaseProvider.overrideWithValue(counting),
            analysisClockProvider.overrideWithValue(() => now),
            sharedPrefsProvider.overrideWithValue(prefs),
          ],
        );
        addTearDown(container.dispose);

        final snapshot = await container.read(
          transactionsNotifierProvider.future,
        );
        expect(snapshot.hasData, isTrue);
        expect(snapshot.commitments, hasLength(1));

        // Three indexed reads: transactions history + active obligations + risk decisions.
        expect(counting.queryCalls, 3);

        // Re-reading the cached snapshot performs no further DB work.
        container.read(transactionsNotifierProvider);
        expect(counting.queryCalls, 3);
      },
    );

    test(
      'a null database yields an empty snapshot without touching the DB',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            smsDatabaseProvider.overrideWithValue(null),
            analysisClockProvider.overrideWithValue(() => now),
            sharedPrefsProvider.overrideWithValue(prefs),
          ],
        );
        addTearDown(container.dispose);

        final snapshot = await container.read(
          transactionsNotifierProvider.future,
        );
        expect(snapshot.hasData, isFalse);
      },
    );

    test('updateReserveProgress persists and reloads once', () async {
      final realDb = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(realDb.close);

      final obliRepo = ObligationRepository(realDb);
      await obliRepo.upsert(
        ObligationRecord(
          sourceType: ObligationSourceType.manual,
          sourceId: 'test-obligation',
          dedupeKey: 'test:key',
          merchant: 'Test Merchant',
          merchantNorm: 'test merchant',
          categoryKey: 'insurance',
          amountPaise: 1000000,
          amountStatus: AmountStatus.known,
          recurrence: ReconciliationRecurrence.annual,
          dueDate: DateTime(2027, 1, 1),
          dueDay: 1,
          dueMonth: 1,
          paymentAccountScope: AccountScope.unknown,
          paymentStatus: ReconciliationPaymentStatus.unpaid,
          nextExpectedSource: NextExpectedSource.userEntered,
          payeeType: PayeeType.merchant,
          userCadenceStatus: UserCadenceStatus.userConfirmed,
          confidence: 1.0,
          reviewStatus: ObligationReviewStatus.confirmed,
          reserveEnabled: false,
          reserveFundedPaise: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      final counting = _CountingDatabase(realDb);
      final container = ProviderContainer(
        overrides: [
          smsDatabaseProvider.overrideWithValue(counting),
          analysisClockProvider.overrideWithValue(() => now),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transactionsNotifierProvider.future);
      final initialCalls = counting.queryCalls;

      final notifier = container.read(transactionsNotifierProvider.notifier);
      await notifier.updateReserveProgress(
        dedupeKey: 'test:key',
        enabled: true,
        fundedPaise: 500000,
      );

      // Reload performs three queries again
      expect(counting.queryCalls, initialCalls + 3);

      final reloaded = await container.read(
        transactionsNotifierProvider.future,
      );
      final obligation = reloaded.obligations.firstWhere(
        (o) => o.dedupeKey == 'test:key',
      );
      expect(obligation.reserveEnabled, isTrue);
      expect(obligation.reserveFundedPaise, 500000);
    });

    test('updateReserveProgress fails clearly when database is null', () async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          smsDatabaseProvider.overrideWithValue(null),
          analysisClockProvider.overrideWithValue(() => now),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transactionsNotifierProvider.future);
      final notifier = container.read(transactionsNotifierProvider.notifier);

      expect(
        () => notifier.updateReserveProgress(
          dedupeKey: 'test:key',
          enabled: true,
          fundedPaise: 500000,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('database is unavailable'),
          ),
        ),
      );
    });

    test('saveRiskDecision persists and reloads once', () async {
      final realDb = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(realDb.close);

      final prefs = await SharedPreferences.getInstance();
      final counting = _CountingDatabase(realDb);
      final container = ProviderContainer(
        overrides: [
          smsDatabaseProvider.overrideWithValue(counting),
          analysisClockProvider.overrideWithValue(() => now),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transactionsNotifierProvider.future);
      final initialCalls = counting.queryCalls;

      final notifier = container.read(transactionsNotifierProvider.notifier);
      final decision = ForecastRiskDecision(
        ownerKey: 'test:risk',
        targetMonth: '2026-08',
        status: ForecastRiskDecisionStatus.confirmed,
      );
      await notifier.saveRiskDecision(decision);

      // Reload performs three queries again
      expect(counting.queryCalls, initialCalls + 3);

      final reloaded = await container.read(
        transactionsNotifierProvider.future,
      );
      expect(reloaded.riskDecisions, hasLength(1));
      expect(reloaded.riskDecisions.first.ownerKey, 'test:risk');
    });

    test('saveRiskDecision fails clearly when database is null', () async {
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          smsDatabaseProvider.overrideWithValue(null),
          analysisClockProvider.overrideWithValue(() => now),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transactionsNotifierProvider.future);
      final notifier = container.read(transactionsNotifierProvider.notifier);

      final decision = ForecastRiskDecision(
        ownerKey: 'test:risk',
        targetMonth: '2026-08',
        status: ForecastRiskDecisionStatus.confirmed,
      );
      expect(
        () => notifier.saveRiskDecision(decision),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('database is unavailable'),
          ),
        ),
      );
    });

    test('reload keeps the previous snapshot visible (no loading flash)', () async {
      final realDb = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(realDb.close);

      await TransactionRepository(realDb).upsertParsedTxn(
        txn(amountPaise: 120000, date: DateTime(2026, 8, 10)),
      );

      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          smsDatabaseProvider.overrideWithValue(realDb),
          analysisClockProvider.overrideWithValue(() => now),
          sharedPrefsProvider.overrideWithValue(prefs),
        ],
      );
      addTearDown(container.dispose);

      await container.read(transactionsNotifierProvider.future);
      expect(
        container.read(transactionsNotifierProvider).asData,
        isNotNull,
        reason: 'the first load resolves to data',
      );

      final notifier = container.read(transactionsNotifierProvider.notifier);
      // Start a reload but do not await it yet: the state must still expose the
      // previous snapshot (not a bare AsyncLoading), so dependents like
      // insightsProvider never flash a stale placeholder mid-refresh.
      final pending = notifier.reload();
      expect(
        container.read(transactionsNotifierProvider).asData,
        isNotNull,
        reason: 'reload must refresh in place without a loading flash',
      );
      await pending;
      expect(container.read(transactionsNotifierProvider).asData, isNotNull);
    });
  });
}

/// A [Database] wrapper that counts `query` invocations to prove the notifier
/// crosses the async boundary once. All other members are unused.
class _CountingDatabase implements Database {
  _CountingDatabase(this._inner);

  final Database _inner;
  int queryCalls = 0;

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) {
    queryCalls++;
    return _inner.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
  }

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _inner.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    return _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

// TASK-21: the reducer called the estimator once, for the target month, so
// every future month projected fixed costs against full salary with no
// everyday spending at all.
void _task21Horizon() {
  final now = DateTime(2026, 8, 15);

  // A December that costs three times an ordinary month, twice over, so the
  // same-month median has something seasonal to find.
  List<ParsedTxn> history() => [
    for (final year in [2024, 2025])
      txn(
        amountPaise: 3000000,
        date: DateTime(year, 12, 10),
        categoryKey: 'food',
        merchant: 'grocer',
      ),
    for (var m = 1; m <= 8; m++)
      txn(
        amountPaise: 1000000,
        date: DateTime(2026, m, 10),
        categoryKey: 'food',
        merchant: 'grocer',
      ),
  ];

  group('a seasonal estimate per horizon month (TASK-21)', () {
    test('December is estimated higher than an ordinary month', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history(),
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );

      expect(snapshot.horizonSeasonal, hasLength(kForecastHorizonMonths));
      expect(snapshot.seasonal, same(snapshot.horizonSeasonal.first));

      // Offsets from August 2026: 4 → December 2026, 5 → January 2027.
      final december = snapshot.horizonSeasonal[4];
      final january = snapshot.horizonSeasonal[5];
      expect(december.targetMonth, 12);
      expect(january.targetMonth, 1);
      expect(
        december.totalAmountPaise,
        greaterThan(january.totalAmountPaise),
        reason: 'December must carry its own seasonal magnitude',
      );
    });

    test('every horizon month is estimated, not just the target month', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: history(),
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );

      for (var offset = 0; offset < kForecastHorizonMonths; offset++) {
        expect(
          snapshot.horizonSeasonal[offset].totalAmountPaise,
          greaterThan(0),
          reason: 'offset $offset has no everyday spending at all',
        );
      }
    });
  });
}

// ---------------------------------------------------------------------------
// TASK-41 — a pre-notification must not survive into the working set
// ---------------------------------------------------------------------------

/// The bank announces the debit a day early, then reports the real one. Both
/// were stored as completed debits before TASK-32 fixed the parser, and no
/// rescan can retire the stale row — so the read paths have to reject it.
/// Payee is synthetic; the structure is the device's.
const _kNoticeBody = '''
E-Mandate!
[amount] will be deducted on 03/08/26, 00:00:00
For AutoPay  Acme Broadband Bill Payment mandate
UMN [vpa]
Maintain Balance
-HDFC Bank''';

const _kRealDebitBody = '''
UPI Mandate:
Sent [amount]
from HDFC Bank A/c [account]
To AutoPay  Acme Broadband
03/08/26
[ref]''';

void _task41NoticeLeak() {
  group('TASK-41 — a future-debit notice is not a transaction anywhere', () {
    final now = DateTime(2026, 8, 15);

    SmsAnalysisSnapshot build() => SmsAnalysisSnapshot.reduce(
      history: [
        txn(
          amountPaise: 11800,
          date: DateTime(2026, 8, 3),
          merchant: 'opaqueumnhandle',
          categoryKey: 'other',
          smsId: 'notice',
          rawBodyRedacted: _kNoticeBody,
        ),
        txn(
          amountPaise: 11800,
          date: DateTime(2026, 8, 3),
          merchant: 'acme broadband',
          categoryKey: 'other',
          smsId: 'real',
          rawBodyRedacted: _kRealDebitBody,
        ),
      ],
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: now,
    );

    test('the announcement is kept out of the target month actuals', () {
      final snapshot = build();

      // One spend happened, so exactly one row may reach reconciliation and
      // the forecast drivers that are built from it.
      expect(snapshot.currentMonthTxns, hasLength(1));
      expect(snapshot.currentMonthTxns.single.smsId, 'real');
    });

    test('and out of the transaction list the user scrolls', () {
      final snapshot = build();

      expect(snapshot.allTxns, hasLength(1));
      expect(snapshot.allTxns.single.smsId, 'real');
    });

    test('the surviving rupee is the real debit, counted once', () {
      final snapshot = build();

      // Guard: the fix must remove a phantom, not a rupee. ₹118 was spent
      // once and must still be there once.
      final total = snapshot.currentMonthTxns.fold<int>(
        0,
        (sum, t) => sum + t.amountPaise,
      );
      expect(total, 11800);
    });
  });
}

// A settlement stored as a card row — `_cardMarker` fires on `credit card`, so
// the bank's own bill-payment debit is not distinguishable by instrument.
const _kSettlementBody =
    'Payment of [amount] towards your HDFC Credit Card debited from A/c '
    '[account]';
const _kCardPurchaseBody =
    'Rs.[amount] spent on HDFC Bank Card [account] at AMAZON. Avl Lmt: '
    '[amount]';

void _specASpendLens() {
  final now = DateTime(2026, 8, 15);

  group('Spec A — the spend lens is derived where the working set is', () {
    // The architectural claim of TASK-41, asserted rather than assumed: a read
    // path added later that filters `spendLensTxns` inherits every exclusion
    // `active` applies, without repeating any of them.
    test('dismissed, notice and superseded rows never reach either lens', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: [
          txn(
            amountPaise: 250000,
            date: DateTime(2026, 8, 5),
            merchant: 'acme broadband',
            categoryKey: 'other',
            smsId: 'real',
            rawBodyRedacted: 'Rs.2500 debited from HDFC Bank ac',
          ),
          txn(
            amountPaise: 300000,
            date: DateTime(2026, 8, 6),
            merchant: 'acme broadband',
            categoryKey: 'other',
            smsId: 'dismissed',
            reviewStatus: ReviewStatus.dismissed,
            rawBodyRedacted: 'Rs.3000 debited from HDFC Bank ac',
          ),
          txn(
            amountPaise: 199900,
            date: DateTime(2026, 8, 7),
            merchant: 'google',
            categoryKey: 'other',
            smsId: 'notice',
            rawBodyRedacted:
                'E-Mandate! Rs.1999 will be deducted on 11/08/26 For Google',
          ),
          txn(
            amountPaise: 400000,
            date: DateTime(2026, 8, 8),
            merchant: 'acme broadband',
            categoryKey: 'other',
            smsId: 'superseded',
            supersededBySmsId: 'real',
            rawBodyRedacted: 'Rs.4000 debited from HDFC Bank ac',
          ),
        ],
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );

      // Guard: the predicates themselves have no opinion about a dismissal or
      // a supersede, so an empty result would prove nothing without this.
      final dismissed = snapshot.allTxns.where((t) => t.smsId == 'dismissed');
      expect(dismissed, isEmpty);

      expect(snapshot.spendLensTxns.map((t) => t.smsId), ['real']);
      expect(snapshot.everydayCashTxns.map((t) => t.smsId), ['real']);
    });
  });

  group('Spec A — year-over-year switches to the spend lens', () {
    test('a card purchase counts once and a settlement counts zero times', () {
      final snapshot = SmsAnalysisSnapshot.reduce(
        history: [
          txn(
            amountPaise: 50000,
            date: DateTime(2026, 8, 6),
            instrument: PaymentInstrument.card,
            type: TxnType.pos,
            merchant: 'amazon',
            categoryKey: 'shopping',
            smsId: 'purchase',
            rawBodyRedacted: _kCardPurchaseBody,
          ),
          txn(
            amountPaise: 4500000,
            date: DateTime(2026, 8, 20),
            instrument: PaymentInstrument.card,
            type: TxnType.pos,
            merchant: null,
            categoryKey: 'other',
            smsId: 'settlement',
            rawBodyRedacted: _kSettlementBody,
          ),
        ],
        obligations: const [],
        riskDecisions: const [],
        configuredPlans: const [],
        now: now,
      );

      expect(snapshot.yearOverYear['shopping']?.currentPaise, 50000);
      expect(snapshot.yearOverYear['other']?.currentPaise ?? 0, 0);
    });
  });
}

// ---------------------------------------------------------------------------
// Spec A Part 2 — card identity, and the coverage line it makes sayable.
//
// Part 1 took the card-settlement inflation out of the required figure and put
// nothing back. The line that names that gap has to name the card, which is why
// it waited for the regex.
// ---------------------------------------------------------------------------

const _kParser = SmsTransactionParser();

/// Parses a real body, so these tests exercise the identity chain end to end:
/// body -> `_account` -> `accountLast4` -> `_cardEstimates` bucket -> the
/// coverage line the user reads. Handing `accountLast4` in directly would make
/// them pass with the old regex still in place.
ParsedTxn _parsed(String body, DateTime at, {String sender = 'VM-HDFCBK'}) =>
    _kParser.parseOne(
      RawSms(
        providerId: '$body|$at',
        sender: sender,
        body: body,
        receivedAt: at,
      ),
      scanBatchId: 'batch',
      bodyHashSalt: 'salt',
    )!;

String _purchase(int rupees, String card, String merchant) =>
    'Rs.$rupees spent on HDFC Bank Card $card at $merchant. Avl Lmt: Rs.95500';

/// The card-side acknowledgement that the holder paid their bill — the credit
/// `isCardBillPayment` reads, and the only thing in this app that can say when
/// one card cycle ended and the next began.
String _billPaid(String card) =>
    'Payment of Rs.20000 received towards your credit card ending with $card '
    'on 20-08-26.';

void _specACardIdentity() {
  final now = DateTime(2026, 8, 31);

  SmsAnalysisSnapshot snap(List<ParsedTxn> history) => SmsAnalysisSnapshot.reduce(
    history: history,
    obligations: const [],
    riskDecisions: const [],
    configuredPlans: const [],
    now: now,
  );

  group('Spec A Part 2 — two cards stay two cards', () {
    test('purchases on two cards produce two estimates, not one unknown bucket', () {
      final history = [
        _parsed(_purchase(2500, 'x3333', 'RAZ*SWIGGY'), DateTime(2026, 8, 4)),
        _parsed(_purchase(3200, 'XX9012', 'AMAZON'), DateTime(2026, 8, 6)),
      ];

      // Guard: the fixture proves itself. If the parser stopped reading tails
      // the assertion below would still "pass" at length 1 for the wrong
      // reason — one bucket, not two cards.
      expect(
        history.map((t) => t.accountLast4).toList(),
        ['3333', '9012'],
      );
      expect(
        history.every((t) => t.instrument == PaymentInstrument.card),
        isTrue,
      );

      final cards = snap(history).cards;

      expect(cards, hasLength(2));
      expect(
        cards.map((c) => c.cardLast4).toSet(),
        {'3333', '9012'},
        reason: 'both cards collapsed into the unknown bucket',
      );
    });
  });

  group('Spec A Part 2 — the coverage line that names the gap', () {
    ForecastOutlook outlook(List<ParsedTxn> history) =>
        const ForecastAdapter().build(const AppState(), snap(history), now: now);

    List<ForecastCoverageLine> cardLines(List<ParsedTxn> history) => [
      for (final line in outlook(history).coverageLines)
        if (line.reason == CoverageReason.cardCycleOnly) line,
    ];

    test('reads the spend since the last bill payment, not the lifetime total', () {
      final history = [
        // Before the window opens. These belong to a bill that has been paid.
        _parsed(_purchase(50000, 'x7110', 'AMAZON'), DateTime(2026, 8, 2)),
        _parsed(_purchase(70000, 'x7110', 'FLIPKART'), DateTime(2026, 8, 10)),
        // The window opens here.
        _parsed(_billPaid('7110'), DateTime(2026, 8, 20)),
        // Rs.38,000 after it.
        _parsed(_purchase(30000, 'x7110', 'CROMA'), DateTime(2026, 8, 22)),
        _parsed(_purchase(8000, 'x7110', 'BIGBASKET'), DateTime(2026, 8, 27)),
      ];

      final line = cardLines(history).single;

      expect(line.amountPaise, 3800000, reason: 'lifetime total, not the window');
      expect(line.label, contains('7110'));
      expect(
        line.label.toLowerCase(),
        contains('last payment'),
        reason: 'the line must say which window the figure covers',
      );
      // The gap is named, never planned: it stays a coverage line and never
      // becomes a dated requirement (Spec B owns that).
      expect(
        outlook(history).months.first.events.map((e) => e.label),
        isNot(contains(line.label)),
      );
    });

    test('says the window is unknown when no bill payment was ever seen', () {
      final history = [
        _parsed(_purchase(50000, 'x7110', 'AMAZON'), DateTime(2026, 8, 2)),
        _parsed(_purchase(30000, 'x7110', 'CROMA'), DateTime(2026, 8, 22)),
      ];

      final line = cardLines(history).single;

      // A lifetime total presented as one bill is a number the user cannot act
      // on. The amount is still shown — the omission has to stay quantified —
      // but the line says what it is.
      expect(line.amountPaise, 8000000);
      expect(
        line.label.toLowerCase(),
        contains('no bill payment'),
        reason: 'a lifetime total must not read as one bill',
      );
      expect(line.label.toLowerCase(), isNot(contains('last payment')));
    });

    test('a settlement inside the window is not counted as a purchase', () {
      // `CardCycleEstimator` admitted any card-instrument debit that was not an
      // ATM withdrawal, which is exactly the shape of a body-worded settlement
      // (`_cardMarker` fires on the bare phrase "credit card"). It inflated the
      // one line Part 2 exists to add.
      final settlement = _parsed(
        'Payment of Rs.45000 towards your HDFC Credit Card ending with 7110 '
        'debited from A/c XX1234 on 21-08-26.',
        DateTime(2026, 8, 21),
      );
      expect(MoneyLens.isCardSettlement(settlement), isTrue);
      expect(settlement.instrument, PaymentInstrument.card);
      expect(settlement.direction, TransactionDirection.debit);

      final history = [
        _parsed(_billPaid('7110'), DateTime(2026, 8, 20)),
        settlement,
        _parsed(_purchase(30000, 'x7110', 'CROMA'), DateTime(2026, 8, 22)),
      ];

      expect(cardLines(history).single.amountPaise, 3000000);
    });

    test('a card with nothing bought since its bill was paid says nothing', () {
      // The window created this case: before it, the figure was a lifetime
      // total and was never zero, so the line always had something to say. A
      // ₹0 "bills aren't planned yet" is noise, not honesty — there is no
      // omission to name — and it would sit in "Needs your attention" for every
      // card the user is up to date on.
      final history = [
        _parsed(_purchase(50000, 'x7110', 'AMAZON'), DateTime(2026, 8, 2)),
        _parsed(_billPaid('7110'), DateTime(2026, 8, 20)),
      ];

      // Guard: the card is still identified and still estimated. Suppressing
      // the *line* must not mean losing the card.
      final estimate = snap(history).cards.single;
      expect(estimate.cardLast4, '7110');
      expect(estimate.statementEventAmountPaise, 0);

      expect(cardLines(history), isEmpty);
    });

    test('and it is reachable — the why-log reads plan.coverageLines', () {
      // TASK-34: three phases of coverage lines were computed correctly and not
      // one of them could be opened. `home_screen.dart` passes
      // `plan.coverageLines` to `WhyLogScreen`, and a plan's lines come from
      // `monthResult.coverageLines`, not from `outlook.coverageLines` — which is
      // what every assertion above reads. A line that lands in one and not the
      // other is invisible.
      final history = [
        _parsed(_billPaid('7110'), DateTime(2026, 8, 20)),
        _parsed(_purchase(38000, 'x7110', 'CROMA'), DateTime(2026, 8, 22)),
      ];

      final plan = buildForecastExplorer(
        outlook: outlook(history),
        reservePlan: snap(history).reservePlan,
        now: now,
      ).planAt(0);

      final line = plan.coverageLines.singleWhere(
        (c) => c.reason == CoverageReason.cardCycleOnly,
      );
      expect(line.amountPaise, 3800000);
      expect(line.label, contains('7110'));
    });
  });
}
