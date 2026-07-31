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
  _StubCandidates(this.records);

  final List<ObligationRecord> records;
  List<ParsedTxn>? seenPersisted;
  String? seenScanBatchId;

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
}) => ObligationRecord(
  sourceType: sourceType,
  sourceId: 'sms:batch',
  dedupeKey: dedupeKey,
  merchant: 'Netflix',
  merchantNorm: 'netflix',
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
}
