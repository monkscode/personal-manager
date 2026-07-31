import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/features/app/sms_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn txn({
  required String smsId,
  double confidence = 0.95,
  int amountPaise = 50000,
  String? merchant = 'Swiggy',
  ReviewReason? reviewReason = ReviewReason.firstScan,
  String? collisionSetId,
  ReviewStatus reviewStatus = ReviewStatus.needsReview,
  DateTime? autoAddedAt,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: DateTime(2026, 7, 5),
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: 'food',
  confidence: confidence,
  reviewStatus: reviewStatus,
  reviewReason: reviewReason,
  collisionSetId: collisionSetId,
  autoAddedAt: autoAddedAt,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.reviewPending,
  rawBodyRedacted: 'redacted',
  bodyHash: 'hash-$smsId',
  scanBatchId: 'scan:test',
);

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('SmsReviewScreen', () {
    testWidgets('pre-checks high-confidence rows and not low-confidence rows', (
      tester,
    ) async {
      await pump(
        tester,
        SmsReviewScreen(
          items: [
            txn(smsId: 'high', confidence: 0.95),
            txn(
              smsId: 'low',
              confidence: 0.6,
              reviewReason: ReviewReason.lowConfidence,
            ),
          ],
          onConfirmSelected: (_) {},
          onDismiss: (_) {},
        ),
      );

      final high = tester.widget<Checkbox>(
        find.byKey(const ValueKey('review-check-high')),
      );
      final low = tester.widget<Checkbox>(
        find.byKey(const ValueKey('review-check-low')),
      );
      expect(high.value, isTrue);
      expect(low.value, isFalse);
    });

    testWidgets('groups collision sets and excludes them from bulk confirm', (
      tester,
    ) async {
      List<ParsedTxn>? confirmed;
      await pump(
        tester,
        SmsReviewScreen(
          items: [
            txn(smsId: 'solo', confidence: 0.95),
            txn(
              smsId: 'dup1',
              collisionSetId: 'collision:x',
              reviewReason: ReviewReason.dedupCollision,
            ),
            txn(
              smsId: 'dup2',
              collisionSetId: 'collision:x',
              reviewReason: ReviewReason.dedupCollision,
            ),
          ],
          onConfirmSelected: (list) => confirmed = list,
          onDismiss: (_) {},
        ),
      );

      expect(find.text('Possible duplicate'), findsOneWidget);
      // Collision rows are not selectable, so no checkbox exists for them.
      expect(find.byKey(const ValueKey('review-check-dup1')), findsNothing);
      expect(find.byKey(const ValueKey('review-check-dup2')), findsNothing);

      await tester.tap(find.text('Select all'));
      await tester.pump();
      await tester.tap(find.text('Confirm selected'));
      await tester.pump();

      expect(confirmed, isNotNull);
      expect(confirmed!.map((t) => t.smsId), ['solo']);
    });

    testWidgets('dismiss invokes the callback with the row', (tester) async {
      ParsedTxn? dismissed;
      await pump(
        tester,
        SmsReviewScreen(
          items: [txn(smsId: 'a')],
          onConfirmSelected: (_) {},
          onDismiss: (t) => dismissed = t,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('dismiss-a')));
      await tester.pump();

      expect(dismissed?.smsId, 'a');
    });
  });

  group('RecentlyAutoAddedView', () {
    testWidgets('lists auto-added rows and surfaces a correction action', (
      tester,
    ) async {
      ParsedTxn? corrected;
      await pump(
        tester,
        RecentlyAutoAddedView(
          items: [
            txn(
              smsId: 'auto',
              merchant: 'Amazon',
              reviewStatus: ReviewStatus.autoAdded,
              reviewReason: null,
              autoAddedAt: DateTime(2026, 7, 5),
            ),
          ],
          onCorrect: (t) => corrected = t,
        ),
      );

      expect(find.text('Amazon'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('correct-auto')));
      await tester.pump();

      expect(corrected?.smsId, 'auto');
    });

    testWidgets('shows an empty state when nothing was auto-added', (
      tester,
    ) async {
      await pump(
        tester,
        RecentlyAutoAddedView(items: const [], onCorrect: (_) {}),
      );

      expect(find.text('No auto-added transactions yet'), findsOneWidget);
    });
  });
}
