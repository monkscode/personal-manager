import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// TASK-44. Every body here is the real shape measured on the author's device
/// on 2026-08-05, reproduced with the amounts un-redacted where the parser
/// needs to read them.
///
/// Two bank *announcements* were stored as completed transactions because the
/// shared notice vocabulary did not contain the words these two banks use:
/// ICICI's standing instruction ("to be debited", 8 rows / ₹4,081.10) and
/// HDFC's NACH mandate registration ("received today for processing", 2 rows /
/// ₹2,22,830, both booked as *income*).
const parser = SmsTransactionParser();

/// Row 19 on the device — an ICICI standing instruction, four of whose eight
/// siblings are followed by the real card debit two to three days later.
const _iciciStandingInstruction =
    'Payment of Rs 399.00 towards Merchant Amazon to be debited from '
    'ICICI Bank Credit Card 7117, as per Standing Instruction registered '
    'by you.';

/// Row 1166 on the device — a NACH mandate *registration*. Nothing moved, and
/// the amount is the mandate ceiling: Rs.1,22,830 is exactly 2 x the Rs.61,415
/// HDFC EMI of TASK-43.
const _nachRegistration =
    'Auto Pay (HDFC Bank NACH Mandate): Rs.122830.00 UMRN:HDFC7020308251001350 '
    'To:HDFC LTD Freq MNTH received today for processing.';

/// Row 673 — the real card debit that follows the standing instruction.
const _realCardDebit =
    'Rs 399.00 spent using ICICI Bank Card XX7117 on 26-Jun-26 on AMAZON '
    'INDIA CY. Avl Limit: Rs 150000.00.';

RawSms sms({
  required String sender,
  required String body,
  String? providerId,
  DateTime? receivedAt,
}) => RawSms(
  providerId: providerId,
  sender: sender,
  body: body,
  receivedAt: receivedAt ?? DateTime(2026, 6, 24, 10),
);

ParsedTxn stored({
  required String smsId,
  required String body,
  required TransactionDirection direction,
  int amountPaise = 39900,
  ReviewStatus reviewStatus = ReviewStatus.autoAdded,
  DateTime? date,
}) => ParsedTxn(
  smsId: smsId,
  sender: 'JD-ICICIT-T',
  direction: direction,
  instrument: PaymentInstrument.bank,
  type: TxnType.pos,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 8, 5),
  merchant: 'card purchase',
  payeeType: PayeeType.unknown,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: reviewStatus,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: body,
  bodyHash: 'h:${body.hashCode}',
  scanBatchId: 'b',
);

SmsAnalysisSnapshot reduceOf(List<ParsedTxn> history) =>
    SmsAnalysisSnapshot.reduce(
      history: history,
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: DateTime(2026, 8, 5, 12),
    );

