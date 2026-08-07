// The detector proposes; this screen is where the user decides. Both answers
// have to be reachable, because a "no" is as load-bearing as a "yes": two of
// the owner's own-name debits are genuine payments to someone sharing their
// name, and one detected pair is a coincidence.
import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/features/app/self_transfer_review_screen.dart';
import 'package:expense_insight/services/self_transfer_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _leg({
  required String smsId,
  required TransactionDirection direction,
  required String accountLast4,
  int amountPaise = 5000000,
  String? merchant,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: DateTime(2026, 1, 13),
  merchant: merchant,
  accountLast4: accountLast4,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h-$smsId',
  scanBatchId: 'b',
);

final _candidate = SelfTransferCandidate(
  debit: _leg(
    smsId: 'debit-hdfc',
    direction: TransactionDirection.debit,
    accountLast4: '7001',
    merchant: 'payee name',
  ),
  credit: _leg(
    smsId: 'credit-axis',
    direction: TransactionDirection.credit,
    accountLast4: '7002',
  ),
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(theme: buildTheme(AppPalette.dark), home: Scaffold(body: child)),
);

void main() {
  group('SelfTransferReviewScreen', () {
    testWidgets('names the amount and both accounts so the pair is recognisable',
        (tester) async {
      await _pump(
        tester,
        SelfTransferReviewScreen(
          candidates: [_candidate],
          onDecide: (_, _) {},
        ),
      );

      expect(find.textContaining('₹50,000'), findsOneWidget);
      expect(find.textContaining('7001'), findsWidgets);
      expect(find.textContaining('7002'), findsWidgets);
    });

    testWidgets('confirming reports the pair as a transfer', (tester) async {
      SelfTransferCandidate? decided;
      bool? verdict;
      await _pump(
        tester,
        SelfTransferReviewScreen(
          candidates: [_candidate],
          onDecide: (candidate, confirmed) {
            decided = candidate;
            verdict = confirmed;
          },
        ),
      );

      await tester.tap(find.byKey(const ValueKey('self-transfer-yes-debit-hdfc')));
      await tester.pump();

      expect(decided?.debit.smsId, 'debit-hdfc');
      expect(verdict, isTrue);
    });

    testWidgets('rejecting reports it as a real payment, not as no answer',
        (tester) async {
      SelfTransferCandidate? decided;
      bool? verdict;
      await _pump(
        tester,
        SelfTransferReviewScreen(
          candidates: [_candidate],
          onDecide: (candidate, confirmed) {
            decided = candidate;
            verdict = confirmed;
          },
        ),
      );

      await tester.tap(find.byKey(const ValueKey('self-transfer-no-debit-hdfc')));
      await tester.pump();

      expect(decided?.debit.smsId, 'debit-hdfc');
      expect(verdict, isFalse);
    });

    testWidgets('says so when there is nothing to decide', (tester) async {
      await _pump(
        tester,
        SelfTransferReviewScreen(candidates: const [], onDecide: (_, _) {}),
      );

      expect(find.byKey(const ValueKey('self-transfer-empty')), findsOneWidget);
    });
  });
}
