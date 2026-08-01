import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ParsedTxn] with the fields the normalizer keys off. Bodies mirror
/// (redacted) real device messages so the dedup/enrich logic is grounded in the
/// user's actual SMS formats.
ParsedTxn txn({
  required String smsId,
  String sender = 'VM-HDFCBK-S',
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.pos,
  int amountPaise = 1000000,
  DateTime? date,
  String? merchant,
  String? upiVpaNorm,
  String categoryKey = 'other',
  int? balancePaise,
  required String body,
}) => ParsedTxn(
  smsId: smsId,
  sender: sender,
  direction: direction,
  instrument: PaymentInstrument.bank,
  type: type,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 7, 5),
  merchant: merchant,
  upiVpaNorm: upiVpaNorm,
  payeeType: PayeeType.unknown,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  balancePaise: balancePaise,
  rawBodyRedacted: body,
  bodyHash: 'h:${body.hashCode}',
  scanBatchId: 'b',
);

void main() {
  const normalizer = SmsLiveNormalizer();

  group('dedup — same event delivered under multiple DLT headers', () {
    test('collapses cross-sender identical content to one row', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          sender: 'AD-HDFCBK-S',
          amountPaise: 6141500,
          body: '[AD-HDFCBK-S] debit 6141500p :: [amount] debited [account] '
              '05-12-25, 10:57:27 UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
        txn(
          smsId: 'b',
          sender: 'VM-HDFCBK-S',
          amountPaise: 6141500,
          body: '[VM-HDFCBK-S] debit 6141500p :: [amount] debited [account] '
              '05-12-25, 10:57:27 UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
      ]);
      expect(rows, hasLength(1));
    });

    test('keeps distinct same-day same-amount SIPs (different payee/ref)', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          amountPaise: 1000000,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/111111111111/FUND ALPHA',
        ),
        txn(
          smsId: 'b',
          amountPaise: 1000000,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/222222222222/FUND BETA',
        ),
      ]);
      expect(rows, hasLength(2));
    });

    test('keeps sequential ATM withdrawals (different balance/timestamp)', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          type: TxnType.atm,
          amountPaise: 2000000,
          balancePaise: 5432100,
          body: '[JD-HDFCBK-S] debit 2000000p :: [amount] withdrawn from HDFC '
              'Bank Card x1111 at MAIN STREET ATM on 2026-07-17:20:20:43 '
              'Avl bal: 54321.00',
        ),
        txn(
          smsId: 'b',
          type: TxnType.atm,
          amountPaise: 2000000,
          balancePaise: 3432100,
          body: '[JD-HDFCBK-S] debit 2000000p :: [amount] withdrawn from HDFC '
              'Bank Card x1111 at MAIN STREET ATM on 2026-07-17:20:21:42 '
              'Avl bal: 34321.00',
        ),
      ]);
      expect(rows, hasLength(2));
    });
  });

  group('enrich — fill a stable merchant/category for blank rows', () {
    test('writes the UPI P2M payee as a lowercase merchant owner key', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
      );
      expect(out.merchant, 'acme digital privat');
    });

    test('writes a known-merchant name and its category', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          body: '[amount] spent on HDFC Bank Card x7115 at RAZ*SWIGGY '
              'on 2026-07-11:22:03:27',
        ),
      );
      expect(out.merchant, 'swiggy');
      expect(out.categoryKey, 'food');
    });

    test('does NOT write the bank-name fallback as a merchant', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          type: TxnType.other,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited from your '
              'account towards NEFT',
        ),
      );
      expect(out.merchant, isNull);
    });

    test('is a no-op on rows that already have a good merchant + category', () {
      final original = txn(
        smsId: 'a',
        merchant: 'swiggy',
        categoryKey: 'food',
        body: 'anything',
      );
      final out = normalizer.enrich(original);
      expect(out.merchant, 'swiggy');
      expect(out.categoryKey, 'food');
    });

    test('gives the same owner key to the same payee across months', () {
      final july = normalizer.enrich(
        txn(
          smsId: 'jul',
          date: DateTime(2026, 7, 5),
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/111/ACME DIGITAL PRIVAT',
        ),
      );
      final august = normalizer.enrich(
        txn(
          smsId: 'aug',
          date: DateTime(2026, 8, 5),
          body: '[AD-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/999/ACME DIGITAL PRIVAT',
        ),
      );
      expect(july.merchant, august.merchant);
      expect(july.merchant, isNotEmpty);
    });
  });
}
