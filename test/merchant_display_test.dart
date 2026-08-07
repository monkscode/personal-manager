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
              'Paid [amount] On HDFC Bank Card [account] at KANDOI BHOGILAL '
              'MULCHA on 21-JUL-26 09:07 AM Bal [amount]',
        ),
      );
      expect(d.name, 'Kandoi Bhogilal Mulcha');
    });

    test('strips aggregator prefix RAZ* and maps to a known merchant', () {
      final d = resolver.resolve(
        txn(
          body:
              '[amount] spent on HDFC Bank Card [account] at RAZ*SWIGGY '
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
              '[amount] spent on HDFC Bank Card [account] at Freeze land '
              'on 2026-07-12:14:35:39.',
        ),
      );
      expect(d.name, 'Freeze Land');
    });

    // The two card shapes that reached the user as "Card Purchase" — 31 rows
    // in the 13-month window. The parser stores its `card purchase`
    // placeholder for both, and nothing here read past it, so step 2 handed
    // the placeholder back as though it were a resolved name.
    test('the newer Axis card body names the merchant after the timestamp', () {
      final d = resolver.resolve(
        txn(
          sender: 'AD-AXISBK-S',
          merchant: 'card purchase',
          body:
              'Spent\nCard no. [account]\n[amount]\n07-07-25 21:16:01\n'
              'Disha Enter\nAvl Lmt [amount]\n'
              'SMS BLOCK [number] to [number], if not you - Axis Bank',
        ),
      );
      expect(d.name, 'Disha Enter');
    });

    test('the ICICI card body names the merchant after the second "on"', () {
      final d = resolver.resolve(
        txn(
          sender: 'JD-ICICIT-S',
          merchant: 'card purchase',
          body:
              '[amount] spent using ICICI Bank Card [account] on 27-Dec-25 '
              'on AMAZON INDIA CY. Avl Limit: [amount]. If not you, call '
              '[number] [number]/SMS BLOCK [number] to [number].',
        ),
      );
      // Canonicalised: the bank truncates to ~11 characters and the corpus
      // carries six spellings of this one merchant.
      expect(d.name, 'Amazon');
    });

    test('the limit line is never mistaken for the merchant', () {
      // The pattern takes the line after the timestamp on faith, because Axis
      // always puts the merchant there. When it does not, the pattern really
      // does capture "Avl Lmt INR 5000.00" — measured, not assumed. What keeps
      // that off the screen is PayeeText.sanitize, whose footer rule cuts at
      // `\bavl\b` and leaves nothing with a letter in it.
      //
      // So this pins a composition rather than one regex: loosen that footer
      // rule and a payee called "Avl Lmt Inr 5000.00" appears on Axis rows.
      final d = resolver.resolve(
        txn(
          sender: 'AD-AXISBK-S',
          merchant: 'card purchase',
          body: 'Spent\nCard no. XX1234\nINR 100.00\n07-07-25 21:16:01\n'
              'Avl Lmt INR 5000.00\n'
              'SMS BLOCK 1234 to 919000000000, if not you - Axis Bank',
        ),
      );
      expect(d.name, 'Card Purchase');
    });
  });

  group('ATM / cash', () {
    test('ATM withdrawal shows "Cash withdrawal" and cash category', () {
      final d = resolver.resolve(
        txn(
          type: TxnType.atm,
          body:
              '[amount] withdrawn from HDFC Bank Card [account] at SCIENCE '
              'CITY-II on 17-07-26:20:20:43 Avl bal: [amount].',
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
              'For IMPS -Federal bank- [number] Avl bal [amount]',
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

  group('normalizeSenderHeader', () {
    test('strips the two-letter operator/access code prefix', () {
      expect(normalizeSenderHeader('VM-HDFCBK'), 'HDFCBK');
      expect(normalizeSenderHeader('AD-SBIINB'), 'SBIINB');
      expect(normalizeSenderHeader('AX-ICICIT'), 'ICICIT');
    });

    test('strips a trailing single-letter category suffix (T/P/S)', () {
      expect(normalizeSenderHeader('VM-HDFCBK-S'), 'HDFCBK');
      expect(normalizeSenderHeader('JD-SBIINB-T'), 'SBIINB');
      expect(normalizeSenderHeader('BZ-ICICIB-P'), 'ICICIB');
    });

    test('passes a bare header through unchanged (uppercased)', () {
      expect(normalizeSenderHeader('HDFCBK'), 'HDFCBK');
      expect(normalizeSenderHeader('hdfcbk'), 'HDFCBK');
    });

    test('trims surrounding whitespace', () {
      expect(normalizeSenderHeader('  VK-KOTAKB  '), 'KOTAKB');
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

  // TASK-45. The resolver reads the *redacted* body, so its vocabulary is the
  // redactor's five tokens rather than raw digits. Same rule as the parser's
  // `_tidyPayee`, stated against the other vocabulary.
  group('TASK-45 — a redaction placeholder is not a payee name', () {
    test('a placeholder standing alone is refused', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-ICICIT-S',
          merchant: 'card purchase',
          body: '[amount] spent on ICICI Bank Card [account] on 05-Aug-26 at '
              '[number]. Avl Lmt: [amount]',
        ),
      );

      expect(d.name, isNot(contains('[')));
    });

    test('a placeholder embedded in a longer capture is refused', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-ICICIT-S',
          merchant: 'card purchase',
          body: '[amount] spent on ICICI Bank Card [account] on 05-Aug-26. '
              'To dispute, call [number] or SMS BLOCK [number] to [number]',
        ),
      );

      expect(d.name, isNot(contains('[')));
    });

    test('every token the redactor emits is refused', () {
      for (final token in ['[amount]', '[account]', '[vpa]', '[ref]', '[number]']) {
        final d = resolver.resolve(
          txn(
            sender: 'VM-AXISBK-S',
            body: 'payment to $token done',
          ),
        );

        expect(
          d.name,
          isNot(contains('[')),
          reason: '$token reached the user as a payee name',
        );
      }
    });

    // Verbatim from the device. The body names the merchant outright
    // (`Info:Amazon.in - Bil`) and the resolver rendered `[number]`, because
    // the `to [number]` in the dispute footer is what it captured.
    test('a dispute footer never outranks the body', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-ICICIT-S',
          merchant: 'card purchase',
          body: '[amount] debited on Credit Card [account] on 01-Feb-21.'
              'Info:Amazon.in - Bil.Avbl Lmt:[amount].Call [number] for '
              'dispute or SMS BLOCK [number] to [number]',
        ),
      );

      expect(d.name, isNot(contains('[')));
    });

    // Guard: a real payee alongside a placeholder keeps the real part.
    test('a real payee beside a reference keeps the payee', () {
      final d = resolver.resolve(
        txn(
          sender: 'VM-AXISBK-S',
          body: '[amount] debited at ECS/RAZORPAY SOFTW/[number]. Avl Bal [amount]',
        ),
      );

      expect(d.name.toLowerCase(), contains('razorpay'));
      expect(d.name, isNot(contains('[')));
    });
  });
}
