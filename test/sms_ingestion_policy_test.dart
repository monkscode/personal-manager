import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn txn({
  required String smsId,
  required int amountPaise,
  required DateTime date,
  required String scanBatchId,
  String? accountLast4,
  String? refNumber,
  String? merchant,
  double confidence = 0.95,
  TransactionDirection direction = TransactionDirection.debit,
  ReviewStatus reviewStatus = ReviewStatus.autoAdded,
  ReviewReason? reviewReason,
  String? collisionSetId,
  String categoryKey = 'other',
}) {
  return ParsedTxn(
    smsId: smsId,
    sender: 'VM-HDFCBK',
    direction: direction,
    instrument: PaymentInstrument.bank,
    type: TxnType.upi,
    amountPaise: amountPaise,
    txnDate: date,
    accountLast4: accountLast4,
    merchant: merchant,
    payeeType: PayeeType.merchant,
    categoryKey: categoryKey,
    confidence: confidence,
    reviewStatus: reviewStatus,
    reviewReason: reviewReason,
    collisionSetId: collisionSetId,
    source: TxnSource.sms,
    refNumber: refNumber,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'redacted',
    bodyHash: 'hash',
    scanBatchId: scanBatchId,
  );
}

void main() {
  group('SmsIngestionPolicy.classify', () {
    test(
      'drops exact provider-id duplicates without creating review noise',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
        );
        final incoming = txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'new',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'routes same amount/day/account/direction with no distinguishing signal to a collision set',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          accountLast4: '1234',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          accountLast4: '1234',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.queueReview);
        expect(decision.transaction.reviewStatus, ReviewStatus.needsReview);
        expect(decision.transaction.reviewReason, ReviewReason.dedupCollision);
        expect(decision.transaction.collisionSetId, isNotNull);
        expect(decision.existingToFlag, hasLength(1));
        expect(decision.existingToFlag.single.smsId, 'provider:1');
        expect(
          decision.existingToFlag.single.reviewStatus,
          ReviewStatus.needsReview,
        );
        expect(
          decision.existingToFlag.single.collisionSetId,
          decision.transaction.collisionSetId,
        );
      },
    );

    test(
      'skips strong reference-number duplicates tied to the same account and instrument',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          accountLast4: '1234',
          refNumber: '123456789012',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          accountLast4: '1234',
          refNumber: '123456789012',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'first scan reviews all rows and later high confidence rows are auto-added with audit time',
      () {
        final candidate = txn(
          smsId: 'provider:3',
          amountPaise: 90000,
          date: DateTime(2026, 7, 9),
          scanBatchId: 'new',
          refNumber: '987654321098',
          merchant: 'merchant',
        );

        final firstScan = SmsIngestionPolicy.classify(
          incoming: candidate,
          existing: const [],
          isFirstScan: true,
          now: DateTime(2026, 7, 10),
        );
        final laterScan = SmsIngestionPolicy.classify(
          incoming: candidate,
          existing: const [],
          isFirstScan: false,
          now: DateTime(2026, 7, 10),
        );

        expect(firstScan.action, IngestionAction.queueReview);
        expect(firstScan.transaction.reviewReason, ReviewReason.firstScan);
        expect(laterScan.action, IngestionAction.upsert);
        expect(laterScan.transaction.reviewStatus, ReviewStatus.autoAdded);
        expect(laterScan.transaction.autoAddedAt, DateTime(2026, 7, 10));
      },
    );

    test(
      'treats same-ref resends as duplicates without an account last4',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          refNumber: 'RRN12345',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          refNumber: 'RRN12345',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      },
    );

    test(
      'same ref with a different amount is not a duplicate (RRN reused across legs)',
      () {
        final existing = txn(
          smsId: 'provider:1',
          amountPaise: 50000,
          date: DateTime(2026, 7, 9, 9),
          scanBatchId: 'old',
          refNumber: 'RRN12345',
        );
        final incoming = txn(
          smsId: 'provider:2',
          amountPaise: 75000,
          date: DateTime(2026, 7, 9, 18),
          scanBatchId: 'new',
          refNumber: 'RRN12345',
        );

        final decision = SmsIngestionPolicy.classify(
          incoming: incoming,
          existing: [existing],
          isFirstScan: false,
        );

        expect(decision.action, isNot(IngestionAction.skipDuplicate));
      },
    );

    test('collision set ids are stable for the same tuple, whoever collides', () {
      // Behavioural, not a restatement of the hash recipe: the same tuple must
      // always produce the same id, and a different tuple a different one.
      String idFor({required String amountOwner, required int amountPaise}) {
        final decision = SmsIngestionPolicy.classify(
          incoming: txn(
            smsId: 'provider:नया$amountOwner',
            amountPaise: amountPaise,
            date: DateTime(2026, 7, 9, 18),
            scanBatchId: 'new',
            accountLast4: '1234',
          ),
          existing: [
            txn(
              smsId: 'provider:पुराना$amountOwner',
              amountPaise: amountPaise,
              date: DateTime(2026, 7, 9, 9),
              scanBatchId: 'old',
              accountLast4: '1234',
            ),
          ],
          isFirstScan: false,
        );
        return decision.transaction.collisionSetId!;
      }

      expect(idFor(amountOwner: 'x', amountPaise: 50000), startsWith('collision:'));
      expect(
        idFor(amountOwner: 'x', amountPaise: 50000),
        idFor(amountOwner: 'y', amountPaise: 50000),
        reason: 'same tuple, different sms ids — the set id must not move',
      );
      expect(
        idFor(amountOwner: 'x', amountPaise: 50000),
        isNot(idFor(amountOwner: 'x', amountPaise: 60000)),
        reason: 'a different amount is a different collision set',
      );
    });

    test('three duplicates land in one collision set', () {
      final stored = _ingestAll(_duplicates(3));

      expect(stored, hasLength(3));
      expect(stored.map((t) => t.collisionSetId).toSet(), hasLength(1));
      expect(stored.first.collisionSetId, isNotNull);
    });

    test('ingest order does not change the collision set id', () {
      final forwards = _ingestAll(_duplicates(3));
      final backwards = _ingestAll(_duplicates(3).reversed.toList());

      expect(
        forwards.map((t) => t.collisionSetId).toSet(),
        backwards.map((t) => t.collisionSetId).toSet(),
      );
    });

    test('every member of a three-way collision is flagged for review', () {
      final stored = _ingestAll(_duplicates(3));

      expect(
        stored.map((t) => t.reviewStatus),
        everyElement(ReviewStatus.needsReview),
      );
      expect(
        stored.map((t) => t.reviewReason),
        everyElement(ReviewReason.dedupCollision),
      );
    });

    test('four duplicates: all four flagged, still a single set', () {
      final stored = _ingestAll(_duplicates(4));

      expect(stored, hasLength(4));
      expect(stored.map((t) => t.collisionSetId).toSet(), hasLength(1));
      expect(
        stored.map((t) => t.reviewStatus),
        everyElement(ReviewStatus.needsReview),
      );
    });

    // A stored row is never re-parsed today: sms_id matches, ingestion short
    // -circuits to skipDuplicate, and the row keeps whatever the parser of the
    // day produced. After a parser fix the stored history stays wrong forever.
    group('re-parse of an already-stored message', () {
      ParsedTxn stored({
        String? merchant,
        TransactionDirection direction = TransactionDirection.debit,
        ReviewStatus reviewStatus = ReviewStatus.confirmed,
        ReviewReason? reviewReason,
        String? collisionSetId,
      }) => txn(
        smsId: 'provider:1',
        amountPaise: 50000,
        date: DateTime(2026, 7, 9),
        scanBatchId: 'old-scan',
        merchant: merchant,
        direction: direction,
        reviewStatus: reviewStatus,
        reviewReason: reviewReason,
        collisionSetId: collisionSetId,
      );

      test('a changed parse refreshes the row instead of being skipped', () {
        final decision = SmsIngestionPolicy.classify(
          incoming: stored(merchant: 'cred club', reviewStatus: ReviewStatus.autoAdded),
          existing: [stored()], // stored has no merchant
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.refreshParse);
        expect(decision.transaction.merchant, 'cred club');
      });

      test('the user decision survives the refresh', () {
        final decision = SmsIngestionPolicy.classify(
          // The fresh parse of an unreviewed message would say autoAdded.
          incoming: stored(merchant: 'cred club', reviewStatus: ReviewStatus.autoAdded),
          existing: [stored(reviewStatus: ReviewStatus.dismissed)],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.refreshParse);
        expect(decision.transaction.reviewStatus, ReviewStatus.dismissed);
        expect(decision.transaction.merchant, 'cred club');
      });

      test('a resolved row does not inherit the fresh parse uncertainty', () {
        // copyWith cannot clear a field, so a naive merge would leave the
        // confirmed row carrying parserUncertain and drag it back into review.
        final decision = SmsIngestionPolicy.classify(
          incoming: txn(
            smsId: 'provider:1',
            amountPaise: 50000,
            date: DateTime(2026, 7, 9),
            scanBatchId: 'new-scan',
            merchant: 'cred club',
            reviewStatus: ReviewStatus.needsReview,
            reviewReason: ReviewReason.parserUncertain,
          ),
          existing: [stored()], // confirmed, reviewReason null
          isFirstScan: false,
        );

        expect(decision.transaction.reviewStatus, ReviewStatus.confirmed);
        expect(decision.transaction.reviewReason, isNull);
      });

      test('the collision set the user resolved is preserved', () {
        final decision = SmsIngestionPolicy.classify(
          incoming: stored(merchant: 'cred club', reviewStatus: ReviewStatus.autoAdded),
          existing: [stored(collisionSetId: 'collision:abc')],
          isFirstScan: false,
        );

        expect(decision.transaction.collisionSetId, 'collision:abc');
      });

      test('an unchanged parse is still skipped, so a rescan writes nothing', () {
        final decision = SmsIngestionPolicy.classify(
          incoming: stored(),
          existing: [stored()],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.skipDuplicate);
      });

      test('a corrected direction reaches the stored row', () {
        final decision = SmsIngestionPolicy.classify(
          incoming: stored(direction: TransactionDirection.debit),
          existing: [stored(direction: TransactionDirection.credit)],
          isFirstScan: false,
        );

        expect(decision.action, IngestionAction.refreshParse);
        expect(decision.transaction.direction, TransactionDirection.debit);
      });
    });

    test(
      'a row indistinguishable from a later member still collides',
      () {
        // A carries a ref, B does not. C carries a different ref, so C is
        // distinguishable from A — but nothing separates C from B, so C must
        // still collide instead of being auto-added.
        final stored = _ingestAll([
          _duplicate('a', refNumber: 'REF111'),
          _duplicate('b'),
          _duplicate('c', refNumber: 'REF222'),
        ]);

        final c = stored.singleWhere((t) => t.smsId == 'provider:c');
        final b = stored.singleWhere((t) => t.smsId == 'provider:b');
        expect(c.reviewStatus, ReviewStatus.needsReview);
        expect(c.reviewReason, ReviewReason.dedupCollision);
        expect(b.reviewStatus, ReviewStatus.needsReview);
        expect(c.collisionSetId, b.collisionSetId);
      },
    );
  });

  // Spec A Part 2. `accountLast4` is the account leg of the weak-collision
  // tuple, so making a card tail readable puts card rows through a gate they
  // used to walk past with a null account. Measured here rather than assumed.
  group('two card purchases that a readable tail now brings into one tuple', () {
    const parser = SmsTransactionParser();

    ParsedTxn purchase(String id, String merchantSuffix) => parser.parseOne(
      RawSms(
        providerId: id,
        sender: 'VM-HDFCBK',
        // No reference, and "Avl Lmt" is not a balance keyword, so neither
        // reference nor balance can tell the two rows apart.
        body: 'Rs.250 spent on HDFC Bank Card x3333 at SWIGGY$merchantSuffix. '
            'Avl Lmt: Rs.95500',
        receivedAt: DateTime(2026, 8, 6, 13),
      ),
      scanBatchId: 'batch',
      bodyHashSalt: 'salt',
    )!;

    test('the tail is what puts them in one tuple at all', () {
      // The fixture proves itself: without this the assertions below could pass
      // for the wrong reason — two rows the policy never even compared.
      final a = purchase('1', '');
      expect(a.accountLast4, '3333');
      expect(a.instrument, PaymentInstrument.card);
      expect(a.refNumber, isNull);
      expect(a.balancePaise, isNull);
    });

    test('same merchant: the policy asks the user rather than guessing', () {
      final decision = SmsIngestionPolicy.classify(
        incoming: purchase('2', ''),
        existing: [purchase('1', '')],
        isFirstScan: false,
      );

      // The spec predicted these would stay apart. They do not, and the
      // behaviour is the policy's designed one rather than a defect the
      // widening introduced: same amount, same day, same account, same
      // direction and nothing to tell them apart is exactly the tuple
      // `_weakCollision` exists to surface, and a bank row with an `A/c` tail
      // has been treated this way since TASK-09.
      //
      // It costs the user a review prompt, not a rupee. `queueReview` writes
      // both rows with `needsReview`, and `SmsAnalysisSnapshot.reduce` drops
      // only `dismissed`, notices and superseded rows from `active` — so both
      // purchases keep counting while the question is open. Scoping the tail
      // away from this tuple would need a card identity separate from
      // `accountLast4`, which is Spec B's.
      expect(decision.action, IngestionAction.queueReview);
      expect(decision.transaction.reviewReason, ReviewReason.dedupCollision);
      expect(decision.existingToFlag, hasLength(1));
      // Neither row is dropped — one owner per rupee survives the collision.
      expect(decision.transaction.smsId, isNot(decision.existingToFlag.single.smsId));
    });

    test('different merchants stay apart, which is the common case', () {
      // Two card purchases on one day at *different* merchants — the shape a
      // real inbox produces far more often — are still told apart by
      // `_hasDistinguishingSignal`, so the widening does not sweep ordinary
      // card spending into review.
      final decision = SmsIngestionPolicy.classify(
        incoming: purchase('2', ' INSTAMART'),
        existing: [purchase('1', '')],
        isFirstScan: false,
      );

      expect(decision.action, IngestionAction.upsert);
      expect(decision.transaction.reviewReason, isNull);
    });
  });
}

/// One member of a same amount/day/account/direction duplicate group.
ParsedTxn _duplicate(String id, {String? refNumber}) => txn(
  smsId: 'provider:$id',
  amountPaise: 200000,
  date: DateTime(2026, 1, 6),
  scanBatchId: 'batch',
  accountLast4: '1234',
  refNumber: refNumber,
);

List<ParsedTxn> _duplicates(int count) => [
  for (var i = 0; i < count; i++) _duplicate(String.fromCharCode(97 + i)),
];

/// Replays a scan: each row is classified against everything stored so far and
/// the decision is applied, exactly as `TransactionRepository.ingestParsedTxn`
/// does. Returns the resulting table in insertion order.
List<ParsedTxn> _ingestAll(List<ParsedTxn> incoming) {
  final store = <String, ParsedTxn>{};
  for (final row in incoming) {
    final decision = SmsIngestionPolicy.classify(
      incoming: row,
      existing: store.values.toList(),
      isFirstScan: false,
    );
    for (final flagged in decision.existingToFlag) {
      store[flagged.smsId] = flagged;
    }
    if (decision.action != IngestionAction.skipDuplicate) {
      store[decision.transaction.smsId] = decision.transaction;
    }
  }
  return store.values.toList();
}
