import 'dart:async';

import 'package:expense_insight/data/parsed_bill.dart';
import 'package:expense_insight/services/gmail_service.dart';
import 'package:flutter_test/flutter_test.dart';

RawEmail email({
  required String from,
  String subject = '',
  String body = '',
  String snippet = '',
  DateTime? date,
}) => RawEmail(
  id: from + subject,
  from: from,
  subject: subject,
  snippet: snippet,
  body: body,
  date: date ?? DateTime(2026, 1, 20),
);

ParsedBill _bill(RawEmail e, {double amount = 0, String category = 'other'}) =>
    ParsedBill(
      sourceId: e.id,
      merchant: e.fromName,
      amount: amount,
      categoryKey: category,
      recurrence: 'monthly',
      confidence: 0.9,
      sourceSubject: e.subject,
      sourceFrom: e.from,
    );

void main() {
  group('isLikelyBillEmail prefilter (D13)', () {
    test('keeps a utility "Payment Reminder"', () {
      final e = email(
        from: 'City Gas <no-reply@citygas.example>',
        subject: 'Payment Reminder',
        body:
            'Your piped gas bill is due on 20 Feb 2026. Kindly pay before the due date.',
      );
      expect(GmailService.isLikelyBillEmail(e), isTrue);
    });

    test('keeps a mobile postpaid "Payment Reminder"', () {
      final e = email(
        from: 'MyOperator <bills@myoperator.example>',
        subject: 'Payment Reminder',
        body:
            'Your mobile postpaid bill payment is due. Pay now to avoid a late fee.',
      );
      expect(GmailService.isLikelyBillEmail(e), isTrue);
    });

    test('keeps a known biller even without an explicit bill keyword', () {
      final e = email(
        from: 'Netflix <info@netflix.com>',
        subject: 'Your membership',
        body: 'Thanks for being a member.',
      );
      expect(GmailService.isLikelyBillEmail(e), isTrue);
    });

    test('does not use broad body footer terms as prefilter signals', () {
      final e = email(
        from: 'AlphaSignal <digest@alphasignal.example>',
        subject: 'Inside the pragmatic AI engineer\'s new secret weapon',
        body:
            'Newsletter footer: manage billing, insurance and statement preferences.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('rejects a job-alert sender', () {
      final e = email(
        from: 'Naukri <alerts@naukri.com>',
        subject: '5 new jobs for you',
        body: 'Apply now to these jobs matching your profile.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('rejects a newsletter sender', () {
      final e = email(
        from: 'Medium Daily Digest <newsletter@medium.com>',
        subject: "Today's highlights",
        body: 'Stories picked for you this week.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('rejects a SIP / mutual-fund confirmation sender', () {
      final e = email(
        from: 'CAMS <noreply@camsonline.com>',
        subject: 'SIP transaction confirmation',
        body: 'Your SIP of Rs 5000 has been processed for folio 12345.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('rejects an unknown sender with no bill signal', () {
      final e = email(
        from: 'Some App <hello@somesaas.example>',
        subject: 'Welcome aboard',
        body: 'Here is how to get started with our product.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('rejects a known-biller premium receipt', () {
      final e = email(
        from: 'Tata AIA <service@tataaia.com>',
        subject: 'Download your Premium Receipt',
        body:
            'Your annual premium payment was received. Receipt amount ₹40,200.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test(
      'rejects a deposit account statement without card payment signals',
      () {
        final e = email(
          from: 'HDFC Bank <statements@hdfcbank.net>',
          subject: 'Email Account Statement of your HDFC Bank Account',
          body: 'Statement period 26 May 2026 to 25 Jun 2026.',
        );
        expect(GmailService.isLikelyBillEmail(e), isFalse);
      },
    );

    test('rejects a mutual-fund portfolio disclosure', () {
      final e = email(
        from: 'PGIM India Mutual Fund <service@pgimindiamf.com>',
        subject: 'Monthly Portfolio Disclosure as on June 30, 2026',
        body: 'View the monthly portfolio statement for your investments.',
      );
      expect(GmailService.isLikelyBillEmail(e), isFalse);
    });

    test('keeps a credit-card statement with an amount due', () {
      final e = email(
        from: 'Card Bank <cards@bank.example>',
        subject: 'Your credit card statement is ready',
        body: 'Total amount due ₹12,500. Payment due date 5 Aug 2026.',
      );
      expect(GmailService.isLikelyBillEmail(e), isTrue);
    });

    test('rejects observed informational and completed subjects', () {
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
        final e = email(
          from: 'Financial Service <alerts@financial.example>',
          subject: subject,
          body: 'Payment statement amount due ₹1,499 on 11 Feb 2026.',
        );
        expect(GmailService.isLikelyBillEmail(e), isFalse, reason: subject);
      }
    });

    test('keeps observed upcoming payment notices', () {
      for (final e in [
        email(
          from: 'ICICI Bank <cards@icicibank.com>',
          subject: 'Upcoming payment notification: Standing Instructions',
          body: 'Your credit card will be charged ₹1,499 on 11 Feb 2026.',
        ),
        email(
          from: 'Amazon Pay <reminders@amazon.in>',
          subject: 'Payment Reminder',
          body: 'Amount due ₹181 on 11 Feb 2026.',
        ),
      ]) {
        expect(GmailService.isLikelyBillEmail(e), isTrue, reason: e.subject);
      }
    });
  });

  group('narrowed Gmail search query (D13)', () {
    test('keeps the confirmed core bill terms and the 1-month window', () {
      final q = GmailService.searchQuery;
      for (final term in <String>[
        '"payment reminder"',
        '"amount due"',
        'due',
        'premium',
        'invoice',
        'bill',
        'emi',
        'statement',
      ]) {
        expect(q.contains(term), isTrue, reason: 'query must keep "$term": $q');
      }
      expect(GmailService.kGmailLookbackMonths, 1);
      expect(q.contains('newer_than:1m'), isTrue);
      expect(q.contains('newer_than:6m'), isFalse);
    });

    test('drops the noisiest broad terms', () {
      final q = GmailService.searchQuery;
      expect(q.contains('subscription'), isFalse);
      expect(q.contains('recharge'), isFalse);
      // "payment" only ever appears inside the quoted "payment reminder" phrase.
      expect(RegExp(r'payment(?! reminder)').hasMatch(q), isFalse);
    });
  });

  group('scan pipeline prefilters before the AI call', () {
    test('AI is not called for prefiltered-out emails', () async {
      final service = GmailService();
      final calls = <List<RawEmail>>[];
      Future<List<ParsedBill>> fakeAi(List<RawEmail> emails) async {
        calls.add(emails);
        return emails.map((e) => _bill(e)).toList();
      }

      final bill = email(
        from: 'City Gas <no-reply@citygas.example>',
        subject: 'Payment Reminder',
        body: 'Your gas bill is due on 20 Feb 2026. Please pay.',
      );
      final noise = email(
        from: 'Naukri <alerts@naukri.com>',
        subject: '5 new jobs',
        body: 'apply now',
      );

      await service.extractCandidates([bill, noise], aiExtract: fakeAi);

      expect(calls.length, 1);
      expect(calls.single.map((e) => e.id).toList(), [bill.id]);
    });

    test('recovered amount flows into the candidate (H2 backstop)', () async {
      final service = GmailService();
      Future<List<ParsedBill>> fakeAi(List<RawEmail> emails) async =>
          emails.map((e) => _bill(e, category: 'utilities')).toList();

      final bill = email(
        from: 'City Gas <no-reply@citygas.example>',
        subject: 'Payment Reminder',
        body: 'Your gas bill amount payable is \u20B91,450 due on 20 Feb 2026.',
      );

      final out = await service.extractCandidates([bill], aiExtract: fakeAi);
      expect(out.single.amount, 1450);
    });

    test(
      'falls back to on-device rules when the AI throws, still prefiltered',
      () async {
        final service = GmailService();
        var fallbackMessage = '';
        Future<List<ParsedBill>> throwingAi(List<RawEmail> emails) async =>
            throw StateError('boom');

        final bill = email(
          from: 'Tata Power <bills@tatapower.com>',
          subject: 'Electricity bill generated',
          body: 'Amount due \u20B92,100. Due date 10/02/2026.',
        );
        final noise = email(
          from: 'Naukri <alerts@naukri.com>',
          subject: 'jobs',
          body: 'apply now',
        );

        final out = await service.extractCandidates(
          [bill, noise],
          aiExtract: throwingAi,
          onAiFallback: (m) => fallbackMessage = m,
        );

        expect(fallbackMessage, contains('boom'));
        expect(out.map((b) => b.merchant), [
          'Tata Power',
        ]); // noise never surfaces
      },
    );

    test('falls back when the whole AI extraction times out', () async {
      final service = GmailService(
        aiExtractionTimeout: const Duration(milliseconds: 10),
      );
      var fallbackMessage = '';
      Future<List<ParsedBill>> neverReturns(List<RawEmail> emails) =>
          Completer<List<ParsedBill>>().future;
      final bill = email(
        from: 'Tata Power <bills@tatapower.com>',
        subject: 'Electricity bill generated',
        body: 'Amount due ₹2,100. Due date 10/02/2026.',
      );

      final out = await service.extractCandidates(
        [bill],
        aiExtract: neverReturns,
        onAiFallback: (message) => fallbackMessage = message,
      );

      expect(fallbackMessage, contains('timed out'));
      expect(out.map((candidate) => candidate.merchant), ['Tata Power']);
    });

    test('globally deduplicates candidates from mixed AI batches', () async {
      final service = GmailService();
      final first = email(
        from: 'City Gas <no-reply@citygas.example>',
        subject: 'Payment Reminder A',
        body: 'Amount due ₹1,450 on 20 Feb 2026.',
      );
      final second = email(
        from: 'City Gas <no-reply@citygas.example>',
        subject: 'Payment Reminder B',
        body: 'Amount due ₹1,450 on 20 Feb 2026.',
      );
      Future<List<ParsedBill>> duplicateAi(List<RawEmail> emails) async => [
        _bill(emails[0], amount: 1450, category: 'utilities'),
        _bill(emails[1], amount: 1450, category: 'utilities'),
      ];

      final out = await service.extractCandidates([
        first,
        second,
      ], aiExtract: duplicateAi);

      expect(out, hasLength(1));
    });
  });
}
