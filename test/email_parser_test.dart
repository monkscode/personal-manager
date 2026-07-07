import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/services/email_parser.dart';
import 'package:flutter_test/flutter_test.dart';

const parser = EmailParser();

RawEmail email({
  required String from,
  required String subject,
  required String body,
  DateTime? date,
}) =>
    RawEmail(id: from + subject, from: from, subject: subject, body: body, date: date ?? DateTime(2026, 1, 20));

void main() {
  group('RawEmail helpers', () {
    test('extracts sender domain and display name', () {
      final e = email(from: 'LIC of India <no-reply@licindia.com>', subject: 's', body: 'b');
      expect(e.fromDomain, 'licindia.com');
      expect(e.fromName, 'LIC of India');
    });
  });

  group('known billers', () {
    test('LIC annual premium is fully extracted', () {
      final bill = parser.parseOne(email(
        from: 'LIC of India <no-reply@licindia.com>',
        subject: 'Premium payment reminder',
        body: 'Your LIC policy premium of ₹47,000 is due on 14 Feb 2026. Please pay before the due date.',
      ))!;
      expect(bill.merchant, 'LIC of India');
      expect(bill.amount, 47000);
      expect(bill.categoryKey, 'insurance');
      expect(bill.recurrence, 'annual');
      expect(bill.dueDate, DateTime(2026, 2, 14));
      expect(bill.confidence, greaterThan(0.8));
    });

    test('Netflix monthly subscription', () {
      final bill = parser.parseOne(email(
        from: 'Netflix <info@netflix.com>',
        subject: 'Your Netflix bill',
        body: "We'll charge ₹649 to your card on 03 Feb 2026.",
      ))!;
      expect(bill.merchant, 'Netflix');
      expect(bill.amount, 649);
      expect(bill.categoryKey, 'subscriptions');
      expect(bill.recurrence, 'monthly');
    });

    test('electricity bill via sender rule + numeric date (day-first)', () {
      final bill = parser.parseOne(email(
        from: 'Tata Power <bills@tatapower.com>',
        subject: 'Electricity bill generated',
        body: 'Amount due ₹2,100. Due date 10/02/2026.',
      ))!;
      expect(bill.merchant, 'Tata Power');
      expect(bill.amount, 2100);
      expect(bill.categoryKey, 'utilities');
      expect(bill.dueDate, DateTime(2026, 2, 10));
    });
  });

  group('inferred (unknown sender)', () {
    test('rent from a personal address infers housing + monthly', () {
      final bill = parser.parseOne(email(
        from: 'Landlord <owner@gmail.com>',
        subject: 'House rent for February',
        body: 'Monthly rent ₹18,000 due by 01 Feb 2026.',
        date: DateTime(2026, 1, 25),
      ))!;
      expect(bill.categoryKey, 'housing');
      expect(bill.recurrence, 'monthly');
      expect(bill.amount, 18000);
      expect(bill.dueDate, DateTime(2026, 2, 1));
      expect(bill.merchant, 'Landlord');
    });

    test('loan EMI infers monthly and picks the EMI amount, not a fee', () {
      final bill = parser.parseOne(email(
        from: 'HDFC Bank <alerts@hdfcbank.net>',
        subject: 'Loan EMI due',
        body: 'Convenience fee ₹20. Your loan EMI amount payable is ₹12,500 due on 05/02/2026.',
      ))!;
      expect(bill.amount, 12500);
      expect(bill.recurrence, 'monthly');
      expect(bill.dueDate, DateTime(2026, 2, 5));
    });
  });

  group('gating', () {
    test('promotional mail with an amount but no bill signal is rejected', () {
      final bill = parser.parseOne(email(
        from: 'Amazon <deals@amazon.in>',
        subject: 'Mega Sale!',
        body: 'Pay just ₹999 in our sale! 50% off, cashback offer, use coupon.',
      ));
      expect(bill, isNull);
    });

    test('an email with no amount is rejected even if bill-like', () {
      final bill = parser.parseOne(email(
        from: 'Bank <x@bank.com>',
        subject: 'Payment due',
        body: 'Your bill is due soon.',
      ));
      expect(bill, isNull);
    });
  });

  group('date handling', () {
    test('missing year on an upcoming due date rolls to next year', () {
      final bill = parser.parseOne(email(
        from: 'ACT Fibernet <no-reply@actcorp.in>',
        subject: 'Broadband payment reminder',
        body: 'Your broadband bill ₹1,100 is due 05 Jan.',
        date: DateTime(2025, 12, 20),
      ))!;
      expect(bill.dueDate, DateTime(2026, 1, 5));
    });
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
