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

    // ======================================================================
    // TASK-26 — flagging an already-stored row must not rewrite it.
    //
    // `sms_id` is UNIQUE, so a REPLACE insert makes SQLite delete and
    // re-insert the row: `created_at` is overwritten and the AUTOINCREMENT id
    // is re-issued. Every read in this file uses `id` as its ordering
    // tiebreak.
    // ======================================================================

    group('flagging a collision member preserves the stored row (TASK-26)', () {
      Future<(TransactionRepository, Database)> openWithDb() async {
        final db = await SmsDatabase.openWithFactory(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(db.close);
        return (TransactionRepository(db), db);
      }

      Future<Map<String, Object?>> rowFor(Database db, String smsId) async =>
          (await db.query(
            'transactions',
            where: 'sms_id = ?',
            whereArgs: [smsId],
          )).single;

      test('keeps the date the flagged message was first seen', () async {
        final (repository, db) = await openWithDb();
        await repository.upsertParsedTxn(
          txn(smsId: 'provider:1', refNumber: null),
          createdAt: DateTime(2026, 1, 1),
        );

        await repository.ingestParsedTxn(
          txn(smsId: 'provider:2', refNumber: null, merchant: null),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        final flagged = await rowFor(db, 'provider:1');
        expect(
          flagged['review_status'],
          'needs_review',
          reason: 'the row must actually have been flagged',
        );
        expect(
          DateTime.fromMillisecondsSinceEpoch(flagged['created_at']! as int),
          DateTime(2026, 1, 1),
        );
      });

      test('keeps the flagged row in its place in the date group', () async {
        final (repository, db) = await openWithDb();
        // Two rows on the same date. A re-issued id sends the flagged one to
        // the end of the group, because `queryByMonth` orders by
        // `txn_date ASC, id ASC`.
        await repository.upsertParsedTxn(
          txn(smsId: 'provider:a', refNumber: null),
        );
        await repository.upsertParsedTxn(
          txn(smsId: 'provider:b', refNumber: null, amountPaise: 777000),
        );
        final idBefore = (await rowFor(db, 'provider:a'))['id'];

        await repository.ingestParsedTxn(
          txn(smsId: 'provider:c', refNumber: null, merchant: null),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        expect((await rowFor(db, 'provider:a'))['id'], idBefore);
        final order = (await repository.queryByMonth(
          '2026-07',
        )).map((r) => r.smsId).toList();
        expect(order, ['provider:a', 'provider:b', 'provider:c']);
      });

      test('writes only the review columns of the flagged row', () async {
        final (repository, db) = await openWithDb();
        await repository.upsertParsedTxn(
          txn(smsId: 'provider:1', refNumber: null),
          createdAt: DateTime(2026, 1, 1),
        );
        final before = Map<String, Object?>.from(
          await rowFor(db, 'provider:1'),
        );

        await repository.ingestParsedTxn(
          txn(smsId: 'provider:2', refNumber: null, merchant: null),
          isFirstScan: false,
          now: DateTime(2026, 7, 20),
        );

        final after = await rowFor(db, 'provider:1');
        final changed = after.keys
            .where((k) => after[k] != before[k])
            .toSet();
        expect(changed, {
          'review_status',
          'needs_review',
          'review_reason',
          'collision_set_id',
          'coverage_bucket',
        });
      });

      // GUARD, not regression coverage: the reads and both writes already share
      // one `_db.transaction`, so this passed before the fix too. Kept because
      // the flag/insert pair half-applying would leave a collision set naming a
      // row that does not exist.
      test('a failed insert rolls the flag back with it', () async {
        final realDb = await SmsDatabase.openWithFactory(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(realDb.close);
        final repository = TransactionRepository(
          _FailingInsertDatabase(realDb, failForSmsId: 'provider:2'),
        );
        await TransactionRepository(realDb).upsertParsedTxn(
          txn(smsId: 'provider:1', refNumber: null),
        );

        await expectLater(
          repository.ingestParsedTxn(
            txn(smsId: 'provider:2', refNumber: null, merchant: null),
            isFirstScan: false,
            now: DateTime(2026, 7, 20),
          ),
          throwsA(isA<StateError>()),
        );

        final rows = await realDb.query('transactions');
        expect(rows, hasLength(1));
        expect(rows.single['review_status'], 'auto_added');
      });
    });

    // ======================================================================
    // TASK-26 — the two unbounded queries need supporting indexes.
    //
    // Asserted on the query plan, not on the number of rows returned. The
    // previous "no full-table scan" test counted rows *returned* by queries
    // written to match nothing, so it stayed near zero whatever the plan was.
    // ======================================================================

    group('unbounded queries are index-backed (TASK-26)', () {
      // Mirrors `TransactionRepository.recentlyAutoAdded`. sqflite builds this
      // SQL internally and does not expose it, so the predicate is repeated
      // here; each test also runs the repository method over the same data so a
      // divergence shows up as a result mismatch rather than silently.
      const recentlyAutoAddedSql =
          'SELECT * FROM transactions '
          'WHERE review_status = ? AND auto_added_at IS NOT NULL '
          'ORDER BY auto_added_at DESC, id DESC LIMIT 50';
      const latestBalanceAnchorSql =
          'SELECT * FROM transactions '
          'WHERE instrument = ? AND balance_paise IS NOT NULL '
          'AND account_last4 = ? AND review_status != ? '
          'ORDER BY txn_date DESC, id DESC LIMIT 1';

      Future<String> planFor(
        Database db,
        String sql,
        List<Object?> args,
      ) async => (await db.rawQuery(
        'EXPLAIN QUERY PLAN $sql',
        args,
      )).map((r) => r['detail']).join(' | ');

      Future<Database> seeded() async {
        final db = await SmsDatabase.openWithFactory(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(db.close);
        final repository = TransactionRepository(db);
        for (var i = 0; i < 60; i++) {
          await repository.upsertParsedTxn(
            txn(
              smsId: 'provider:$i',
              amountPaise: 100000 + i,
              refNumber: 'REF$i',
              balancePaise: 900000 + i,
              txnDate: DateTime(2026, 7, 9, 10).add(Duration(minutes: i)),
            ),
          );
        }
        return db;
      }

      test('recentlyAutoAdded sorts through an index, not a temp B-tree', () async {
        final db = await seeded();

        final plan = await planFor(db, recentlyAutoAddedSql, [
          ReviewStatus.autoAdded.storageValue,
        ]);

        expect(plan, contains('idx_transactions_auto_added'));
        expect(
          plan,
          isNot(contains('TEMP B-TREE')),
          reason:
              'auto_added is the majority status, so sorting it to return 50 '
              'rows costs more with every message ever received',
        );
      });

      test('latestBalanceAnchor seeks the account instead of scanning', () async {
        final db = await seeded();

        final plan = await planFor(db, latestBalanceAnchorSql, [
          PaymentInstrument.bank.storageValue,
          '1234',
          ReviewStatus.dismissed.storageValue,
        ]);

        expect(plan, contains('idx_transactions_account_instrument'));
        expect(
          plan,
          isNot(contains('SCAN')),
          reason:
              'this runs on every snapshot load, and an account with no recent '
              'balance SMS would walk the whole table',
        );
      });

      test('the plan assertions fail once the indexes are dropped', () async {
        // Defect 3 in full: the test it replaces passed with every index
        // dropped. This one must not.
        final db = await seeded();
        await db.execute('DROP INDEX idx_transactions_auto_added');
        await db.execute('DROP INDEX idx_transactions_account_instrument');

        expect(
          await planFor(db, recentlyAutoAddedSql, [
            ReviewStatus.autoAdded.storageValue,
          ]),
          contains('TEMP B-TREE'),
        );
        expect(
          await planFor(db, latestBalanceAnchorSql, [
            PaymentInstrument.bank.storageValue,
            '1234',
            ReviewStatus.dismissed.storageValue,
          ]),
          contains('SCAN'),
        );
      });
    });

    // TASK-46. The floor on `merchant` is enforced HERE, where a merchant
    // becomes a stored value, not at the capture sites.
    //
    // TASK-45 routed five parser captures through `PayeeText.sanitize`, which
    // is the shape TASK-41 warns about: a predicate applied at call sites is
    // not a rule. The sixth path proved it — `_merchant` returns a UPI handle's
    // local part with a bare `.split('@').first` and no tidying, so the device
    // stored the bare mobile number `9999999999` (from `9999999999@axl`) as a
    // payee name on two rows.
    //
    // Every test below writes straight through the repository, bypassing the
    // parser entirely. A test that went through the parser would pass already
    // and prove nothing about the guarantee.
    group('stores no identifier in the merchant column', () {
      test('clears a bare mobile number captured from a UPI handle', () async {
        final repo = await openRepository();
        await repo.upsertParsedTxn(txn(merchant: '9999999999'));

        final stored = await repo.allSince(DateTime(2000));
        expect(stored.single.merchant, isNull);
      });

      test('trims a card tail rather than storing it', () async {
        final repo = await openRepository();
        await repo.upsertParsedTxn(
          txn(merchant: 'your icici bank credit card xx7117'),
        );

        final stored = await repo.allSince(DateTime(2000));
        expect(stored.single.merchant, isNull);
      });

      test('keeps the payee when only a trailing reference is dropped', () async {
        final repo = await openRepository();
        await repo.upsertParsedTxn(
          txn(merchant: 'ecs/razorpay softw/111120218042703'),
        );

        final stored = await repo.allSince(DateTime(2000));
        expect(stored.single.merchant, 'ecs/razorpay softw');
      });

      test('leaves a genuine payee untouched', () async {
        final repo = await openRepository();
        // `samplepayee1910` is a real UPI handle and `1mg` a pharmacy: digits
        // glued to letters are part of the word (TASK-45).
        for (final name in ['zomato', 'samplepayee1910', '1mg', 'science city-ii']) {
          await repo.upsertParsedTxn(txn(smsId: 'provider:$name', merchant: name));
        }

        final stored = await repo.allSince(DateTime(2000));
        expect(
          {for (final t in stored) t.merchant},
          {'zomato', 'samplepayee1910', '1mg', 'science city-ii'},
        );
      });
    });
  });
}

/// A [Database] wrapper whose insert of one specific `sms_id` throws, used to
/// prove that a half-completed ingest rolls back.
class _FailingInsertDatabase implements Database {
  _FailingInsertDatabase(this._inner, {required this.failForSmsId});

  final Database _inner;
  final String failForSmsId;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction txn) action, {
    bool? exclusive,
  }) {
    return _inner.transaction(
      (txn) => action(_FailingInsertTransaction(txn, failForSmsId)),
      exclusive: exclusive,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FailingInsertTransaction implements Transaction {
  _FailingInsertTransaction(this._inner, this._failForSmsId);

  final Transaction _inner;
  final String _failForSmsId;

  @override
  Future<int> insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    if (values['sms_id'] == _failForSmsId) {
      throw StateError('insert failed for $_failForSmsId');
    }
    return _inner.insert(
      table,
      values,
      nullColumnHack: nullColumnHack,
      conflictAlgorithm: conflictAlgorithm,
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
