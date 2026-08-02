import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const parser = SmsTransactionParser();

RawSms sms({
  required String sender,
  required String body,
  String? providerId,
  DateTime? receivedAt,
}) => RawSms(
  providerId: providerId,
  sender: sender,
  body: body,
  receivedAt: receivedAt ?? DateTime(2026, 7, 9, 18, 45),
);

void main() {
  group('SmsTransactionParser.parseOne', () {
    test('parses a modern UPI debit with amount and UPI ref but no balance', () {
      final txn = parser.parseOne(
        sms(
          providerId: '101',
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: Rs. 450.00 debited via UPI to swiggy@okhdfcbank. UPI Ref 123456789012.',
        ),
        scanBatchId: 'scan-1',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.smsId, 'provider:101');
      expect(txn.direction, TransactionDirection.debit);
      expect(txn.instrument, PaymentInstrument.bank);
      expect(txn.type, TxnType.upi);
      expect(txn.amountPaise, 45000);
      expect(txn.refNumber, '123456789012');
      expect(txn.upiVpaNorm, 'swiggy@okhdfcbank');
      expect(txn.merchant, 'swiggy');
      expect(txn.categoryKey, 'groceries');
      expect(txn.confidence, greaterThanOrEqualTo(0.8));
      expect(txn.rawBodyRedacted, isNot(contains('450.00')));
      expect(txn.bodyHash, hasLength(64));
    });

    test('extracts a strict bank balance anchor only from bank-account SMS', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-ICICIB',
          body:
              'ICICI Bank: INR 2,000 credited to A/c XX1234. Avl Bal INR 50,000.00.',
        ),
        scanBatchId: 'scan-2',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
      expect(txn.instrument, PaymentInstrument.bank);
      expect(txn.amountPaise, 200000);
      expect(txn.accountLast4, '1234');
      expect(txn.balancePaise, 5000000);
    });

    test('never treats credit-card available limit as a cash balance anchor', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VK-HDFCBK',
          body:
              'HDFC Credit Card ending 4321 spent Rs. 1,299 at Amazon. Available credit limit Rs. 50,000.',
        ),
        scanBatchId: 'scan-3',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
      expect(txn.instrument, PaymentInstrument.card);
      expect(txn.amountPaise, 129900);
      expect(txn.accountLast4, '4321');
      expect(txn.balancePaise, isNull);
      expect(txn.categoryKey, 'other');
    });

    test(
      'rejects OTP and promotional messages even when they mention amounts',
      () {
        expect(
          parser.parseOne(
            sms(
              sender: 'VM-HDFCBK',
              body: 'OTP 123456 for payment of Rs. 500. Do not share.',
            ),
            scanBatchId: 'scan-4',
            bodyHashSalt: 'test-salt',
          ),
          isNull,
        );
        expect(
          parser.parseOne(
            sms(
              sender: 'AD-HDFCBK',
              body: 'Get Rs. 1000 cashback offer on your new account today.',
            ),
            scanBatchId: 'scan-4',
            bodyHashSalt: 'test-salt',
          ),
          isNull,
        );
      },
    );

    test('does not use a balance amount as the transaction amount', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'VM-HDFCBK',
            body: 'HDFC Bank: Avl Bal Rs. 5,000 debited from your account.',
          ),
          scanBatchId: 'scan-5',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('rejects body-only bank mentions without two validity signals', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'AD-STORE99',
            body: 'HDFC Bank customers can pay Rs. 500 today.',
          ),
          scanBatchId: 'scan-6',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('rejects substring-only bank names from non-bank senders', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'AD-STORE99',
            body: 'myhdfcbonus says Rs. 500 debited via UPI Ref 987654321098.',
          ),
          scanBatchId: 'scan-7',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('prefers debit when a debit verb and a non-inflow credit verb both appear', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'Rs 500 debited from a/c XX1234; payment received by MERCHANT',
        ),
        scanBatchId: 'scan-8',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
    });

    test('an explicit refund credit wins over an incidental debit verb', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'Refund of Rs 500 credited; the original amount debited earlier. A/c XX1234',
        ),
        scanBatchId: 'scan-9',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
    });

    test('skips a colon-form balance and uses the transaction amount', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'HDFC Bank: Avl Bal: Rs 5,000. Rs 500 debited from a/c XX1234.',
        ),
        scanBatchId: 'scan-10',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.amountPaise, 50000);
    });

    test('flags two equally plausible amounts as parser-uncertain and routes to review', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'HDFC Bank: Rs. 500 debited. Rs. 700 debited. Ref 123456.',
        ),
        scanBatchId: 'scan-11',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.confidence, greaterThanOrEqualTo(0.8));
      expect(txn.reviewReason, ReviewReason.parserUncertain);
      expect(txn.reviewStatus, ReviewStatus.needsReview);

      final decision = SmsIngestionPolicy.classify(
        incoming: txn,
        existing: const [],
        isFirstScan: false,
      );

      expect(decision.action, IngestionAction.queueReview);
      expect(decision.transaction.reviewReason, ReviewReason.parserUncertain);
    });
  });

  group('promotional copy never becomes money', () {
    test('a pre-approved loan offer is not a transaction', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'Congratulations! Rs. 5,00,000 pre-approved Personal Loan can be '
              'credited to your HDFC Bank A/c XX1234 instantly. Apply now.',
        ),
        scanBatchId: 'scan-12',
        bodyHashSalt: 'test-salt',
      );

      expect(txn?.reviewStatus, isNot(ReviewStatus.autoAdded));
      expect(txn, isNull);
    });

    test('a rewards-offer teaser is kept out of the auto-added ledger', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              "You've spent Rs.50,000 on your card this year - check your "
              'rewards offer!',
        ),
        scanBatchId: 'scan-13',
        bodyHashSalt: 'test-salt',
      );

      expect(txn?.reviewStatus, isNot(ReviewStatus.autoAdded));
      expect(txn?.reviewStatus, ReviewStatus.needsReview);
      expect(txn?.reviewReason, ReviewReason.parserUncertain);
    });

    test('a real debit carrying a marketing tail is reviewed, not dropped', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: Rs.1,299.00 debited from a/c XX1234 at BIGBAZAAR. '
              'Avl Bal Rs.20,000.00. Get an exclusive offer on your next '
              'purchase, click here.',
        ),
        scanBatchId: 'scan-14',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.amountPaise, 129900);
      expect(txn.direction, TransactionDirection.debit);
      expect(txn.reviewStatus, ReviewStatus.needsReview);
      expect(txn.reviewReason, ReviewReason.parserUncertain);
      expect(txn.coverageBucket, CoverageBucket.reviewPending);
    });

    test('a genuine IMPS credit is not caught by the promo filter', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'Rs.50,000.00 credited to a/c XX1234 by IMPS Ref 112233445566. '
              'Avl Bal Rs.75,000.00.',
        ),
        scanBatchId: 'scan-15',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
      expect(txn.amountPaise, 5000000);
      expect(txn.reviewStatus, ReviewStatus.autoAdded);
      expect(txn.reviewReason, isNull);
    });
  });

  group('money that has not moved', () {
    test('a failed debit notice is rejected outright', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'VM-HDFCBK',
            body:
                'Rs.2,500.00 debited from A/c XX1234 could not be processed. '
                'The amount will be credited back in 3 days.',
          ),
          scanBatchId: 'scan-16',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('an autopay pre-notice takes the stated date and never auto-adds', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          receivedAt: DateTime(2025, 7, 2, 10),
          body:
              'Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25 for '
              'NETFLIX UPI Autopay. Ref 512345678901.',
        ),
        scanBatchId: 'scan-17',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.txnLocalDate, '2025-07-05');
      expect(txn.reviewStatus, ReviewStatus.needsReview);
      expect(txn.reviewReason, ReviewReason.parserUncertain);
      expect(txn.coverageBucket, CoverageBucket.reviewPending);

      final decision = SmsIngestionPolicy.classify(
        incoming: txn,
        existing: const [],
        isFirstScan: false,
      );

      expect(decision.action, IngestionAction.queueReview);
      expect(decision.transaction.reviewStatus, ReviewStatus.needsReview);
    });

    test('a pre-notice plus the real debit ingest as one transaction', () {
      final messages = [
        sms(
          sender: 'VM-HDFCBK',
          receivedAt: DateTime(2025, 7, 2, 10),
          body:
              'Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25 for '
              'NETFLIX UPI Autopay. Ref 512345678901.',
        ),
        sms(
          sender: 'VM-HDFCBK',
          receivedAt: DateTime(2025, 7, 5, 6, 30),
          body:
              'Rs.499.00 debited from A/c XX1234 for NETFLIX UPI Autopay. '
              'Ref 512345678901.',
        ),
      ];

      final stored = <ParsedTxn>[];
      for (final message in messages) {
        final parsed = parser.parseOne(
          message,
          scanBatchId: 'autopay',
          bodyHashSalt: 'test-salt',
        );
        if (parsed == null) continue;
        final decision = SmsIngestionPolicy.classify(
          incoming: parsed,
          existing: stored,
          isFirstScan: false,
        );
        if (decision.action != IngestionAction.skipDuplicate) {
          stored.add(decision.transaction);
        }
      }

      expect(stored, hasLength(1));
      expect(stored.single.amountPaise, 49900);
      expect(stored.single.txnLocalDate, '2025-07-05');
      expect(stored.single.reviewStatus, isNot(ReviewStatus.autoAdded));
    });
  });

  group('direction follows the verb governing the amount', () {
    test('a loan EMI is an outflow, not income', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: Rs.15,000.00 debited from A/c XX1234 towards loan '
              'repayment. Avl Bal Rs.5,000.00.',
        ),
        scanBatchId: 'scan-18',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
      expect(txn.amountPaise, 1500000);
    });

    test('a refund credit stays an inflow', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'Rs.5,000.00 credited to A/c XX1234 as refund for order #123',
        ),
        scanBatchId: 'scan-19',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
    });

    test('a reversal credit stays an inflow', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'Rs.2,000.00 reversed to your A/c XX1234',
        ),
        scanBatchId: 'scan-20',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
    });

    test('cashback is an inflow despite the bill it refers to being paid', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: Rs.100.00 credited to A/c XX1234 as cashback for '
              'your bill paid on 26-06-25.',
        ),
        scanBatchId: 'scan-21',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.credit);
      expect(txn.amountPaise, 10000);
    });

    test('the common UPI debit still reads as a debit', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body: 'Rs.1,250.00 debited from a/c XX1234 to swiggy@okhdfcbank',
        ),
        scanBatchId: 'scan-22',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
    });

    test('no verb beside the amount falls back to the whole-message rule', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'HDFC Bank: A/c XX1234 has been debited with an amount of '
              'Rs.750.00 for your electricity bill.',
        ),
        scanBatchId: 'scan-23',
        bodyHashSalt: 'test-salt',
      );

      expect(txn, isNotNull);
      expect(txn!.direction, TransactionDirection.debit);
      expect(txn.amountPaise, 75000);
    });
  });

  group('high-volume formats that used to parse to nothing', () {
    test('the HDFC UPI alert that separates "Sent" from "To" parses', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK',
          body:
              'Sent Rs.500.00 From HDFC Bank A/C x1234 To rahul@okhdfcbank '
              'On 05/01/25 Ref 501234567890',
        ),
        scanBatchId: 'scan-24',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
      expect(txn.amountPaise, 50000);
      expect(txn.accountLast4, '1234');
      expect(txn.refNumber, '501234567890');
    });

    test('the SBI UPI alert with no currency token parses', () {
      final txn = parser.parseOne(
        sms(
          sender: 'AD-SBIINB',
          body:
              'Dear UPI user A/C X3456 debited by 1250.0 on date 05Jan25 trf '
              'to GROCERY STORE Refno 501234567890 -SBI',
        ),
        scanBatchId: 'scan-25',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.direction, TransactionDirection.debit);
      expect(txn.amountPaise, 125000);
      expect(txn.accountLast4, '3456');
      expect(txn.refNumber, '501234567890');
    });

    test('a date and a reference number are never read as an amount', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'AD-SBIINB',
            body:
                'Dear UPI user A/C X3456 debited on date 05Jan25 trf to '
                'GROCERY STORE Refno 501234567890 -SBI',
          ),
          scanBatchId: 'scan-26',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('a bare number with no verb beside it is not an amount', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'VM-HDFCBK',
            body:
                'HDFC Bank: A/c XX1234 debited. Your reward points balance is '
                '1250.0 as on date. Ref 501234567890',
          ),
          scanBatchId: 'scan-27',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });
  });

  group('merchant, instrument and balance are read precisely', () {
    ParsedTxn parse(String body, {String sender = 'VM-HDFCBK'}) =>
        parser.parseOne(
          sms(sender: sender, body: body),
          scanBatchId: 'scan-28',
          bodyHashSalt: 'test-salt',
        )!;

    test('the merchant is the merchant, not the rest of the sentence', () {
      final txn = parse(
        'Spent Rs.3,200.00 on HDFC Bank Card XX9012 at AMAZON on 26-06-25. '
        'Available Limit Rs.46,800.00. Not you? Call 18002586161.',
      );

      expect(txn.merchant, 'amazon');
    });

    test('merchant capture stops at a date, a reference and a balance', () {
      expect(
        parse('Rs.900.00 debited from A/c XX1234 at BOOKSTORE on 26-06-25.').merchant,
        'bookstore',
      );
      expect(
        parse('Rs.900.00 debited from A/c XX1234 at BOOKSTORE Ref 123456789012').merchant,
        'bookstore',
      );
      expect(
        parse('Rs.900.00 debited from A/c XX1234 at BOOKSTORE. Avl Bal Rs.9,000.00.').merchant,
        'bookstore',
      );
    });

    // HDFC's UPI debit — the highest-volume alert format in the corpus —
    // introduces the payee with `To` on its own line and carries no VPA at all.
    // Bodies are the real device shape (see TASK-29).
    const hdfcUpi = 'Sent Rs.245.00\n'
        'From HDFC Bank A/C x1234\n'
        'To ACME DIGITAL PRIVATE LIMI\n'
        'On 01/08/26\n'
        'Ref 561234567890\n'
        'Not You? Call 18002586161/SMS BLOCK UPI to 7000000000';

    test('the UPI payee on the To line becomes the merchant', () {
      expect(parse(hdfcUpi).merchant, 'acme digital private limi');
    });

    test('a short To payee is captured whole', () {
      expect(
        parse(hdfcUpi.replaceAll('ACME DIGITAL PRIVATE LIMI', 'CRED Club')).merchant,
        'cred club',
      );
    });

    test('the From account never becomes the merchant', () {
      // The guard that stops a careless `to|from` alternation capturing the
      // user's own account as the payee.
      final merchant = parse(hdfcUpi).merchant;
      expect(merchant, isNot(contains('hdfc')));
      expect(merchant, isNot(contains('a/c')));
    });

    test('the helpline number in a Not-you tail is never the merchant', () {
      // Real Axis card body: no `at` and no `To PAYEE` line, but the footer
      // reads "SMS BLOCK ... to 919000000000". A phone number is not a payee.
      final merchant = parse(
        'Spent Rs.245.00\n'
        'Axis Bank Card no. XX1234\n'
        '10-05-26 12:08:47 IST\n'
        'BLINKIT\n'
        'Avl Limit: Rs.50000\n'
        'Not you? SMS BLOCK 1234 to 919000000000',
      ).merchant;

      expect(merchant, isNot('919000000000'));
    });

    test('a bare digit run is never captured as a payee name', () {
      expect(
        parse('Sent Rs.500.00\nFrom HDFC Bank A/C x1234\nTo 919876543210\n'
                'On 01/08/26\nRef 561234567890')
            .merchant,
        isNot('919876543210'),
      );
    });

    test('an at-introduced merchant still wins over a To elsewhere', () {
      expect(
        parse('Rs.900.00 debited from A/c XX1234 at BOOKSTORE on 26-06-25.').merchant,
        'bookstore',
      );
    });

    test('a bank-card purchase is a card, not a bank debit', () {
      final txn = parse(
        'Spent Rs.3,200.00 on HDFC Bank Card XX9012 at AMAZON on 26-06-25. '
        'Available Limit Rs.46,800.00. Not you? Call 18002586161.',
      );

      expect(txn.instrument, PaymentInstrument.card);
    });

    test('an available limit alone is enough to classify as a card', () {
      final txn = parse(
        'HDFC Bank: Rs.2,500.00 spent at BOOKSTORE on 26-06-25. '
        'Available Limit Rs.10,000.00.',
      );

      expect(txn.instrument, PaymentInstrument.card);
    });

    test('a bank debit with no card wording stays a bank debit', () {
      final txn = parse(
        'HDFC Bank: Rs.750.00 debited from A/c XX1234 at BOOKSTORE. '
        'Avl Bal Rs.9,000.00.',
      );

      expect(txn.instrument, PaymentInstrument.bank);
    });

    test('the real Axis debit format parses cleanly, not into review', () {
      final txn = parse(
        'Axis Bank Acct XX7788 debited with INR 2750.00 on 28-06-25. '
        'Info- UPI/P2A/RAHUL. Avl Bal- INR 41000.00',
        sender: 'VK-AXISBK',
      );

      expect(txn.amountPaise, 275000);
      expect(txn.balancePaise, 4100000);
      expect(txn.direction, TransactionDirection.debit);
      expect(txn.reviewReason, isNot(ReviewReason.parserUncertain));
      expect(txn.reviewStatus, ReviewStatus.autoAdded);
    });

    test('Avl Bal followed by a space, a colon or a dash is always a balance', () {
      for (final form in const [
        'Avl Bal Rs.9,000.00',
        'Avl Bal: Rs.9,000.00',
        'Avl Bal- Rs.9,000.00',
      ]) {
        final txn = parse(
          'HDFC Bank: Rs.750.00 debited from A/c XX1234. $form.',
        );

        expect(txn.amountPaise, 75000, reason: form);
        expect(txn.balancePaise, 900000, reason: form);
        expect(txn.reviewReason, isNot(ReviewReason.parserUncertain), reason: form);
      }
    });
  });

  group('patterns match tokens, not stray substrings', () {
    ParsedTxn parse(String body, {String sender = 'VM-HDFCBK'}) =>
        parser.parseOne(
          sms(sender: sender, body: body),
          scanBatchId: 'scan-11',
          bodyHashSalt: 'test-salt',
        )!;

    // M1 — a handle missing from _upiHandles costs the row its VPA, and with it
    // the merchant name, the payee type and the UPI classification.
    for (final vpa in const [
      'samplepayee@okaxis',
      'amazonpayin@apl',
      'someone@yapl',
      'someone@axisbank',
      'someone@icici',
      'someone@hdfcbank',
      'someone@sbi',
    ]) {
      test('the $vpa handle is recognised as a UPI payee', () {
        final txn = parse('Rs.450.00 debited from A/c XX1234 to $vpa. Ref 123456789012.');

        expect(txn.upiVpaNorm, vpa, reason: vpa);
        expect(txn.type, TxnType.upi, reason: vpa);
      });
    }

    // M2 — regression guard. Already handled; `no` must not be swallowed into
    // the captured reference.
    test('a spaced or joined reference keyword yields digits only', () {
      expect(
        parse('Rs.450.00 debited from A/c XX1234. UPI Ref no 123456789012.').refNumber,
        '123456789012',
      );
      expect(
        parse('Rs.450.00 debited from A/c XX1234. Refno 123456789012.').refNumber,
        '123456789012',
      );
    });

    // M3 — without a word boundary, the `hrs.` in "within 24 hrs." supplies the
    // `rs.` of a currency token and the following number is read as money.
    test('the "rs" inside "hrs." is not a currency token', () {
      final txn = parse(
        'Valid for 24 hrs. 5000 bonus points await. '
        'Rs.450.00 debited from A/c XX1234 on 05-07-26.',
      );

      expect(txn.amountPaise, 45000);
    });

    // M5 — `contains` against the whole body lets a merchant name decide the
    // transaction type.
    test('a merchant containing "atm" is not an ATM withdrawal', () {
      final txn = parse(
        'Rs.450.00 debited from A/c XX1234 at ATMOSPHERE CAFE on 05-07-26.',
      );

      expect(txn.type, isNot(TxnType.atm));
    });

    test('a merchant containing "upi" is not a UPI transfer', () {
      final txn = parse(
        'Spent Rs.499.00 on HDFC Bank Card XX9012 at UPIWALA STORE on 05-07-26.',
      );

      expect(txn.type, isNot(TxnType.upi));
      expect(txn.instrument, PaymentInstrument.card);
    });

    test('a real VPA still classifies as UPI', () {
      expect(
        parse('Rs.450.00 debited from A/c XX1234 to swiggy@okhdfcbank. Ref 123456789012.').type,
        TxnType.upi,
      );
    });
  });
}
