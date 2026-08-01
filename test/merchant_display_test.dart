import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/merchant_display.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ParsedTxn] mirroring what the on-device parser stores. Defaults to
/// a debit; individual tests override the fields under test. Bodies are taken
/// (redacted) from real device messages so the resolver is grounded in the
/// user's actual SMS formats.
ParsedTxn txn({
  String sender = 'VM-HDFCBK-S',
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.pos,
  PaymentInstrument instrument = PaymentInstrument.card,
  String? merchant,
  String? upiVpaNorm,
  String categoryKey = 'other',
  required String body,
}) => ParsedTxn(
  smsId: 'sms:${body.hashCode}',
  sender: sender,
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: 50000,
  txnDate: DateTime(2026, 7, 12),
  merchant: merchant,
  upiVpaNorm: upiVpaNorm,
  payeeType: PayeeType.unknown,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: body,
  bodyHash: 'h',
  scanBatchId: 'b',
);

void main() {
  const resolver = MerchantDisplay();

  group('merchant name extraction from the transaction body', () {
    test('card "at MERCHANT on <date>" yields a clean title-cased name', () {
      final d = resolver.resolve(
        txn(
          body:
              'Paid [amount] On HDFC Bank Card 5555 at KANDOI BHOGILAL MULCHA '
              'on 21-JUL-26 09:07 AM Bal [amount]',
        ),
      );
      expect(d.name, 'Kandoi Bhogilal Mulcha');
    });

    test('strips aggregator prefix RAZ* and maps to a known merchant', () {
      final d = resolver.resolve(
        txn(
          body:
              '[amount] spent on HDFC Bank Card x7115 at RAZ*SWIGGY '
              'on 2026-07-11:22:03:27.Not U?',
        ),
      );
      expect(d.name, 'Swiggy');
      expect(d.categoryKey, 'food');
      expect(d.categoryLabel, 'Food & Dining');
    });

    test('spent ... at MERCHANT. (period terminated) yields the merchant', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-ICICIT-S',
          body:
              '[amount] spent on ICICI Bank Card [account] on 12-Jul-26 at '
              'SANSKRUTIK. Avl Lmt: [amount].',
        ),
      );
      expect(d.name, 'Sanskrutik');
    });

    test('UPI/P2M/<ref>/<NAME> yields the payee name', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-AXISBK-S',
          type: TxnType.upi,
          instrument: PaymentInstrument.bank,
          body:
              '[amount] debited\n[account]\n01-12-25, 10:57:27\n'
              'UPI/P2M/549148394747/ACME DIGITAL PRIVAT\nAxis Bank',
        ),
      );
      expect(d.name, 'Acme Digital Privat');
    });

    test('lower-cased merchant token is title-cased ("Freeze Land")', () {
      final d = resolver.resolve(
        txn(
          body:
              '[amount] spent on HDFC Bank Card x7115 at Freeze land '
              'on 2026-07-12:14:35:39.',
        ),
      );
      expect(d.name, 'Freeze Land');
    });
  });

  group('ATM / cash', () {
    test('ATM withdrawal shows "Cash withdrawal" and cash category', () {
      final d = resolver.resolve(
        txn(
          type: TxnType.atm,
          body:
              '[amount] withdrawn from HDFC Bank Card x1111 at MAIN STREET ATM '
              'on 2026-07-17:20:20:43 Avl bal: [amount].',
        ),
      );
      expect(d.name, 'Cash withdrawal');
      expect(d.categoryKey, 'cash');
      expect(d.categoryLabel, 'Cash');
    });
  });

  group('credits / transfers', () {
    test('IMPS credit is categorised as income, not a spend', () {
      final d = resolver.resolve(
        txn(
          direction: TransactionDirection.credit,
          type: TxnType.other,
          instrument: PaymentInstrument.bank,
          body:
              'Received! [amount] in HDFC Bank [account] On 21-07-26 '
              'For IMPS -Federal bank- 620218359066 Avl bal [amount]',
        ),
      );
      expect(d.categoryKey, 'income');
      expect(d.categoryLabel, 'Income');
    });
  });

  group('merchant / VPA field fallbacks', () {
    test('known merchant in the stored merchant field maps to canonical name', () {
      final d = resolver.resolve(
        txn(
          type: TxnType.upi,
          instrument: PaymentInstrument.bank,
          merchant: 'amazon pay in e',
          upiVpaNorm: 'amazonpayin@apl',
          body: '[amount] debited [account] Axis Bank',
        ),
      );
      expect(d.name, 'Amazon');
      expect(d.categoryKey, 'shopping');
    });

    test('opaque hex VPA prefix is not used as a name; falls back to bank', () {
      final d = resolver.resolve(
        txn(
          type: TxnType.upi,
          instrument: PaymentInstrument.bank,
          merchant: '77d1cc47c9de4e9c8e351a8077d60879',
          upiVpaNorm: '77d1cc47c9de4e9c8e351a8077d60879@ybl',
          body: '[amount] debited [account] HDFC Bank',
        ),
      );
      expect(d.name, 'HDFC Bank');
    });

    test('readable UPI handle is title-cased when no merchant token exists', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-AXISBK-S',
          type: TxnType.upi,
          instrument: PaymentInstrument.bank,
          merchant: 'priyalpatel1910',
          upiVpaNorm: 'samplepayee1910@okaxis',
          body: '[amount] debited [account] Axis Bank',
        ),
      );
      expect(d.name, 'Priyalpatel1910');
    });
  });

  group('bank-name fallback', () {
    test('no merchant/VPA/at-token falls back to the friendly bank name', () {
      final d = resolver.resolve(
        txn(
          type: TxnType.other,
          instrument: PaymentInstrument.bank,
          body: '[amount] debited [account] 05-07-26 Axis Bank',
          sender: 'AD-HDFCBK-S',
        ),
      );
      expect(d.name, 'HDFC Bank');
    });
  });

  group('category labels', () {
    test('labelForCategory maps keys to human labels', () {
      expect(MerchantDisplay.labelForCategory('food'), 'Food & Dining');
      expect(MerchantDisplay.labelForCategory('groceries'), 'Groceries');
      expect(MerchantDisplay.labelForCategory('transport'), 'Transport');
      expect(MerchantDisplay.labelForCategory('utilities'), 'Bills & Utilities');
      expect(MerchantDisplay.labelForCategory('cash'), 'Cash');
      expect(MerchantDisplay.labelForCategory('other'), 'Other');
    });
  });
}
