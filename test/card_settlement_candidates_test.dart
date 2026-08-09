// Two candidate sources, one confirmation gate. Nothing is ever auto-confirmed.
//
// Source 1 is a debit that paired with a card acknowledgement -- strong
// evidence, and how Cheq Digital was found at all. Source 2 is string
// adjacency to an already-confirmed front, and exists for exactly one reason:
// the bank truncates the same payee at four different lengths, and the
// untruncated spellings do not all pair. `cheq` -- Rs.1,90,417, the single
// largest card payment on the device -- never pairs with anything.
//
// Source 2 is NOT a prefix-matching rule. Letting pairing learn merchant names
// unsupervised was measured and rejected: it erased 11 innocent rows, because
// `amazon` is a proper prefix of `amazon pay credit c` and a stationery shop
// paired once by coincidence. Adjacency proposes; only a stored answer decides.
import 'package:expense_insight/data/card_settlement_front_store.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/card_settlement_candidates.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn _debit({
  required int amountPaise,
  required DateTime date,
  required String merchant,
  String? smsId,
}) => ParsedTxn(
  smsId: smsId ?? 'debit:$merchant:$amountPaise',
  sender: 'VM-HDFCBK-S',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.upi,
  amountPaise: amountPaise,
  txnDate: date,
  accountLast4: '4501',
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'Sent [amount] From HDFC Bank A/C [account] To $merchant',
  bodyHash: 'h',
  scanBatchId: 'b',
);

ParsedTxn _ack({
  required int amountPaise,
  required DateTime date,
  required String cardLast4,
  String? smsId,
}) => ParsedTxn(
  smsId: smsId ?? 'ack:$cardLast4:$amountPaise',
  sender: 'VM-HDFCBK-S',
  direction: TransactionDirection.credit,
  instrument: PaymentInstrument.card,
  type: TxnType.pos,
  amountPaise: amountPaise,
  txnDate: date,
  accountLast4: cardLast4,
  payeeType: PayeeType.merchant,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted:
      'Payment of [amount] has been received towards your Axis Bank '
      'Credit Card [account]',
  bodyHash: 'h',
  scanBatchId: 'b',
);

