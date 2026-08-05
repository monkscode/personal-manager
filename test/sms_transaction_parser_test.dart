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

    // Superseded by TASK-32. This pre-notice used to be stored as a debit dated
    // at the announced day, on the theory that the real debit would later fold
    // into it. On the device that theory failed — 30 notices sat alongside 30
    // real debits — so a notice is no longer an actual at all.
    test('an autopay pre-notice is a dated notice, not a transaction', () {
      final result = parser.parse(
        sms(
          sender: 'VM-HDFCBK',
          receivedAt: DateTime(2025, 7, 2, 10),
          body:
              'Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25 for '
              'NETFLIX UPI Autopay. Ref 512345678901.',
        ),
        scanBatchId: 'scan-17',
        bodyHashSalt: 'test-salt',
      );

      expect(result.txn, isNull);
      expect(result.notice!.dueDate, DateTime(2025, 7, 5));
      expect(result.notice!.payee, 'netflix');
      expect(result.notice!.amountPaise, 49900);
      expect(result.notice!.accountLast4, '1234');
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
      final notices = <FutureDebitNotice>[];
      for (final message in messages) {
        final result = parser.parse(
          message,
          scanBatchId: 'autopay',
          bodyHashSalt: 'test-salt',
        );
        if (result.notice != null) notices.add(result.notice!);
        final parsed = result.txn;
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

      // One rupee, one owner: the announcement is an obligation signal and the
      // debit alert is the actual. Only the latter is a stored transaction.
      expect(stored, hasLength(1));
      expect(stored.single.amountPaise, 49900);
      expect(stored.single.txnLocalDate, '2025-07-05');
      expect(notices, hasLength(1));
      expect(notices.single.amountPaise, 49900);
    });
  });

  // Bodies below are the real Axis/HDFC shapes measured on the author's device
  // on 2026-08-03 (TASK-32), reproduced with the amounts un-redacted.
  group('a future-tense notice is never a completed debit', () {
    test('an upcoming-mandate notice produces no transaction', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'AX-AXISBK-S',
            receivedAt: DateTime(2026, 7, 26, 9),
            body:
                'For the upcoming mandate set for 28-07-26, Rs.1999.00 will be '
                'debited from your A/c towards Google for GOOGLE, 512345678901. '
                'To stop execution, pause mandate - Axis Bank',
          ),
          scanBatchId: 'scan-32a',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('it surfaces instead as a dated notice carrying payee and due date', () {
      final notice = parser
          .parse(
            sms(
              sender: 'AX-AXISBK-S',
              receivedAt: DateTime(2026, 7, 26, 9),
              body:
                  'For the upcoming mandate set for 28-07-26, Rs.1999.00 will '
                  'be debited from your A/c towards Google for GOOGLE, '
                  '512345678901. To stop execution, pause mandate - Axis Bank',
            ),
            scanBatchId: 'scan-32b',
            bodyHashSalt: 'test-salt',
          )
          .notice!;

      expect(notice.payee, 'google');
      expect(notice.amountPaise, 199900);
      expect(notice.dueDate, DateTime(2026, 7, 28));
    });

    // GUARD, not regression coverage: this passes with or without the tense
    // check, because a past-tense body carries no future marker. It is here to
    // fail loudly if the future-notice vocabulary is ever widened far enough to
    // swallow the real NACH debit — the 20 `UMRN:` rows of TASK-31 format 2.
    test('GUARD: a past-tense NACH debit is still an actual', () {
      final result = parser.parse(
        sms(
          sender: 'JX-HDFCBK-S',
          receivedAt: DateTime(2026, 7, 5, 8),
          body:
              'PAYMENT ALERT!\nRs.4500.00 deducted from HDFC Bank A/c XX1234 '
              'towards Indian Clearing Corporation Lt UMRN: HDFC7020308251001350',
        ),
        scanBatchId: 'scan-32c',
        bodyHashSalt: 'test-salt',
      );

      expect(result.notice, isNull);
      expect(result.txn!.direction, TransactionDirection.debit);
      expect(result.txn!.amountPaise, 450000);
      expect(result.txn!.txnLocalDate, '2026-07-05');
    });
  });

  // TASK-31. Every body here is the real shape measured on the author's device
  // on 2026-08-03, un-redacted. Together these six formats carried 56 of the 79
  // rows stored with no merchant at all.
  group('payees the parser used to leave on the floor', () {
    String? merchantOf(String body, {String sender = 'VM-HDFCBK-S'}) => parser
        .parseOne(
          sms(sender: sender, body: body),
          scanBatchId: 'scan-31',
          bodyHashSalt: 'test-salt',
        )
        ?.merchant;

    test('format 1: HDFC ACH D- names the originator', () {
      expect(
        merchantOf(
          'UPDATE: Rs.5000.00 debited from HDFC Bank A/c XX1234 on 05-JUL-26. '
          'Info: ACH D- GROWW INVEST TECH PR-HK7R5VFDNFHO. Avl bal:Rs.20000.00',
        ),
        'groww invest tech pr',
      );
    });

    test('format 2: HDFC PAYMENT ALERT names the payee before UMRN', () {
      expect(
        merchantOf(
          'PAYMENT ALERT!\nRs.4500.00 deducted from HDFC Bank A/c XX1234 '
          'towards HDFC LTD UMRN: HDFC7020208251013841',
        ),
        'hdfc ltd',
      );
    });

    test('format 3: the Axis UPI line names the payee after the ref', () {
      expect(
        merchantOf(
          sender: 'JD-AXISBK-S',
          'Rs.500.00 debited\nA/c no. XX7111\n01-12-25, 10:58:24\n'
          'UPI/P2M/568843434007/CHEQ DIGITAL PRIVAT\n'
          'Not you? SMS BLOCKUPI Cust ID to 919951860002\nAxis Bank',
        ),
        'cheq digital privat',
      );
    });

    test('format 3: a P2A payee stops at the next slash, not the line end', () {
      expect(
        merchantOf(
          sender: 'CP-AXISBK-S',
          'Rs.2500.00 credited\nA/c no. XX7111\n13-01-26, 14:49:18 IST\n'
          'UPI/P2A/154680721130/DHRUVIL U/HDFC/For - Axis Bank',
        ),
        'dhruvil u',
      );
    });

    test('format 4: the Axis card line names the merchant after the time', () {
      expect(
        merchantOf(
          sender: 'AX-AXISBK-S',
          'Spent Rs.5191.00\nAxis Bank Card no. XX7111\n07-12-25 19:31:06 IST\n'
          'Google\nAvl Limit: Rs.44809.00\n'
          'Not you? SMS BLOCK 7111 to 919951860002',
        ),
        'google',
      );
    });

    test('format 5: the HDFC ATM withdrawal names the location', () {
      expect(
        merchantOf(
          sender: 'AD-HDFCBK-S',
          'Withdrawn Rs.20000.00 From HDFC Bank Card x7102 At SCIENCE CITY-II '
          'On 2025-12-07:14:18:33 Bal Rs.15000.00 Not You? Call 18002586161',
        ),
        'science city-ii',
      );
    });

    test('format 6: the Kotak biller confirmation names the biller', () {
      expect(
        merchantOf(
          sender: 'CP-ATGLTD-S',
          'Dear Customer,Payment of Rs.1020.50 with Ref 123456 is received for '
          'Customer ID 1000023412 by K from Kotak - Adani Total Gas',
        ),
        'adani total gas',
      );
    });

    // The bank-as-payee decision this task called for. A clearing house or the
    // bank itself is a real originator and must keep its owner key, but it is
    // not a merchant and must not be shown as one.
    test('a clearing-house originator is typed as a bank mandate', () {
      final txn = parser.parseOne(
        sms(
          sender: 'JX-HDFCBK-S',
          body:
              'PAYMENT ALERT!\nRs.4500.00 deducted from HDFC Bank A/c XX1234 '
              'towards Indian Clearing Corporation Lt UMRN: HDFC70203082510',
        ),
        scanBatchId: 'scan-31b',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.merchant, 'indian clearing corporation lt');
      expect(txn.payeeType, PayeeType.bankMandate);
    });

    test('the bank itself as ACH originator is a bank mandate too', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK-S',
          body:
              'UPDATE: Rs.5000.00 debited from HDFC Bank A/c XX1234 on '
              '05-JUL-26. Info: ACH D- HDFC BANK LTD-468262824. '
              'Avl bal:Rs.20000.00',
        ),
        scanBatchId: 'scan-31c',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.merchant, 'hdfc bank ltd');
      expect(txn.payeeType, PayeeType.bankMandate);
    });

    test('a named commercial originator stays a merchant', () {
      final txn = parser.parseOne(
        sms(
          sender: 'VM-HDFCBK-S',
          body:
              'UPDATE: Rs.5000.00 debited from HDFC Bank A/c XX1234 on '
              '05-JUL-26. Info: ACH D- GROWW INVEST TECH PR-HK7R5VFDNFHO. '
              'Avl bal:Rs.20000.00',
        ),
        scanBatchId: 'scan-31d',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.payeeType, PayeeType.merchant);
    });

    // HDFC Ltd is the housing-finance lender, not HDFC Bank. It is a genuine
    // EMI payee and must not be swept up with the clearing houses.
    test('a lender whose name ends in Ltd is not a bank mandate', () {
      final txn = parser.parseOne(
        sms(
          sender: 'JM-HDFCBK-S',
          body:
              'PAYMENT ALERT!\nRs.4500.00 deducted from HDFC Bank A/c XX1234 '
              'towards HDFC LTD UMRN: HDFC7020208251013841',
        ),
        scanBatchId: 'scan-31e',
        bodyHashSalt: 'test-salt',
      )!;

      expect(txn.merchant, 'hdfc ltd');
      expect(txn.payeeType, PayeeType.merchant);
    });

    test('an explicit towards-payee beats an opaque UPI handle', () {
      expect(
        merchantOf(
          sender: 'VA-AXISBK-S',
          'Your A/c has been debited towards Google for Rs.1999.00 on '
          '28-07-26. xfkxfma537eoyvuzwkvss3vbvbr1oxoo@okaxis - Axis Bank',
        ),
        'google',
      );
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

  group('TASK-36 — an opaque handle never stands in for a named payee', () {
    ParsedTxn parse(String body, {String sender = 'AD-AXISBK-S'}) =>
        parser.parseOne(
          sms(sender: sender, body: body),
          scanBatchId: 'scan-36',
          bodyHashSalt: 'test-salt',
        )!;

    // Verbatim from the device (2,061 rows, 2026-08-04), with the redaction
    // tokens substituted back. 22 stored rows carry this shape.
    const bharatConnect =
        'Your A/c has been debited towards AutoPay  Bharat Connect PostPaid '
        'Bill Payment for Rs.120.07 on 29-07-26. '
        'ece9ae70c53842d58abf92660f4698af@ybl - Axis Bank';

    // The same sentence with a short payee. This one already parses correctly,
    // which is what localises the defect to the length of the name.
    const google =
        'Your A/c has been debited towards Google for Rs.1999.00 on 28-07-26. '
        'xfkxfma537eoyvuzwkvss3vbvbr1oxoo@apl - Axis Bank';

    test('a short named payee is read from the body (guard)', () {
      // Guard: this passed before the fix. It is the control that proves the
      // failure below is about the payee's length and nothing else.
      expect(parse(google).merchant, 'google');
    });

    test('a long named payee is read from the body too', () {
      expect(parse(bharatConnect).merchant, isNot(startsWith('ece9ae70')));
    });

    test('and it normalises to the name the obligation is already stored '
        'under', () {
      // `_tidyPayee` collapses the double space and strips the leading
      // `AutoPay`, landing on the exact `merchant_norm` of obligation #4 on
      // the device. Anything else would create a second obligation for a
      // commitment that already has one.
      expect(
        parse(bharatConnect).merchant,
        'bharat connect postpaid bill payment',
      );
    });

    test('the VPA is still captured even when the payee is named (guard)', () {
      // The handle keeps its own column; the fix moves it out of `merchant`,
      // it does not discard it.
      expect(
        parse(bharatConnect).upiVpaNorm,
        'ece9ae70c53842d58abf92660f4698af@ybl',
      );
    });

    // The device also holds 7 rows whose merchant is
    // `77d1cc47c9de4e9c8e351a8077d60879`, taken from a UMN — a mandate
    // reference, not a payee handle at all.
    const eMandate =
        'E-Mandate!\n'
        'Rs.118.00 will be deducted on 03/08/26, 00:00:00\n'
        'For AutoPay  Bharat Connect PostPaid Bill Payment mandate\n'
        'UMN 77d1cc47c9de4e9c8e351a8077d60879@ybl\n'
        'Maintain Balance\n'
        '-HDFC Bank';

    test('a UMN mandate notice is a notice, not a completed debit (guard)', () {
      final result = parser.parse(
        sms(sender: 'VM-HDFCBK', body: eMandate),
        scanBatchId: 'scan-36',
        bodyHashSalt: 'test-salt',
      );

      expect(result.txn, isNull);
      expect(result.notice, isNotNull);
    });

    // Found on the device 2026-08-04, rendered as a "Drivers" row reading
    // `autopay  bharat connec`. HDFC truncates the payee in the body itself;
    // the double space and the `AutoPay` prefix are ours.
    const upiMandate =
        'UPI Mandate:\n'
        'Sent Rs.118.00\n'
        'from HDFC Bank A/c XX1234\n'
        'To AutoPay  Bharat Connec\n'
        '03/08/26\n'
        'Ref 123456789012\n'
        'Not You? Call 9812345678/SMS BLOCK UPI to 9812345678';

    test('the `To <payee>` fallback tidies the name it captures', () {
      // `_namedPayee` runs every capture through `_tidyPayee`, but the `at`
      // and `to` fallbacks below it only `.trim()`. So this body kept its
      // boilerplate prefix and its double space, minting a fourth spelling of
      // a commitment that already has three.
      expect(parse(upiMandate, sender: 'VM-HDFCBK').merchant, 'bharat connec');
    });

    test('and it names the payee, not the UMN (guard)', () {
      // Guard: the notice path already reads `for <payee> mandate` at a
      // 60-character cap, so this passed before the fix. It is recorded
      // because the device holds 7 rows that contradict it — those rows are
      // stale storage from before TASK-32, not a live parser defect. See
      // TASK-37.
      final notice = parser
          .parse(
            sms(sender: 'VM-HDFCBK', body: eMandate),
            scanBatchId: 'scan-36',
            bodyHashSalt: 'test-salt',
          )
          .notice!;

      expect(notice.payee, 'bharat connect postpaid bill payment');
    });
  });

  // TASK-45. Four capture shapes, each taken verbatim (redacted) from the
  // device, each returning something that is not a payee. All four funnel
  // through `_tidyPayee`, which is where the rule belongs.
  group('TASK-45 — a payee capture stops at the payee', () {
    ParsedTxn parse(String sender, String body) => parser.parseOne(
      sms(sender: sender, body: body),
      scanBatchId: 'scan-45',
      bodyHashSalt: 'test-salt',
    )!;

    // A — ICICI writes the whole message on one line, so a capture bounded
    // only by the line end swallows the footer. 77 device rows store a
    // merchant longer than 40 characters this way.
    test('an ICICI single-line UPI body stops at the sentence end', () {
      final txn = parse(
        'VM-ICICIB',
        'Hello! Your A/c no. XX1234 has been debited by Rs 500.00 on 16Nov18. '
            'The A/c balance is Rs 10,000.00.Info: UPI/P2A/016501509718/'
            'AKSHAT AMRISHBHAI D. Call 18605005555 (if in India) if you have '
            'not done this transaction.',
      );

      expect(txn.merchant, 'akshat amrishbhai d');
    });

    // B — a payment towards the user's own card has no external payee. The
    // terminator fires correctly and the capture is still wrong.
    test('a payment towards your own credit card names no payee', () {
      final txn = parse(
        'VM-ICICIB',
        'Dear Customer, Payment of Rs 5,000.00 has been received towards your '
            'ICICI Bank Credit Card XX7117 on 17-JUN-24 through UPI. Thank you.',
      );

      expect(txn.merchant, isNot(contains('7117')));
      expect(txn.merchant, anyOf(isNull, isNot(contains('credit card'))));
    });

    test('the Axis wording of the same confirmation also names no payee', () {
      final txn = parse(
        'VM-AXISBK',
        'Dear Customer, payment of Rs 2,000.00 towards your Axis Bank Credit '
            'Card XXXX7114 has been received on 09-NOV-23. Thank You.',
      );

      expect(txn.merchant, isNot(contains('7114')));
      expect(txn.merchant, isNot(contains('has been received')));
    });

    // C — the rail prefix and the transaction reference are not the payee.
    test('an ECS rail string keeps the biller and drops the reference', () {
      final txn = parse(
        'VM-AXISBK',
        'Rs 1,200.00 debited from A/c no. XX7103 on 28-10-21 14:15:16 IST at '
            'ECS/RAZORPAY SOFTW/111120218042703. Avl Bal- Rs 5,000.00. '
            'Call 18001030 if not done by you - Axis Bank',
      );

      expect(txn.merchant, isNot(contains('111120218042703')));
      expect(txn.merchant, contains('razorpay'));
    });

    // D — the counterparty's account number is an identifier, not a name.
    test('a bare counterparty account number is not a payee', () {
      final txn = parse(
        'VM-HDFCBK',
        'HDFC Bank:Rs 300.00 debited from a/c XX1234 on 07/04/26 to a/c '
            'XXXX7103 (UPI Ref No. 123456789012). Not you? Call on 18004190 '
            'to report',
      );

      expect(txn.merchant, isNot(contains('7103')));
    });

    // The privacy floor, stated as one assertion over all four bodies: a
    // digit the redactor removes from the body may not survive in `merchant`.
    test('no stored merchant carries a masked tail or a long digit run', () {
      final bodies = <String, String>{
        'VM-ICICIB':
            'Dear Customer, Payment of Rs 5,000.00 has been received towards '
            'your ICICI Bank Credit Card XX7117 on 17-JUN-24 through UPI.',
        'VM-AXISBK':
            'Rs 1,200.00 debited from A/c no. XX7103 on 28-10-21 14:15:16 IST '
            'at ECS/RAZORPAY SOFTW/111120218042703. Avl Bal- Rs 5,000.00.',
        'VM-HDFCBK':
            'HDFC Bank:Rs 300.00 debited from a/c XX1234 on 07/04/26 to a/c '
            'XXXX7103 (UPI Ref No. 123456789012). Not you? Call on 18004190',
      };

      for (final entry in bodies.entries) {
        final merchant = parse(entry.key, entry.value).merchant;
        if (merchant == null) continue;
        expect(
          merchant,
          isNot(matches(RegExp(r'\d{4,}'))),
          reason: 'long digit run survived into merchant: "$merchant"',
        );
        expect(
          merchant,
          isNot(matches(RegExp(r'[*x]{1,4}\d{3,}', caseSensitive: false))),
          reason: 'masked tail survived into merchant: "$merchant"',
        );
      }
    });

    // Guards. These payees must survive the new rule unchanged — the fixture
    // proves itself, per Phase 5's lesson.
    test('the Axis multiline rail payee is unchanged', () {
      final txn = parse(
        'VM-AXISBK',
        'Rs 245.00 debited\nA/c no. XX1234\n01-12-25, 10:57:27\n'
            'UPI/P2M/549148394747/ACME DIGITAL PRIVAT\nAxis Bank',
      );

      expect(txn.merchant, 'acme digital privat');
    });

    test('a plain UPI payee is unchanged', () {
      final txn = parse(
        'VM-HDFCBK',
        'HDFC Bank: Rs. 450.00 debited via UPI to swiggy@okhdfcbank. '
            'UPI Ref 123456789012.',
      );

      expect(txn.merchant, 'swiggy');
    });
  });
}
