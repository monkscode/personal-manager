import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/services/email_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const parser = EmailParser();

RawEmail email({
  required String from,
  required String subject,
  required String body,
  DateTime? date,
}) => RawEmail(
  id: from + subject,
  from: from,
  subject: subject,
  body: body,
  date: date ?? DateTime(2026, 1, 20),
);

void main() {
  group('RawEmail helpers', () {
    test('extracts sender domain and display name', () {
      final e = email(
        from: 'LIC of India <no-reply@licindia.com>',
        subject: 's',
        body: 'b',
      );
      expect(e.fromDomain, 'licindia.com');
      expect(e.fromName, 'LIC of India');
    });
  });

  group('known billers', () {
    test('LIC annual premium is fully extracted', () {
      final bill = parser.parseOne(
        email(
          from: 'LIC of India <no-reply@licindia.com>',
          subject: 'Premium payment reminder',
          body:
              'Your LIC policy premium of ₹47,000 is due on 14 Feb 2026. Please pay before the due date.',
        ),
      )!;
      expect(bill.merchant, 'LIC of India');
      expect(bill.amount, 47000);
      expect(bill.categoryKey, 'insurance');
      expect(bill.recurrence, 'annual');
      expect(bill.dueDate, DateTime(2026, 2, 14));
      expect(bill.confidence, greaterThan(0.8));
    });

    test('Netflix monthly subscription', () {
      final bill = parser.parseOne(
        email(
          from: 'Netflix <info@netflix.com>',
          subject: 'Your Netflix bill',
          body: "We'll charge ₹649 to your card on 03 Feb 2026.",
        ),
      )!;
      expect(bill.merchant, 'Netflix');
      expect(bill.amount, 649);
      expect(bill.categoryKey, 'subscriptions');
      expect(bill.recurrence, 'monthly');
    });

    test('electricity bill via sender rule + numeric date (day-first)', () {
      final bill = parser.parseOne(
        email(
          from: 'Tata Power <bills@tatapower.com>',
          subject: 'Electricity bill generated',
          body: 'Amount due ₹2,100. Due date 10/02/2026.',
        ),
      )!;
      expect(bill.merchant, 'Tata Power');
      expect(bill.amount, 2100);
      expect(bill.categoryKey, 'utilities');
      expect(bill.dueDate, DateTime(2026, 2, 10));
    });
  });

  group('inferred (unknown sender)', () {
    test('rent from a personal address infers housing + monthly', () {
      final bill = parser.parseOne(
        email(
          from: 'Landlord <owner@gmail.com>',
          subject: 'House rent for February',
          body: 'Monthly rent ₹18,000 due by 01 Feb 2026.',
          date: DateTime(2026, 1, 25),
        ),
      )!;
      expect(bill.categoryKey, 'housing');
      expect(bill.recurrence, 'monthly');
      expect(bill.amount, 18000);
      expect(bill.dueDate, DateTime(2026, 2, 1));
      expect(bill.merchant, 'Landlord');
    });

    test('loan EMI infers monthly and picks the EMI amount, not a fee', () {
      final bill = parser.parseOne(
        email(
          from: 'HDFC Bank <alerts@hdfcbank.net>',
          subject: 'Loan EMI due',
          body:
              'Convenience fee ₹20. Your loan EMI amount payable is ₹12,500 due on 05/02/2026.',
        ),
      )!;
      expect(bill.amount, 12500);
      expect(bill.recurrence, 'monthly');
      expect(bill.dueDate, DateTime(2026, 2, 5));
    });
  });

  group('gating', () {
    test('promotional mail with an amount but no bill signal is rejected', () {
      final bill = parser.parseOne(
        email(
          from: 'Amazon <deals@amazon.in>',
          subject: 'Mega Sale!',
          body:
              'Pay just ₹999 in our sale! 50% off, cashback offer, use coupon.',
        ),
      );
      expect(bill, isNull);
    });

    test('an email with no amount is rejected even if bill-like', () {
      final bill = parser.parseOne(
        email(
          from: 'Bank <x@bank.com>',
          subject: 'Payment due',
          body: 'Your bill is due soon.',
        ),
      );
      expect(bill, isNull);
    });

    test('known-biller premium receipt is not an upcoming bill', () {
      final bill = parser.parseOne(
        email(
          from: 'Tata AIA <service@tataaia.com>',
          subject: 'Download your Premium Receipt',
          body: 'Your premium payment of ₹40,200 was received on 4 Apr 2021.',
          date: DateTime(2026, 7, 1),
        ),
      );
      expect(bill, isNull);
    });

    test('deposit account statement is not an upcoming bill', () {
      final bill = parser.parseOne(
        email(
          from: 'HDFC Bank <statements@hdfcbank.net>',
          subject: 'Email Account Statement of your HDFC Bank Account',
          body: 'Statement period 26 May 2026 to 25 Jun 2026.',
          date: DateTime(2026, 7, 1),
        ),
      );
      expect(bill, isNull);
    });

    test('mutual-fund portfolio disclosure is not an upcoming bill', () {
      final bill = parser.parseOne(
        email(
          from: 'PGIM India Mutual Fund <service@pgimindiamf.com>',
          subject: 'Monthly Portfolio Disclosure as on June 30, 2026',
          body: 'View the monthly portfolio statement for your investments.',
          date: DateTime(2026, 7, 1),
        ),
      );
      expect(bill, isNull);
    });

    test('observed informational and completed subjects are rejected', () {
      for (final subject in [
        'Payment for Vi Postpaid is successful',
        'CarTrade Tech Limited - Postal Ballot Notice',
        'Intimation regarding credit of Interim Dividend',
        'Protean - Intimation of Contribution Credit',
        'HDFC Bank InstaAlerts',
        'Skip the Wait. Manage Your Home Loan Instantly',
        'Presenting a one-stop destination for all tax-related information',
        'ICICI Bank Limited - 32nd Annual General Meeting',
      ]) {
        final bill = parser.parseOne(
          email(
            from: 'Financial Service <alerts@financial.example>',
            subject: subject,
            body: 'Payment statement amount due ₹1,499 on 11 Feb 2026.',
            date: DateTime(2026, 7, 1),
          ),
        );
        expect(bill, isNull, reason: subject);
      }
    });
  });

  group('H1: amountless high-confidence bills (match the AI path)', () {
    test(
      'high-confidence amountless reminder is kept for review with amount 0',
      () {
        // A known biller + due date + strong "premium/payment reminder" signal,
        // but the figure lives behind a login (common for Indian bill reminders).
        final bill = parser.parseOne(
          email(
            from: 'LIC of India <no-reply@licindia.com>',
            subject: 'Premium payment reminder',
            body:
                'Your LIC policy premium is due on 14 Feb 2026. '
                'Please log in to view and pay before the due date.',
          ),
        );
        expect(bill, isNotNull);
        expect(bill!.amount, 0); // 0 == amount missing, set in review
        expect(bill.merchant, 'LIC of India');
        expect(bill.dueDate, DateTime(2026, 2, 14));
        expect(bill.categoryKey, 'insurance');
      },
    );

    test(
      'utility "Payment Reminder" with a due date but no amount is kept',
      () {
        final bill = parser.parseOne(
          email(
            from: 'City Gas <no-reply@citygas.example>',
            subject: 'Payment Reminder',
            body:
                'Your piped gas bill payment is due on 20 Feb 2026. '
                'Kindly pay to avoid disruption.',
          ),
        );
        expect(bill, isNotNull);
        expect(bill!.amount, 0);
        expect(bill.categoryKey, 'utilities');
        expect(bill.dueDate, DateTime(2026, 2, 20));
      },
    );

    test('low-confidence amountless receipt is rejected', () {
      final bill = parser.parseOne(
        email(
          from: 'Some Service <noreply@randomservice.io>',
          subject: 'Payment received',
          body: 'Thank you, your payment has been received successfully.',
        ),
      );
      expect(bill, isNull);
    });

    test('amountless bill-like email without a strong signal is rejected', () {
      // Passes the general low-confidence gate (has an inferred category) but is
      // still dropped because an amountless bill needs a strong reminder signal.
      final bill = parser.parseOne(
        email(
          from: 'App <noreply@somesaas.com>',
          subject: 'Manage your subscription',
          body: 'You can update your subscription preferences anytime.',
        ),
      );
      expect(bill, isNull);
    });
  });

  group('date handling', () {
    test('missing year on an upcoming due date rolls to next year', () {
      final bill = parser.parseOne(
        email(
          from: 'ACT Fibernet <no-reply@actcorp.in>',
          subject: 'Broadband payment reminder',
          body: 'Your broadband bill ₹1,100 is due 05 Jan.',
          date: DateTime(2025, 12, 20),
        ),
      )!;
      expect(bill.dueDate, DateTime(2026, 1, 5));
    });

    test('historical document dates are not exposed as due dates', () {
      final bill = parser.parseOne(
        email(
          from: 'LIC of India <no-reply@licindia.com>',
          subject: 'Premium reminder',
          body: 'Policy started 4 Apr 2021. Premium amount ₹40,200.',
          date: DateTime(2026, 7, 1),
        ),
      );
      expect(bill, isNotNull);
      expect(bill!.dueDate, isNull);
    });
  });

  group('H2: token-adjacency amount extraction (spec §6)', () {
    test('kAmountMagnitudeWords covers the Indian magnitude multipliers', () {
      expect(
        EmailParser.kAmountMagnitudeWords,
        containsAll(<String>['lakh', 'lakhs', 'crore', 'cr']),
      );
    });

    test(
      'does not grab a magnitude figure from a loan promo ("₹10 Lakhs")',
      () {
        expect(
          parser.extractAmount(
            'Get a personal loan up to ₹10 Lakhs at low interest rates!',
          ),
          isNull,
        );
      },
    );

    test('does not grab "Rs 5 Crore" magnitude figures', () {
      expect(
        parser.extractAmount('Win up to Rs 5 Crore in our mega draw'),
        isNull,
      );
    });

    test('recovers a real payable next to the currency token', () {
      expect(
        parser.extractAmount('Amount payable ₹3,499 by the due date.'),
        3499,
      );
    });

    test(
      'ignores a magnitude promo figure but still recovers the real payable',
      () {
        expect(
          parser.extractAmount(
            'Pre-approved up to ₹10 Lakhs. Your EMI of ₹8,250 is due.',
          ),
          8250,
        );
      },
    );

    test(
      'a bare currency amount with no magnitude word is still extracted',
      () {
        expect(parser.extractAmount('Please pay ₹1,299 now.'), 1299);
      },
    );
  });

  group('parseAll', () {
    test('de-duplicates identical bills and sorts by confidence', () {
      final lic = email(
        from: 'LIC of India <no-reply@licindia.com>',
        subject: 'Premium reminder',
        body: 'Premium ₹47,000 due on 14 Feb 2026.',
      );
      final weak = email(
        from: 'Someone <a@b.com>',
        subject: 'invoice',
        body: 'total amount ₹500',
      );
      final bills = parser.parseAll([lic, lic, weak]);
      expect(bills.length, 2); // two LICs collapse to one
      expect(bills.first.merchant, 'LIC of India'); // highest confidence first
    });
  });
}
