import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/obligation_repository.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<ObligationRepository> openRepository() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    return ObligationRepository(db);
  }

  ObligationRecord obligation({
    String dedupeKey = 'gmail:lic:2026-08',
    int? amountPaise = 4700000,
    AmountStatus amountStatus = AmountStatus.known,
    ObligationReviewStatus reviewStatus = ObligationReviewStatus.confirmed,
    DateTime? dueDate,
    int? dueMonth,
    UserCadenceStatus userCadenceStatus = UserCadenceStatus.userConfirmed,
    ReconciliationPaymentStatus paymentStatus =
        ReconciliationPaymentStatus.unpaid,
    int? amountPaidPaise,
    int? outstandingPaise,
  }) {
    return ObligationRecord(
      sourceType: ObligationSourceType.gmail,
      sourceId: 'gmail-message-1',
      dedupeKey: dedupeKey,
      merchant: 'LIC',
      merchantNorm: 'lic',
      categoryKey: 'insurance',
      amountPaise: amountPaise,
      amountStatus: amountStatus,
      recurrence: ReconciliationRecurrence.annual,
      dueDate: dueDate,
      dueDay: dueDate?.day,
      dueMonth: dueMonth,
      paymentAccountScope: AccountScope.unknown,
      amountPaidPaise: amountPaidPaise,
      outstandingPaise: outstandingPaise,
      paymentStatus: paymentStatus,
      nextExpectedSource: NextExpectedSource.explicitDueDate,
      payeeType: PayeeType.merchant,
      userCadenceStatus: userCadenceStatus,
      confidence: 0.95,
      reviewStatus: reviewStatus,
      createdAt: DateTime(2026, 7, 9),
      updatedAt: DateTime(2026, 7, 9),
    );
  }

  group('ObligationRepository', () {
    test('upserts by dedupe key without duplicating obligations', () async {
      final repository = await openRepository();

      await repository.upsert(obligation(), now: DateTime(2026, 7, 9));
      await repository.upsert(
        obligation(amountPaise: 4800000),
        now: DateTime(2026, 7, 10),
      );

      final rows = await repository.allActive();
      expect(rows, hasLength(1));
      expect(rows.single.amountPaise, 4800000);
      expect(rows.single.dedupeKey, 'gmail:lic:2026-08');
    });

    test(
      'keeps amountless annual obligations reviewable and undated',
      () async {
        final repository = await openRepository();

        await repository.upsert(
          obligation(
            amountPaise: null,
            amountStatus: AmountStatus.missing,
            reviewStatus: ObligationReviewStatus.needsReview,
            dueDate: null,
            dueMonth: null,
          ),
        );

        final row = (await repository.allActive()).single;
        expect(row.amountPaise, isNull);
        expect(row.amountStatus, AmountStatus.missing);
        expect(row.reviewStatus, ObligationReviewStatus.needsReview);
        expect(row.dueMonth, isNull);
      },
    );

    test(
      'imports legacy manualTx entries as manual obligations with stable ids',
      () async {
        final repository = await openRepository();
        const entry = ExpenseEntry(
          name: 'Broadband',
          category: 'Utilities',
          categoryKey: 'utilities',
          amount: 1299,
          initial: 'BR',
          color: Colors.blue,
          recurrence: 'monthly',
        );

        final imported = await repository.importLegacyManualEntries([
          entry,
        ], now: DateTime(2026, 7, 9));
        final importedAgain = await repository.importLegacyManualEntries([
          entry,
        ], now: DateTime(2026, 7, 10));

        final rows = await repository.allActive();
        expect(imported, 1);
        expect(importedAgain, 0);
        expect(rows, hasLength(1));
        expect(rows.single.sourceType, ObligationSourceType.manual);
        expect(rows.single.sourceId, startsWith('legacy:'));
        expect(rows.single.amountPaise, 129900);
        expect(rows.single.paymentStatus, ReconciliationPaymentStatus.unpaid);
      },
    );

    test('preserves row id when upserting by dedupe key', () async {
      final repository = await openRepository();

      // First upsert
      await repository.upsert(obligation(), now: DateTime(2026, 7, 9));
      final first = (await repository.allActive()).single;
      final originalId = first.id;
      expect(originalId, isNotNull);

      // Second upsert with same dedupe key
      await repository.upsert(
        obligation(amountPaise: 4800000),
        now: DateTime(2026, 7, 10),
      );
      final second = (await repository.allActive()).single;
      final updatedId = second.id;

      // ID must be preserved
      expect(updatedId, originalId);
      expect(second.amountPaise, 4800000);
    });

    test(
      'imports legacy entries with same calendar due date but different times only once',
      () async {
        final repository = await openRepository();
        final baseDate = DateTime(2026, 8, 15);

        // Two entries with same name, category, amount, recurrence, but different times on same calendar date
        final entry1 = ExpenseEntry(
          name: 'Broadband',
          category: 'Utilities',
          categoryKey: 'utilities',
          amount: 1299,
          initial: 'BR',
          color: Colors.blue,
          recurrence: 'monthly',
          dueDate: baseDate.add(Duration(hours: 10)), // 10:00 AM
        );

        final entry2 = ExpenseEntry(
          name: 'Broadband',
          category: 'Utilities',
          categoryKey: 'utilities',
          amount: 1299,
          initial: 'BR',
          color: Colors.blue,
          recurrence: 'monthly',
          dueDate: baseDate.add(
            Duration(hours: 18),
          ), // 6:00 PM - same calendar date, different time
        );

        final imported1 = await repository.importLegacyManualEntries([
          entry1,
        ], now: DateTime(2026, 7, 9));
        final imported2 = await repository.importLegacyManualEntries([
          entry2,
        ], now: DateTime(2026, 7, 9));

        final rows = await repository.allActive();
        expect(imported1, 1);
        expect(imported2, 0); // Should not import again - same calendar date
        expect(rows, hasLength(1));
        expect(rows.single.dueDate?.day, 15);
        expect(rows.single.dueDate?.month, 8);
      },
    );

    test(
      'throws ArgumentError when stored review_status is auto_added',
      () async {
        final db = await SmsDatabase.openWithFactory(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        );
        addTearDown(db.close);
        final repository = ObligationRepository(db);

        // Insert a valid obligation first
        await repository.upsert(obligation(), now: DateTime(2026, 7, 9));

        // Manually corrupt the database with invalid auto_added status
        await db.rawUpdate(
          'UPDATE obligations SET review_status = ? WHERE dedupe_key = ?',
          ['auto_added', 'gmail:lic:2026-08'],
        );

        // allActive() must throw when encountering invalid stored status
        expect(() => repository.allActive(), throwsA(isA<ArgumentError>()));
      },
    );

    test('reserve progress is keyed by obligation dedupe key', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(dedupeKey: 'lic:annual'),
        now: DateTime(2026, 7, 22),
      );
      await repository.updateReserveProgress(
        'lic:annual',
        enabled: true,
        fundedPaise: 1800000,
        now: DateTime(2026, 7, 22),
      );

      final saved = await repository.byDedupeKey('lic:annual');
      expect(saved!.reserveEnabled, isTrue);
      expect(saved.reserveFundedPaise, 1800000);
      expect(saved.amountPaidPaise, isNull);
    });

    test('reserve progress defaults to disabled with zero funding', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(dedupeKey: 'lic:annual'),
        now: DateTime(2026, 7, 22),
      );

      final saved = await repository.byDedupeKey('lic:annual');
      expect(saved!.reserveEnabled, isFalse);
      expect(saved.reserveFundedPaise, 0);
    });

    test('updateReserveProgress rejects negative funded amounts', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(dedupeKey: 'lic:annual'),
        now: DateTime(2026, 7, 22),
      );

      expect(
        () => repository.updateReserveProgress(
          'lic:annual',
          enabled: true,
          fundedPaise: -100,
          now: DateTime(2026, 7, 22),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('a rescan must not overwrite user decisions', () {
    test('saved reserve progress survives a re-upsert of the same key', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(dedupeKey: 'lic:annual'),
        now: DateTime(2026, 7, 22),
      );
      await repository.updateReserveProgress(
        'lic:annual',
        enabled: true,
        fundedPaise: 1800000,
        now: DateTime(2026, 7, 22),
      );

      // A later SMS scan re-derives the same dedupe key from history alone, so
      // its record carries the model defaults for the reserve columns.
      await repository.upsert(
        obligation(dedupeKey: 'lic:annual'),
        now: DateTime(2026, 7, 23),
      );

      final saved = await repository.byDedupeKey('lic:annual');
      expect(saved!.reserveEnabled, isTrue);
      expect(saved.reserveFundedPaise, 1800000);
    });

    test('a user-confirmed cadence is not reset to algorithm-detected', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(userCadenceStatus: UserCadenceStatus.userConfirmed),
        now: DateTime(2026, 7, 22),
      );
      await repository.upsert(
        obligation(userCadenceStatus: UserCadenceStatus.algorithmDetected),
        now: DateTime(2026, 7, 23),
      );

      final saved = await repository.byDedupeKey('gmail:lic:2026-08');
      expect(saved!.userCadenceStatus, UserCadenceStatus.userConfirmed);
    });

    test('a dismissed obligation does not reappear as confirmed', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(reviewStatus: ObligationReviewStatus.dismissed),
        now: DateTime(2026, 7, 22),
      );
      await repository.upsert(
        obligation(reviewStatus: ObligationReviewStatus.confirmed),
        now: DateTime(2026, 7, 23),
      );

      final saved = await repository.byDedupeKey('gmail:lic:2026-08');
      expect(saved!.reviewStatus, ObligationReviewStatus.dismissed);
      expect(await repository.allActive(), isEmpty);
    });

    test('a recorded partial payment survives a re-upsert', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(
          paymentStatus: ReconciliationPaymentStatus.partial,
          amountPaidPaise: 2000000,
          outstandingPaise: 2700000,
        ),
        now: DateTime(2026, 7, 22),
      );
      await repository.upsert(
        obligation(paymentStatus: ReconciliationPaymentStatus.unpaid),
        now: DateTime(2026, 7, 23),
      );

      final saved = await repository.byDedupeKey('gmail:lic:2026-08');
      expect(saved!.paymentStatus, ReconciliationPaymentStatus.partial);
      expect(saved.amountPaidPaise, 2000000);
      expect(saved.outstandingPaise, 2700000);
    });

    test('SMS-derived fields still refresh on a re-upsert', () async {
      final repository = await openRepository();

      await repository.upsert(
        obligation(amountPaise: 500000),
        now: DateTime(2026, 7, 22),
      );
      await repository.upsert(
        obligation(amountPaise: 750000, dueDate: DateTime(2026, 9, 12)),
        now: DateTime(2026, 7, 23),
      );

      final saved = await repository.byDedupeKey('gmail:lic:2026-08');
      expect(saved!.amountPaise, 750000);
      expect(saved.dueDate, DateTime(2026, 9, 12));
      expect(saved.dueDay, 12);
    });

    group('a rescan that drops a derived field clears it (M8)', () {
      // `copyWith` resolves every argument with `?? this.x`, so it cannot carry
      // a null across. An obligation that *loses* its due date — the Gmail bill
      // is reissued without one, or a re-parse no longer finds it — kept the
      // stale date forever and the forecast went on dating an event that had no
      // date any more.
      test('a due date that disappears is not resurrected', () async {
        final repository = await openRepository();

        await repository.upsert(
          obligation(dueDate: DateTime(2026, 8, 15)),
          now: DateTime(2026, 7, 22),
        );
        await repository.upsert(
          obligation(dueDate: null),
          now: DateTime(2026, 7, 23),
        );

        final saved = await repository.byDedupeKey('gmail:lic:2026-08');
        expect(saved!.dueDate, isNull);
        expect(saved.dueDay, isNull);
      });

      test('an amount that disappears is not resurrected', () async {
        final repository = await openRepository();

        await repository.upsert(obligation(), now: DateTime(2026, 7, 22));
        await repository.upsert(
          obligation(amountPaise: null, amountStatus: AmountStatus.missing),
          now: DateTime(2026, 7, 23),
        );

        final saved = await repository.byDedupeKey('gmail:lic:2026-08');
        expect(saved!.amountPaise, isNull);
        expect(saved.amountStatus, AmountStatus.missing);
      });

      test('user intent is still preserved across the same rescan', () async {
        // TASK-02's guarantee must survive the change: the preserved set is now
        // written out explicitly rather than expressed by omission.
        final repository = await openRepository();

        await repository.upsert(
          obligation(
            dueDate: DateTime(2026, 8, 15),
            reviewStatus: ObligationReviewStatus.dismissed,
            userCadenceStatus: UserCadenceStatus.userDismissed,
            paymentStatus: ReconciliationPaymentStatus.partial,
            amountPaidPaise: 2000000,
            outstandingPaise: 2700000,
          ),
          now: DateTime(2026, 7, 22),
        );
        await repository.upsert(
          obligation(
            dueDate: null,
            reviewStatus: ObligationReviewStatus.confirmed,
            userCadenceStatus: UserCadenceStatus.algorithmDetected,
            paymentStatus: ReconciliationPaymentStatus.unpaid,
          ),
          now: DateTime(2026, 7, 23),
        );

        final saved = await repository.byDedupeKey('gmail:lic:2026-08');
        expect(saved!.dueDate, isNull);
        expect(saved.reviewStatus, ObligationReviewStatus.dismissed);
        expect(saved.userCadenceStatus, UserCadenceStatus.userDismissed);
        expect(saved.paymentStatus, ReconciliationPaymentStatus.partial);
        expect(saved.amountPaidPaise, 2000000);
        expect(saved.outstandingPaise, 2700000);
      });
    });

    group('ObligationRecord invariants are development-only (M10)', () {
      // Recorded decision, not a guarantee. `amountPaise >= 0`, `confidence in
      // [0, 1]` and `reserveFundedPaise >= 0` are `assert`s, so they hold in
      // debug and profile builds and are stripped from release. The obligations
      // table carries no CHECK constraint behind them either, and `_fromRow`
      // passes column values straight into the constructor — so in release a
      // corrupt row is hydrated as-is.
      //
      // Not promoted to real throws: `_fromRow` is on the read path, and one
      // bad row raising would blank the whole obligation list — the exact
      // failure mode M4 removed from the forecast. If a production guarantee is
      // ever wanted it must degrade the row to review, never throw.
      //
      // These pin that the checks exist *as asserts*. Converting one to a real
      // check must fail here and force the decision to be revisited.
      test('a negative amount trips an assert rather than a check', () {
        expect(
          () => obligation(amountPaise: -1),
          throwsA(isA<AssertionError>()),
        );
      });

      test('an out-of-range confidence trips an assert', () {
        expect(
          () => ObligationRecord(
            sourceType: ObligationSourceType.gmail,
            dedupeKey: 'k',
            merchant: 'LIC',
            merchantNorm: 'lic',
            categoryKey: 'insurance',
            amountStatus: AmountStatus.missing,
            recurrence: ReconciliationRecurrence.annual,
            paymentAccountScope: AccountScope.unknown,
            paymentStatus: ReconciliationPaymentStatus.unpaid,
            nextExpectedSource: NextExpectedSource.unknown,
            payeeType: PayeeType.merchant,
            userCadenceStatus: UserCadenceStatus.algorithmDetected,
            confidence: 1.7,
            reviewStatus: ObligationReviewStatus.needsReview,
            createdAt: DateTime(2026, 7, 9),
            updatedAt: DateTime(2026, 7, 9),
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    test('a failure part-way through a legacy import commits nothing', () async {
      final repository = await openRepository();
      const good = ExpenseEntry(
        name: 'Broadband',
        category: 'Utilities',
        categoryKey: 'utilities',
        amount: 1299,
        initial: 'BR',
        color: Colors.blue,
        recurrence: 'monthly',
      );
      // A negative amount is rejected by MoneyParser, failing the second entry
      // after the first has already been written.
      const bad = ExpenseEntry(
        name: 'Gym',
        category: 'Utilities',
        categoryKey: 'utilities',
        amount: -1,
        initial: 'GY',
        color: Colors.blue,
        recurrence: 'monthly',
      );

      await expectLater(
        repository.importLegacyManualEntries(
          [good, bad],
          now: DateTime(2026, 7, 9),
        ),
        throwsA(isA<FormatException>()),
      );

      expect(await repository.allActive(), isEmpty);
    });
  });

  group('TASK-37 — retiring a key nothing can derive', () {
    Future<ObligationRepository> seeded(List<String> keys) async {
      final repository = await openRepository();
      for (final key in keys) {
        await repository.upsert(obligation(dedupeKey: key));
      }
      return repository;
    }

    ObligationRecord byKey(List<ObligationRecord> all, String key) =>
        all.firstWhere((o) => o.dedupeKey == key);

    test('stamps a stored key the scan did not derive', () async {
      final repository = await seeded([
        'sms_recurring:google:monthly',
        'sms_recurring:xfkxfma537eoyvuzwkvss3vbvbr1oxoo:monthly',
      ]);

      final count = await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const {'sms_recurring:google:monthly'},
        now: DateTime(2026, 8, 4),
      );

      expect(count, 1);
      final all = await repository.allActive();
      expect(
        byKey(all, 'sms_recurring:xfkxfma537eoyvuzwkvss3vbvbr1oxoo:monthly')
            .retiredAt,
        DateTime(2026, 8, 4),
      );
      expect(byKey(all, 'sms_recurring:google:monthly').isRetired, isFalse);
    });

    test('never touches a key outside the swept prefixes', () async {
      // `sms_mandate:` is minted by a different source that did not just run.
      final repository = await seeded([
        'sms_mandate:phonepe',
        'gmail:lic:2026-08',
      ]);

      final count = await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const <String>{},
        now: DateTime(2026, 8, 4),
      );

      expect(count, 0);
      expect(
        (await repository.allActive()).every((o) => !o.isRetired),
        isTrue,
      );
    });

    test('an empty prefix set retires nothing at all', () async {
      // The default for any source that does not enumerate a key-space. Without
      // this a scan wired to NoObligationCandidates would retire everything.
      final repository = await seeded(['sms_recurring:google:monthly']);

      final count = await repository.retireUnderivable(
        keyPrefixes: const <String>{},
        derivedKeys: const <String>{},
        now: DateTime(2026, 8, 4),
      );

      expect(count, 0);
      expect((await repository.allActive()).single.isRetired, isFalse);
    });

    test('keeps the review status and the row id', () async {
      // A sweep that discarded either would be TASK-02 wearing a new hat.
      final repository = await seeded([]);
      await repository.upsert(
        obligation(
          dedupeKey: 'sms_recurring:stale:monthly',
          reviewStatus: ObligationReviewStatus.confirmed,
        ),
      );
      final before = (await repository.allActive()).single;

      await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const <String>{},
        now: DateTime(2026, 8, 4),
      );

      final after = (await repository.allActive()).single;
      expect(after.id, before.id);
      expect(after.reviewStatus, ObligationReviewStatus.confirmed);
      expect(after.createdAt, before.createdAt);
      expect(after.isRetired, isTrue);
    });

    test('an upsert on the same key clears the stamp', () async {
      // A commitment that pauses for a cycle and resumes must come back.
      final repository = await seeded(['sms_recurring:google:monthly']);
      await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const <String>{},
        now: DateTime(2026, 8, 4),
      );
      expect((await repository.allActive()).single.isRetired, isTrue);

      await repository.upsert(
        obligation(dedupeKey: 'sms_recurring:google:monthly'),
      );

      expect((await repository.allActive()).single.isRetired, isFalse);
    });

    test('a second sweep keeps the original timestamp', () async {
      final repository = await seeded(['sms_recurring:google:monthly']);
      await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const <String>{},
        now: DateTime(2026, 8, 4),
      );

      final count = await repository.retireUnderivable(
        keyPrefixes: const {'sms_recurring:'},
        derivedKeys: const <String>{},
        now: DateTime(2026, 9, 1),
      );

      expect(count, 0);
      expect(
        (await repository.allActive()).single.retiredAt,
        DateTime(2026, 8, 4),
      );
    });
  });
}
