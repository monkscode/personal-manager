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
}