void main() {
  group('an announcement is never a completed transaction', () {
    test('an ICICI standing-instruction notice produces no transaction', () {
      expect(
        parser.parseOne(
          sms(sender: 'JD-ICICIT-T', body: _iciciStandingInstruction),
          scanBatchId: 'scan-44a',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('a NACH mandate registration produces no transaction', () {
      expect(
        parser.parseOne(
          sms(
            sender: 'AD-HDFCBK-S',
            receivedAt: DateTime(2025, 8, 2, 9),
            body: _nachRegistration,
          ),
          scanBatchId: 'scan-44b',
          bodyHashSalt: 'test-salt',
        ),
        isNull,
      );
    });

    test('a registration is not routed to an obligation either', () {
      // It names no dated debit and its amount is a ceiling, so unlike a
      // pre-notice there is nothing to own. `_parseNotice` requires a debit
      // direction and this body reads as a credit, so both halves return null.
      final result = parser.parse(
        sms(
          sender: 'AD-HDFCBK-S',
          receivedAt: DateTime(2025, 8, 2, 9),
          body: _nachRegistration,
        ),
        scanBatchId: 'scan-44c',
        bodyHashSalt: 'test-salt',
      );

      expect(result.txn, isNull);
      expect(result.notice, isNull);
    });
  });

  group('rows already on disk stop counting at read time', () {
    test('a stored standing-instruction row is an announcement', () {
      expect(
        stored(
          smsId: 'provider:12306',
          body: _iciciStandingInstruction,
          direction: TransactionDirection.debit,
        ).isFutureDebitNotice,
        isTrue,
      );
    });

    test('a stored NACH registration is an announcement', () {
      expect(
        stored(
          smsId: 'provider:11166',
          body: _nachRegistration,
          direction: TransactionDirection.credit,
          amountPaise: 12283000,
        ).isFutureDebitNotice,
        isTrue,
      );
    });

    test('the working set excludes both announcements', () {
      final history = [
        stored(
          smsId: 'provider:12306',
          body: _iciciStandingInstruction,
          direction: TransactionDirection.debit,
        ),
        stored(
          smsId: 'provider:11166',
          body: _nachRegistration,
          direction: TransactionDirection.credit,
          amountPaise: 12283000,
        ),
        stored(
          smsId: 'provider:12673',
          body: _realCardDebit,
          direction: TransactionDirection.debit,
        ),
      ];
      // Guard: the fixture really does carry three rows, so a 1-vs-3 result
      // cannot pass because the fixture was empty.
      expect(history, hasLength(3));

      final snapshot = reduceOf(history);
      expect(snapshot.currentMonthTxns, hasLength(1));
      expect(snapshot.currentMonthTxns.single.smsId, 'provider:12673');
    });

    test('a user-confirmed announcement is excluded without being deleted', () {
      // Four of the eight standing-instruction rows are user-confirmed. They
      // must stop counting while staying on disk — TASK-41's rule.
      final row = stored(
        smsId: 'provider:12306',
        body: _iciciStandingInstruction,
        direction: TransactionDirection.debit,
        reviewStatus: ReviewStatus.confirmed,
      );

      expect(row.isFutureDebitNotice, isTrue);
      expect(reduceOf([row]).currentMonthTxns, isEmpty);
    });
  });

  group('GUARDs: the new words swallow nothing real', () {
    test('the real card debit that follows is still counted', () {
      final txn = parser.parseOne(
        sms(
          sender: 'JD-ICICIT-S',
          receivedAt: DateTime(2026, 6, 26, 11),
          body: _realCardDebit,
        ),
        scanBatchId: 'scan-44d',
        bodyHashSalt: 'test-salt',
      );

      expect(txn, isNotNull);
      expect(txn!.direction, TransactionDirection.debit);
      expect(txn.amountPaise, 39900);
    });

    test('a completed autopay debit is still an actual', () {
      // 38 rows on the device say "AutoPay" in the past tense. Widening the
      // vocabulary must not reach any of them.
      final result = parser.parse(
        sms(
          sender: 'AX-AXISBK-S',
          receivedAt: DateTime(2026, 7, 29, 8),
          body:
              'Rs.120.07 debited from A/c XX1234 towards AutoPay Bharat '
              'Connect PostPaid Bill Payment. Ref 512345678901.',
        ),
        scanBatchId: 'scan-44e',
        bodyHashSalt: 'test-salt',
      );

      expect(result.notice, isNull);
      expect(result.txn, isNotNull);
      expect(result.txn!.amountPaise, 12007);
    });

    test('the six existing phrasings still match', () {
      const bodies = [
        'Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25.',
        'Rs.499.00 will be credited to your A/c XX1234.',
        'Rs.499.00 will be deducted on 04/02/26.',
        'Your bill of Rs.499.00 is due on 05-Jul-25.',
        'Rs.499.00 is due for payment on 01-06-26 towards Axis Bank CC.',
        'A payment of Rs.499.00 is scheduled for 05-Jul-25.',
        'For the upcoming mandate set for 28-07-26, Rs.1999.00 will be debited.',
      ];
      for (final body in bodies) {
        expect(
          kFutureDebitNoticePattern.hasMatch(body),
          isTrue,
          reason: 'no longer recognised: $body',
        );
      }
    });
  });
}
