import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the device's two August alerts for one HDFC ACH mandate execution
/// (TASK-43). Bodies are the stored redacted forms verbatim.
const _achDebitAlert =
    'UPDATE: [amount] debited from HDFC Bank [account] on 05-AUG-26. '
    'Info: ACH D- HDFC BANK LTD-[number]. Avl bal:[amount]';
const _mandateAlert =
    'PAYMENT ALERT! \n[amount] deducted from HDFC Bank A/C No [account] '
    'towards HDFC LTD UMRN: HDFC[number]';

ParsedTxn txn({
  required String smsId,
  String sender = 'VM-HDFCBK-S',
  TransactionDirection direction = TransactionDirection.debit,
  int amountPaise = 6141500,
  DateTime? date,
  String? merchant,
  String? accountLast4,
  String? refNumber,
  int? balancePaise,
  required String body,
}) => ParsedTxn(
  smsId: smsId,
  sender: sender,
  direction: direction,
  instrument: PaymentInstrument.bank,
  type: TxnType.pos,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 8, 5),
  accountLast4: accountLast4,
  refNumber: refNumber,
  merchant: merchant,
  payeeType: PayeeType.unknown,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  balancePaise: balancePaise,
  rawBodyRedacted: body,
  bodyHash: 'h:${body.hashCode}',
  scanBatchId: 'b',
);

/// The device's real pair: same day, same amount, one payee spelled two ways,
/// complementary field coverage (one carries the balance, the other the
/// account tail), both from HDFCBK under different DLT headers.
List<ParsedTxn> devicePair() => [
  txn(
    smsId: 'provider:12552',
    sender: 'VM-HDFCBK-S',
    merchant: 'hdfc bank ltd',
    balancePaise: 2902221,
    body: _achDebitAlert,
  ),
  txn(
    smsId: 'provider:12554',
    sender: 'JD-HDFCBK-S',
    merchant: 'hdfc ltd',
    accountLast4: '7106',
    body: _mandateAlert,
  ),
];

void main() {
  const normalizer = SmsLiveNormalizer();

  List<ParsedTxn> mark(List<ParsedTxn> rows) =>
      normalizer.markSupersededRedeliveries(rows);

  group('one debit, two bank alerts (TASK-43)', () {
    test('marks exactly one of the two alerts as superseded', () {
      final out = mark(devicePair());

      final superseded = out.where((t) => t.supersededBySmsId != null).toList();
      expect(superseded, hasLength(1));
      // The earliest (txnDate, smsId) survives, reusing collapseRedeliveries'
      // existing ordering — so the readable `hdfc bank ltd` row is the winner.
      expect(superseded.single.smsId, 'provider:12554');
      expect(superseded.single.supersededBySmsId, 'provider:12552');
    });

    test('no row is dropped — the loser is marked, never deleted', () {
      expect(mark(devicePair()).map((t) => t.smsId), [
        'provider:12552',
        'provider:12554',
      ]);
    });
  });

  group('guards — these must hold before and after the fix', () {
    test('GUARD differing balances keep both rows (indian clearing corp)', () {
      final out = mark([
        txn(
          smsId: 'a',
          sender: 'VD-HDFCBK-S',
          amountPaise: 1000000,
          merchant: 'indian clearing corp',
          balancePaise: 15661718,
          body: 'UPDATE: [amount] debited from HDFC Bank [account] on '
              '05-JUN-26. Info: ACH D- Indian Clearing Corp-[number]B3BM4VEJ. '
              'Avl bal:[amount]',
        ),
        txn(
          smsId: 'b',
          sender: 'JM-HDFCBK-S',
          amountPaise: 1000000,
          merchant: 'indian clearing corp',
          balancePaise: 16661718,
          body: 'UPDATE: [amount] debited from HDFC Bank [account] on '
              '05-JUN-26. Info: ACH D- Indian Clearing Corp-[number]KLTSN4HE. '
              'Avl bal:[amount]',
        ),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD a balance that differs beats the spelling relation', () {
      final rows = devicePair();
      final out = mark([
        rows.first,
        rows.last.copyWith(balancePaise: 9999999),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD a self-identifying body keeps both rows (science city-ii)', () {
      final out = mark([
        txn(
          smsId: 'a',
          amountPaise: 2000000,
          merchant: 'science city-ii',
          body: '[amount] withdrawn from HDFC Bank Card [account] at '
              'SCIENCE CITY-II on [number]-07-17:20:23:35 Avl bal: [amount].',
        ),
        txn(
          smsId: 'b',
          sender: 'JD-HDFCBK-S',
          amountPaise: 2000000,
          merchant: 'science city-ii card',
          body: '[amount] withdrawn from HDFC Bank Card [account] at '
              'SCIENCE CITY-II on [number]-07-17:20:22:38 Avl bal: [amount].',
        ),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD two genuinely different payees are never merged', () {
      final out = mark([
        txn(smsId: 'a', merchant: 'google', body: _achDebitAlert),
        txn(
          smsId: 'b',
          sender: 'JD-HDFCBK-S',
          merchant: 'phonepe',
          body: _mandateAlert,
        ),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD TASK-42 counterexample: one payee, two banks, never merged', () {
      // `google` and `google asia pacific pte.ltd` ARE token-subset related and
      // ARE two different subscriptions. On the device they never share a day,
      // but the rule must not depend on that: they are billed by different
      // banks, and two alerts about one event come from one bank.
      final out = mark([
        txn(
          smsId: 'a',
          sender: 'AX-AXISBK-S',
          amountPaise: 199900,
          merchant: 'google',
          body: _achDebitAlert,
        ),
        txn(
          smsId: 'b',
          sender: 'VM-HDFCBK-S',
          amountPaise: 199900,
          merchant: 'google asia pacific pte.ltd',
          body: _mandateAlert,
        ),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD two accounts that both name a tail must agree', () {
      final rows = devicePair();
      final out = mark([
        rows.first.copyWith(accountLast4: '1111'),
        rows.last,
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });

    test('GUARD a different calendar day is not the same event', () {
      final rows = devicePair();
      final out = mark([
        rows.first,
        txn(
          smsId: 'provider:12554',
          sender: 'JD-HDFCBK-S',
          merchant: 'hdfc ltd',
          accountLast4: '7106',
          date: DateTime(2026, 8, 6),
          body: _mandateAlert,
        ),
      ]);
      expect(out.where((t) => t.supersededBySmsId != null), isEmpty);
    });
  });
}