void main() {
  const finder = CardSettlementCandidateFinder();

  test('a paired merchant becomes a candidate carrying its evidence', () {
    final debit = _debit(
      amountPaise: 228200,
      date: DateTime(2026, 8, 1),
      merchant: 'CRED Club',
    );
    final ack = _ack(
      amountPaise: 230700,
      date: DateTime(2026, 8, 1),
      cardLast4: '4321',
    );

    final found = finder.find([debit, ack], CardSettlementFronts.empty);

    expect(found, hasLength(1));
    expect(found.single.merchantNorm, 'cred club');
    expect(found.single.displayMerchant, 'CRED Club');
    expect(found.single.source, CardSettlementCandidateSource.paired);
    expect(found.single.cardLast4, '4321');
    expect(found.single.pointsPaise, 2500);
  });

  test('an already-answered merchant is never re-proposed', () {
    final txns = [
      _debit(
        amountPaise: 228200,
        date: DateTime(2026, 8, 1),
        merchant: 'CRED Club',
      ),
      _ack(
        amountPaise: 230700,
        date: DateTime(2026, 8, 1),
        cardLast4: '4321',
      ),
    ];

    expect(
      finder.find(txns, const CardSettlementFronts({'cred club': true})),
      isEmpty,
    );
    // A rejection is as final as a confirmation. Without this, the stationery
    // shop comes back after every scan.
    expect(
      finder.find(txns, const CardSettlementFronts({'cred club': false})),
      isEmpty,
    );
  });

  test('a truncated spelling of a confirmed front is proposed', () {
    // `cheq` never pairs with anything, and it is Rs.1,90,417 -- the largest
    // single card payment on the device. Only adjacency reaches it.
    final found = finder.find(
      [
        _debit(
          amountPaise: 19041680,
          date: DateTime(2025, 5, 1),
          merchant: 'Cheq',
        ),
      ],
      const CardSettlementFronts({'cheq digital privat': true}),
    );

    expect(found, hasLength(1));
    expect(found.single.merchantNorm, 'cheq');
    expect(found.single.source, CardSettlementCandidateSource.adjacent);
    expect(found.single.adjacentTo, 'cheq digital privat');
    expect(found.single.ack, isNull);
    expect(found.single.pointsPaise, isNull);
  });

  test('adjacency proposes and does not decide', () {
    // The whole safety argument. `amazon`, `amazon pay` and `cred store` are
    // all adjacent to a confirmed front, and all are real spending. They must
    // reach the user as questions, never as exclusions.
    final found = finder.find(
      [
        _debit(
          amountPaise: 62800,
          date: DateTime(2020, 12, 5),
          merchant: 'Amazon',
        ),
        _debit(
          amountPaise: 35000,
          date: DateTime(2025, 11, 27),
          merchant: 'Amazon Pay',
        ),
        _debit(
          amountPaise: 59900,
          date: DateTime(2025, 3, 22),
          merchant: 'CRED Store',
        ),
      ],
      const CardSettlementFronts({
        'amazon pay credit c': true,
        'cred club': true,
        // `cred store` is a sibling of `cred club`, not a prefix -- adjacency
        // deliberately does not reach it through that front. What reaches it
        // is the bare `cred`, one of the eight merchants the device's own
        // pairing confirms, sitting at exactly the four-character floor.
        'cred': true,
      }),
    );

    expect(
      found.map((c) => c.merchantNorm).toSet(),
      {'amazon', 'amazon pay', 'cred store'},
    );
    expect(
      found.every((c) => c.source == CardSettlementCandidateSource.adjacent),
      isTrue,
    );
  });

  test('a sibling of a confirmed front is not adjacent to it', () {
    // `cred store` and `cred club` share "cred " and then diverge -- neither
    // is a prefix of the other, so adjacency must not fire here. This is the
    // Rs.599 of real CRED Store shopping the old `\bcred\b` rule erased. What
    // does reach `cred store` on the device is the bare `cred` front, covered
    // by the test above.
    final found = finder.find(
      [
        _debit(
          amountPaise: 59900,
          date: DateTime(2025, 3, 22),
          merchant: 'CRED Store',
        ),
      ],
      const CardSettlementFronts({'cred club': true}),
    );

    expect(found, isEmpty);
  });

  test('a short merchant is never adjacent to anything', () {
    // Without a floor, a two-character payee is a prefix of half the corpus.
    final found = finder.find(
      [
        _debit(
          amountPaise: 10000,
          date: DateTime(2026, 1, 1),
          merchant: 'Che',
        ),
      ],
      const CardSettlementFronts({'cheq digital privat': true}),
    );

    expect(found, isEmpty);
  });

  test('an unrelated merchant is not adjacent', () {
    final found = finder.find(
      [
        _debit(
          amountPaise: 42000,
          date: DateTime(2026, 8, 1),
          merchant: 'Swiggy',
        ),
      ],
      const CardSettlementFronts({'cred club': true}),
    );

    expect(found, isEmpty);
  });

  test('adjacency runs against confirmed fronts only', () {
    // A rejected merchant must not seed further proposals.
    final found = finder.find(
      [
        _debit(
          amountPaise: 19041680,
          date: DateTime(2025, 5, 1),
          merchant: 'Cheq',
        ),
      ],
      const CardSettlementFronts({'cheq digital privat': false}),
    );

    expect(found, isEmpty);
  });

  test('one candidate per merchant, however many payments it has', () {
    final found = finder.find(
      [
        _debit(
          amountPaise: 228200,
          date: DateTime(2026, 8, 1),
          merchant: 'CRED Club',
          smsId: 'a',
        ),
        _ack(
          amountPaise: 230700,
          date: DateTime(2026, 8, 1),
          cardLast4: '4321',
          smsId: 'ack-a',
        ),
        _debit(
          amountPaise: 118100,
          date: DateTime(2026, 6, 29),
          merchant: 'CRED Club',
          smsId: 'b',
        ),
        _ack(
          amountPaise: 119600,
          date: DateTime(2026, 6, 29),
          cardLast4: '4321',
          smsId: 'ack-b',
        ),
      ],
      CardSettlementFronts.empty,
    );

    expect(found, hasLength(1));
  });

  test('a debit with no merchant is never a candidate', () {
    final txn = ParsedTxn(
      smsId: 'no-merchant',
      sender: 'VM-AXISBK',
      direction: TransactionDirection.debit,
      instrument: PaymentInstrument.bank,
      type: TxnType.other,
      amountPaise: 549000,
      txnDate: DateTime(2025, 12, 2),
      payeeType: PayeeType.unknown,
      categoryKey: 'other',
      confidence: 0.5,
      reviewStatus: ReviewStatus.autoAdded,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted: '[amount] is due for payment towards Axis Bank CC no.',
      bodyHash: 'h',
      scanBatchId: 'b',
    );

    expect(finder.find([txn], CardSettlementFronts.empty), isEmpty);
  });
}
