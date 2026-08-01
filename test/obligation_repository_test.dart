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
}
