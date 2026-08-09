// Thirteen one-time taps for seven years of history: nine confirmations and
// four rejections. The four rejections are the whole safety argument made
// visible -- each is a row that an unsupervised prefix rule erases.
import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/features/app/card_settlement_review_screen.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_settlement_candidates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _txn({
  required String smsId,
  required int amountPaise,
  required DateTime date,
  required TransactionDirection direction,
  required PaymentInstrument instrument,
  String? merchant,
  String? accountLast4,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK-S',
  direction: direction,
  instrument: instrument,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: date,
  accountLast4: accountLast4,
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'body',
  bodyHash: 'h',
  scanBatchId: 'b',
);

final _paired = CardSettlementCandidate(
  merchantNorm: 'cred club',
  displayMerchant: 'CRED Club',
  source: CardSettlementCandidateSource.paired,
  debit: _txn(
    smsId: 'debit-1',
    amountPaise: 228200,
    date: DateTime(2026, 8, 1),
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    merchant: 'CRED Club',
  ),
  ack: _txn(
    smsId: 'ack-1',
    amountPaise: 230700,
    date: DateTime(2026, 8, 1),
    direction: TransactionDirection.credit,
    instrument: PaymentInstrument.card,
    accountLast4: '4321',
  ),
);

final _pairedNoCard = CardSettlementCandidate(
  merchantNorm: 'cred club',
  displayMerchant: 'CRED Club',
  source: CardSettlementCandidateSource.paired,
  debit: _txn(
    smsId: 'debit-3',
    amountPaise: 228200,
    date: DateTime(2026, 8, 1),
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    merchant: 'CRED Club',
  ),
  ack: _txn(
    smsId: 'ack-2',
    amountPaise: 230700,
    date: DateTime(2026, 8, 1),
    direction: TransactionDirection.credit,
    instrument: PaymentInstrument.card,
  ),
);

final _adjacent = CardSettlementCandidate(
  merchantNorm: 'cheq',
  displayMerchant: 'Cheq',
  source: CardSettlementCandidateSource.adjacent,
  adjacentTo: 'cheq digital privat',
  debit: _txn(
    smsId: 'debit-2',
    amountPaise: 19041680,
    date: DateTime(2025, 5, 1),
    direction: TransactionDirection.debit,
    instrument: PaymentInstrument.bank,
    merchant: 'Cheq',
  ),
);

Widget _host(
  List<CardSettlementCandidate> candidates,
  void Function(CardSettlementCandidate, bool) onDecide,
) => MaterialApp(
  theme: buildTheme(AppPalette.dark),
  home: Scaffold(
    body: CardSettlementReviewScreen(
      candidates: candidates,
      onDecide: onDecide,
    ),
  ),
);

void main() {
  testWidgets('a paired candidate shows the card and the points', (
    tester,
  ) async {
    await tester.pumpWidget(_host([_paired], (_, _) {}));

    expect(find.textContaining('CRED Club'), findsWidgets);
    expect(find.textContaining('Card 4321'), findsWidgets);
    expect(find.textContaining('₹25 of it came from points'), findsWidgets);
  });

  testWidgets(
    'a paired candidate whose ack names no card still shows the acknowledgement',
    (tester) async {
      await tester.pumpWidget(_host([_pairedNoCard], (_, _) {}));

      expect(find.textContaining('₹2,307'), findsWidgets);
      expect(find.textContaining('null'), findsNothing);
    },
  );

  testWidgets('an adjacent candidate names the front it resembles', (
    tester,
  ) async {
    await tester.pumpWidget(_host([_adjacent], (_, _) {}));

    expect(find.textContaining('Cheq'), findsWidgets);
    expect(find.textContaining('cheq digital privat'), findsWidgets);
  });

  testWidgets('confirming reports true for that candidate', (tester) async {
    CardSettlementCandidate? decided;
    bool? verdict;
    await tester.pumpWidget(
      _host([_paired], (candidate, confirmed) {
        decided = candidate;
        verdict = confirmed;
      }),
    );

    await tester.tap(find.text('Yes, a card bill'));
    await tester.pump();

    expect(decided?.merchantNorm, 'cred club');
    expect(verdict, isTrue);
  });

  testWidgets('declining reports false', (tester) async {
    bool? verdict;
    await tester.pumpWidget(
      _host([_paired], (_, confirmed) => verdict = confirmed),
    );

    await tester.tap(find.text('No, a purchase'));
    await tester.pump();

    expect(verdict, isFalse);
  });

  testWidgets('an empty list says so rather than showing a blank tab', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const [], (_, _) {}));

    expect(find.textContaining('Nothing to review'), findsOneWidget);
  });
}
