import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/sms_scan_orchestrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RawSms bankSms({
  required String providerId,
  required String body,
  DateTime? at,
  String sender = 'VM-HDFCBK',
}) => RawSms(
  providerId: providerId,
  sender: sender,
  body: body,
  receivedAt: at ?? DateTime(2026, 7, 5, 10),
);

/// Fake detector standing in for the Phase D recurring-debit detector.
class _StubCandidates implements ObligationCandidateSource {
  _StubCandidates(this.records, {this.sweptKeyPrefixes = const <String>{}});

  final List<ObligationRecord> records;
  List<ParsedTxn>? seenPersisted;
  String? seenScanBatchId;

  /// Defaults to sweeping nothing, so existing tests keep their old behaviour
  /// and a retirement sweep only happens where a test opts into one.
  @override
  final Set<String> sweptKeyPrefixes;

  @override
  Future<List<ObligationRecord>> derive({
    required List<ParsedTxn> persisted,
    required String scanBatchId,
    required DateTime now,
  }) async {
    seenPersisted = persisted;
    seenScanBatchId = scanBatchId;
    return records;
  }
}

ObligationRecord smsRecurringCandidate({
  ObligationSourceType sourceType = ObligationSourceType.smsRecurring,
  String dedupeKey = 'sms_recurring:netflix:monthly',
  String merchantNorm = 'netflix',
}) => ObligationRecord(
  sourceType: sourceType,
  sourceId: 'sms:batch',
  dedupeKey: dedupeKey,
  merchant: merchantNorm,
  merchantNorm: merchantNorm,
  categoryKey: 'entertainment',
  amountPaise: 64900,
  amountStatus: AmountStatus.known,
  recurrence: ReconciliationRecurrence.monthly,
  paymentAccountScope: AccountScope.unknown,
  paymentStatus: ReconciliationPaymentStatus.unpaid,
  nextExpectedSource: NextExpectedSource.lockedCadence,
  payeeType: PayeeType.merchant,
  userCadenceStatus: UserCadenceStatus.algorithmDetected,
  confidence: 0.9,
  reviewStatus: ObligationReviewStatus.needsReview,
  createdAt: DateTime(2026, 7, 5),
  updatedAt: DateTime(2026, 7, 5),
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

  SmsScanOrchestrator orchestrator({
    ObligationCandidateSource? candidateSource,
    String batchId = 'scan:test',
  }) => SmsScanOrchestrator(
    candidateSource: candidateSource ?? const NoObligationCandidates(),
    newScanBatchId: () => batchId,
  );

  Future<List<ParsedTxn>> allRows() =>
      txRepo.allSince(DateTime.fromMillisecondsSinceEpoch(0));

  group('future-dated mandate notices (TASK-32)', () {
    test('a mandate notice becomes a dated obligation, never a debit', () async {
      await orchestrator().run(
        outcome: SmsScanOutcome.success([
          bankSms(
            providerId: 'mandate-1',
            sender: 'AX-AXISBK-S',
            at: DateTime(2026, 7, 26, 9),
            body:
                'For the upcoming mandate set for 28-07-26, Rs.1999.00 will be '
                'debited from your A/c towards Google for GOOGLE, '
                '512345678901. To stop execution, pause mandate - Axis Bank',
          ),
        ]),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
        now: DateTime(2026, 7, 26, 9),
      );

      expect(await allRows(), isEmpty);

      final obligations = await obliRepo.allActive();
      expect(obligations, hasLength(1));
      expect(obligations.single.merchantNorm, 'google');
      expect(obligations.single.amountPaise, 199900);
      expect(obligations.single.dueDate, DateTime(2026, 7, 28));
      expect(
        obligations.single.nextExpectedSource,
        NextExpectedSource.explicitDueDate,
      );
      // TASK-18's rule: an algorithm's read of a bank SMS is never presented
      // back to the user as their own confirmed decision.
      expect(
        obligations.single.userCadenceStatus,
        UserCadenceStatus.algorithmDetected,
      );
      expect(
        obligations.single.reviewStatus,
        ObligationReviewStatus.needsReview,
      );
    });

    test('a locked commitment for the same payee owns the rupee alone', () async {
      await orchestrator(
        candidateSource: _StubCandidates([
          smsRecurringCandidate(
            dedupeKey: 'sms_recurring:google:monthly',
          ).copyWith(merchant: 'google', merchantNorm: 'google'),
        ]),
      ).run(
        outcome: SmsScanOutcome.success([
          bankSms(
            providerId: 'mandate-2',
            sender: 'AX-AXISBK-S',
            at: DateTime(2026, 7, 26, 9),
            body:
                'For the upcoming mandate set for 28-07-26, Rs.1999.00 will be '
                'debited from your A/c towards Google for GOOGLE, '
                '512345678901. To stop execution, pause mandate - Axis Bank',
          ),
        ]),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
        now: DateTime(2026, 7, 26, 9),
      );

      // Not two obligations for one debit: the commitment locked from real
      // history is the stronger signal and keeps the rupee.
      final obligations = await obliRepo.allActive();
      expect(obligations, hasLength(1));
      expect(obligations.single.dedupeKey, 'sms_recurring:google:monthly');
    });
  });

  group('a partial read is carried through, never flattened (TASK-33)', () {
    test('the run reports how many messages the reader never saw', () async {
      final result = await orchestrator().run(
        outcome: SmsScanOutcome.success(const [], skippedCount: 1500),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: true,
        bodyHashSalt: 'salt',
      );

      expect(result.isSuccess, isTrue);
      expect(result.skippedMessages, 1500);
      expect(result.isComplete, isFalse);
    });

    test('a complete read reports nothing skipped', () async {
      final result = await orchestrator().run(
        outcome: SmsScanOutcome.success(const []),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: true,
        bodyHashSalt: 'salt',
      );

      expect(result.skippedMessages, 0);
      expect(result.isComplete, isTrue);
    });

    test('a no-op claims no coverage it does not have', () async {
      final result = ScanRunResult.noOp(SmsScanStatus.permissionDenied);

      expect(result.skippedMessages, 0);
      expect(result.isComplete, isFalse);
    });
  });

  group('non-success outcomes', () {
    test('return a typed no-op and never touch the database', () async {
      final result = await orchestrator().run(
        outcome: SmsScanOutcome.failure(SmsScanStatus.permissionDenied),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: true,
        bodyHashSalt: 'salt',
      );

      expect(result.status, SmsScanStatus.permissionDenied);
      expect(result.isSuccess, isFalse);
      expect(result.parsed, 0);
      expect(result.scanBatchId, isEmpty);
      expect(await allRows(), isEmpty);
    });

    test('an empty successful scan is a valid success, not a no-op', () async {
      final result = await orchestrator().run(
        outcome: SmsScanOutcome.success(const []),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: true,
        bodyHashSalt: 'salt',
      );

      expect(result.isSuccess, isTrue);
      expect(result.parsed, 0);
      expect(result.scanBatchId, 'scan:test');
    });
  });

  group('first scan', () {
    test('queues every parsed transaction for review', () async {
      final outcome = SmsScanOutcome.success([
        bankSms(
          providerId: '1',
          body: 'Rs.500.00 debited from A/c XX1234 on 05-07-26 by UPI',
        ),
        bankSms(
          providerId: '2',
          body: 'Rs.750.00 debited from A/c XX5678 on 05-07-26 by UPI',
        ),
      ]);

      final result = await orchestrator().run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: true,
        bodyHashSalt: 'salt',
      );

      expect(result.parsed, 2);
      expect(result.queuedReview, 2);
      expect(result.autoAdded, 0);

      final rows = await allRows();
      expect(rows, hasLength(2));
      expect(
        rows.every((r) => r.reviewStatus == ReviewStatus.needsReview),
        isTrue,
      );
      expect(rows.every((r) => r.reviewReason == ReviewReason.firstScan), isTrue);
      expect(rows.every((r) => r.scanBatchId == 'scan:test'), isTrue);
    });
  });

  group('later scans', () {
    test('auto-adds a high-confidence transaction', () async {
      final outcome = SmsScanOutcome.success([
        bankSms(
          providerId: '1',
          body:
              'Rs.500.00 debited from A/c XX1234 to merchant@okhdfcbank '
              'on 05-07-26. Ref 512345678901',
        ),
      ]);

      final result = await orchestrator().run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
      );

      expect(result.parsed, 1);
      expect(result.autoAdded, 1);
      expect(result.queuedReview, 0);

      final rows = await allRows();
      expect(rows.single.reviewStatus, ReviewStatus.autoAdded);
      expect(rows.single.autoAddedAt, isNotNull);
    });

    test('routes a same amount/day/account collision to a collision set', () async {
      final outcome = SmsScanOutcome.success([
        bankSms(
          providerId: '1',
          body: 'Rs.500 debited from A/c XX1234 on 05-07-26 by UPI',
          at: DateTime(2026, 7, 5, 10),
        ),
        bankSms(
          providerId: '2',
          body: 'Rs.500 debited from A/c XX1234 on 05-07-26 via UPI',
          at: DateTime(2026, 7, 5, 18),
        ),
      ]);

      final result = await orchestrator().run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
      );

      expect(result.parsed, 2);
      expect(result.collisionSets, 1);
      expect(result.queuedReview, greaterThanOrEqualTo(1));
    });

    test('drops an exact re-scanned duplicate', () async {
      final message = bankSms(
        providerId: '1',
        body: 'Rs.500.00 debited from A/c XX1234 to merchant@okhdfcbank '
            'on 05-07-26. Ref 512345678901',
      );

      await orchestrator().run(
        outcome: SmsScanOutcome.success([message]),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
      );
      final rerun = await orchestrator().run(
        outcome: SmsScanOutcome.success([message]),
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
      );

      expect(rerun.parsed, 1);
      expect(rerun.skippedDuplicate, 1);
      expect(await allRows(), hasLength(1));
    });
  });

  group('obligation candidates', () {
    test('are persisted with source/dedupe metadata (never bare entries)', () async {
      final stub = _StubCandidates([smsRecurringCandidate()]);
      final outcome = SmsScanOutcome.success([
        bankSms(
          providerId: '1',
          body: 'Rs.649.00 debited from A/c XX1234 to netflix@okhdfcbank '
              'on 05-07-26. Ref 999888777',
        ),
      ]);

      final result = await orchestrator(candidateSource: stub).run(
        outcome: outcome,
        txRepo: txRepo,
        obliRepo: obliRepo,
        isFirstScan: false,
        bodyHashSalt: 'salt',
      );

      expect(result.obligationCandidates, 1);
      expect(stub.seenScanBatchId, 'scan:test');
      expect(stub.seenPersisted, isNotEmpty);

      final stored = await obliRepo.byDedupeKey('sms_recurring:netflix:monthly');
      expect(stored, isNotNull);
      expect(stored!.sourceType, ObligationSourceType.smsRecurring);
    });

    test('rejects a candidate that is not sms-derived', () async {
      final stub = _StubCandidates([
        smsRecurringCandidate(sourceType: ObligationSourceType.gmail),
      ]);
      final outcome = SmsScanOutcome.success([
        bankSms(
          providerId: '1',
          body: 'Rs.649.00 debited from A/c XX1234 to netflix@okhdfcbank '
              'on 05-07-26. Ref 999888777',
        ),
      ]);

      expect(
        () => orchestrator(candidateSource: stub).run(
          outcome: outcome,
          txRepo: txRepo,
          obliRepo: obliRepo,
          isFirstScan: false,
          bodyHashSalt: 'salt',
        ),
        throwsArgumentError,
      );
    });
  });

  group('TASK-37 — a scan retires the keys it can no longer derive', () {
    Future<ScanRunResult> runWith(_StubCandidates source) => orchestrator(
      candidateSource: source,
    ).run(
      outcome: SmsScanOutcome.success(const []),
      txRepo: txRepo,
      obliRepo: obliRepo,
      isFirstScan: false,
      bodyHashSalt: 'salt',
      now: DateTime(2026, 8, 4),
    );

    test('a stored key the source stopped deriving is retired', () async {
      // Scan 1 derives the key; scan 2 derives a different one, as it would
      // after a parser fix changed what the merchant reads as.
      await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:stale:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      final result = await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:fresh:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      expect(result.retiredObligations, 1);
      final all = await obliRepo.allActive();
      expect(
        all.firstWhere((o) => o.dedupeKey == 'sms_recurring:stale:monthly')
            .isRetired,
        isTrue,
      );
      expect(
        all.firstWhere((o) => o.dedupeKey == 'sms_recurring:fresh:monthly')
            .isRetired,
        isFalse,
      );
    });

    test('a source that sweeps nothing retires nothing', () async {
      // The default. Without it, one scan through NoObligationCandidates would
      // retire every obligation in the database.
      await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:stale:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      final result = await runWith(_StubCandidates(const []));

      expect(result.retiredObligations, 0);
      expect((await obliRepo.allActive()).single.isRetired, isFalse);
    });

    test('a stored mandate obligation is retired once a commitment owns '
        'that payee', () async {
      // TASK-32's finding, now actionable. The orchestrator already declines to
      // *write* a notice obligation when a commitment owns the payee
      // (`ownedByCommitment`), but that only guards new writes — a row stored
      // before the commitment locked stayed forever. On the device that is
      // `sms_mandate:google` sitting beside the ₹1,999 Google commitment.
      await obliRepo.upsert(
        smsRecurringCandidate(dedupeKey: 'sms_mandate:netflix'),
        now: DateTime(2026, 7, 1),
      );
      expect(
        (await obliRepo.allActive()).single.dedupeKey,
        'sms_mandate:netflix',
      );

      final result = await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:netflix:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      expect(result.retiredObligations, 1);
      final mandate = (await obliRepo.allActive()).firstWhere(
        (o) => o.dedupeKey == 'sms_mandate:netflix',
      );
      expect(mandate.isRetired, isTrue);
    });

    test('a mandate for a payee no commitment owns is left alone', () async {
      await obliRepo.upsert(
        smsRecurringCandidate(
          dedupeKey: 'sms_mandate:spotify',
          merchantNorm: 'spotify',
        ),
        now: DateTime(2026, 7, 1),
      );

      await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:netflix:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      final mandate = (await obliRepo.allActive()).firstWhere(
        (o) => o.dedupeKey == 'sms_mandate:spotify',
      );
      expect(mandate.isRetired, isFalse);
    });

    test('deriving the key again brings it back', () async {
      await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:paused:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );
      await runWith(
        _StubCandidates(const [], sweptKeyPrefixes: const {'sms_recurring:'}),
      );
      expect((await obliRepo.allActive()).single.isRetired, isTrue);

      await runWith(
        _StubCandidates([
          smsRecurringCandidate(dedupeKey: 'sms_recurring:paused:monthly'),
        ], sweptKeyPrefixes: const {'sms_recurring:'}),
      );

      expect((await obliRepo.allActive()).single.isRetired, isFalse);
    });
  });
}
