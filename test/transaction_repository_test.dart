import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<TransactionRepository> openRepository() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    return TransactionRepository(db);
  }

  ParsedTxn txn({
    String smsId = 'provider:1',
    String sender = 'VM-HDFCBK',
    int amountPaise = 125000,
    DateTime? txnDate,
    String? accountLast4 = '1234',
    String? merchant = 'zomato',
    String? refNumber = 'UPI123456',
    int? balancePaise,
    double confidence = 0.95,
    ReviewStatus reviewStatus = ReviewStatus.autoAdded,
    CoverageBucket coverageBucket = CoverageBucket.datedEvent,
  }) {
    return ParsedTxn(
      smsId: smsId,
      sender: sender,
      direction: TransactionDirection.debit,
      instrument: PaymentInstrument.bank,
      type: TxnType.upi,
      amountPaise: amountPaise,
      txnDate: txnDate ?? DateTime(2026, 7, 9, 10),
      accountLast4: accountLast4,
      merchant: merchant,
      upiVpaNorm: merchant == null ? null : '$merchant@okhdfcbank',
      payeeType: PayeeType.merchant,
      categoryKey: 'groceries',
      confidence: confidence,
      reviewStatus: reviewStatus,
      source: TxnSource.sms,
      refNumber: refNumber,
      balancePaise: balancePaise,
      coverageBucket: coverageBucket,
      rawBodyRedacted: '[amount] paid at merchant',
      bodyHash: 'hash-$smsId',
      scanBatchId: 'batch-1',
    );
  }

  group('TransactionRepository', () {
    test('upserts by sms id without duplicating rows', () async {
      final repository = await openRepository();
      final original = txn();
      final updated = original.copyWith(
        reviewStatus: ReviewStatus.needsReview,
        reviewReason: ReviewReason.userFlagged,
        coverageBucket: CoverageBucket.reviewPending,
      );

      await repository.upsertParsedTxn(original, createdAt: DateTime(2026, 7, 9));
      await repository.upsertParsedTxn(updated, createdAt: DateTime(2026, 7, 10));

      final rows = await repository.queryByMonth('2026-07');
      expect(rows, hasLength(1));
      expect(rows.single.smsId, 'provider:1');
      expect(rows.single.reviewStatus, ReviewStatus.needsReview);
      expect(rows.single.reviewReason, ReviewReason.userFlagged);
    });

    test('skips strong reference duplicates during ingest', () async {
      final repository = await openRepository();
      await repository.upsertParsedTxn(txn(smsId: 'provider:1'));

      final decision = await repository.ingestParsedTxn(
        txn(smsId: 'provider:2'),
        isFirstScan: false,
        now: DateTime(2026, 7, 9, 11),
      );

      final rows = await repository.queryByMonth('2026-07');
      expect(decision.action, IngestionAction.skipDuplicate);
      expect(rows, hasLength(1));
    });

    test('routes no-ref weak collisions to review and flags both rows', () async {
      final repository = await openRepository();
      await repository.upsertParsedTxn(txn(smsId: 'provider:1', refNumber: null));

      final decision = await repository.ingestParsedTxn(
        txn(smsId: 'provider:2', refNumber: null, merchant: null),
        isFirstScan: false,
        now: DateTime(2026, 7, 9, 11),
      );

      final rows = await repository.queryByMonth('2026-07');
      expect(decision.action, IngestionAction.queueReview);
      expect(rows, hasLength(2));
      expect(rows.every((row) => row.reviewStatus == ReviewStatus.needsReview), isTrue);
      expect(rows.every((row) => row.reviewReason == ReviewReason.dedupCollision), isTrue);
      expect(rows.map((row) => row.collisionSetId).toSet(), hasLength(1));
    });

    test('queries by category, since timestamp, and latest primary balance anchor', () async {
      final repository = await openRepository();
      await repository.upsertParsedTxn(
        txn(
          smsId: 'provider:1',
          txnDate: DateTime(2026, 7, 8, 10),
          balancePaise: 1234500,
        ),
      );
      await repository.upsertParsedTxn(
        txn(
          smsId: 'provider:2',
          txnDate: DateTime(2026, 7, 9, 10),
          balancePaise: 1300000,
        ),
      );

      expect(await repository.queryByCategory('groceries'), hasLength(2));
      expect(await repository.allSince(DateTime(2026, 7, 9)), hasLength(1));

      final anchor = await repository.latestBalanceAnchor(primaryAccountLast4: '1234');
      expect(anchor, isNotNull);
      expect(anchor!.amountPaise, 1300000);
      expect(anchor.accountLast4, '1234');
      expect(anchor.source, BalanceAnchorSource.smsBankBalance);
    });

    test('a newer secondary-account balance never anchors the primary account', () async {
      final repository = await openRepository();
      await repository.upsertParsedTxn(
        txn(
          smsId: 'primary',
          accountLast4: '1234',
          txnDate: DateTime(2026, 7, 8, 10),
          balancePaise: 1000000,
        ),
      );
      await repository.upsertParsedTxn(
        txn(
          smsId: 'secondary',
          accountLast4: '9999',
          txnDate: DateTime(2026, 7, 9, 10),
          balancePaise: 5000000,
        ),
      );

      final anchor = await repository.latestBalanceAnchor(primaryAccountLast4: '1234');
      expect(anchor, isNotNull);
      expect(anchor!.accountLast4, '1234');
      expect(anchor.amountPaise, 1000000);
    });

    test('dedup ingest reads a bounded number of rows regardless of table size', () async {
      final realDb = await SmsDatabase.openWithFactory(
        factory: databaseFactoryFfi,
        path: inMemoryDatabasePath,
      );
      addTearDown(realDb.close);
      final counting = _CountingDatabase(realDb);
      final repository = TransactionRepository(counting);

      // Seed a large table of non-colliding transactions (unique amount + ref).
      for (var i = 0; i < 2000; i++) {
        await repository.upsertParsedTxn(
          txn(
            smsId: 'provider:$i',
            amountPaise: 100000 + i,
            accountLast4: null,
            refNumber: 'REF$i',
            merchant: null,
          ),
        );
      }
      expect(await repository.queryByMonth('2026-07'), hasLength(2000));

      // A single non-colliding ingest must touch only indexed candidate rows,
      // never the whole table.
      counting.rowsRead = 0;
      final decision = await repository.ingestParsedTxn(
        txn(
          smsId: 'provider:new',
          amountPaise: 999999,
          accountLast4: '9999',
          refNumber: 'REFNEW',
          merchant: null,
        ),
        isFirstScan: false,
        now: DateTime(2026, 7, 9, 12),
      );

      expect(decision.action, IngestionAction.upsert);
      expect(
        counting.rowsRead,
        lessThan(50),
        reason: 'ingest must use indexed candidate lookups, not a full-table scan',
      );
      expect(await repository.queryByMonth('2026-07'), hasLength(2001));
    });

    test('indexed ingest still skips strong-ref duplicates at scale', () async {
      final repository = await openRepository();
      for (var i = 0; i < 500; i++) {
        await repository.upsertParsedTxn(
          txn(smsId: 'provider:$i', amountPaise: 100000 + i, refNumber: 'REF$i'),
        );
      }

      final decision = await repository.ingestParsedTxn(
        txn(smsId: 'provider:dup', amountPaise: 100042, refNumber: 'REF42'),
        isFirstScan: false,
        now: DateTime(2026, 7, 9, 11),
      );

      expect(decision.action, IngestionAction.skipDuplicate);
      expect(await repository.queryByMonth('2026-07'), hasLength(500));
    });

    group('re-parse of an already-stored message', () {
      test('rewrites the stored row without duplicating it', () async {
        final repository = await openRepository();
        await repository.upsertParsedTxn(
          txn(merchant: null, reviewStatus: ReviewStatus.confirmed),
        );

        final decision = await repository.ingestParsedTxn(
          txn(merchant: 'cred club'),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        expect(decision.action, IngestionAction.refreshParse);
        final rows = await repository.queryByMonth('2026-07');
        expect(rows, hasLength(1), reason: 'a refresh must not add a row');
        expect(rows.single.merchant, 'cred club');
        expect(
          rows.single.reviewStatus,
          ReviewStatus.confirmed,
          reason: "the user's decision must survive a re-parse",
        );
      });

      test('keeps the date the message was first seen', () async {
        final repository = await openRepository();
        await repository.upsertParsedTxn(
          txn(merchant: null),
          createdAt: DateTime(2026, 1, 1),
        );

        await repository.ingestParsedTxn(
          txn(merchant: 'cred club'),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        // REPLACE would otherwise stamp the rescan's clock over created_at.
        final stored = await repository.rawCreatedAt('provider:1');
        expect(stored, DateTime(2026, 1, 1));
      });

      test('a rescan that corrects nothing writes nothing', () async {
        final repository = await openRepository();
        await repository.upsertParsedTxn(txn(merchant: 'cred club'));

        final decision = await repository.ingestParsedTxn(
          txn(merchant: 'cred club'),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      });
    });
  });
}

/// A [Database] wrapper that counts the number of rows returned by `query`,
/// including queries issued inside a `transaction`. Used to prove that ingest
/// uses bounded indexed lookups instead of scanning the whole table. All other
/// members are intentionally unimplemented (the repository never calls them).
class _CountingDatabase implements Database {
  _CountingDatabase(this._inner);

  final Database _inner;
  int rowsRead = 0;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    return _inner.transaction(
      (txn) => action(_CountingTransaction(txn, this)),
      exclusive: exclusive,
    );
  }

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
  }) async {
    final result = await _inner.query(
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
    rowsRead += result.length;
    return result;
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

class _CountingTransaction implements Transaction {
  _CountingTransaction(this._inner, this._owner);

  final Transaction _inner;
  final _CountingDatabase _owner;

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
  }) async {
    final result = await _inner.query(
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
    _owner.rowsRead += result.length;
    return result;
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
