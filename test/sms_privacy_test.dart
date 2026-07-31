import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_privacy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmsPrivacy.redactBody', () {
    test('masks amounts, accounts, references, balances, and VPAs', () {
      const body =
          'HDFC Bank: Rs. 1,234.56 debited from A/c XX1234 to ravi@okhdfcbank. '
          'UPI Ref 123456789012. Avl Bal Rs. 56,789.00';

      final redacted = SmsPrivacy.redactBody(body);

      expect(redacted, contains('[amount]'));
      expect(redacted, contains('[account]'));
      expect(redacted, contains('[vpa]'));
      expect(redacted, contains('[ref]'));
      expect(redacted, isNot(contains('1,234.56')));
      expect(redacted, isNot(contains('XX1234')));
      expect(redacted, isNot(contains('ravi@okhdfcbank')));
      expect(redacted, isNot(contains('123456789012')));
      expect(redacted, isNot(contains('56,789.00')));
    });

    test('redaction masks card/account tails written as "ending NNNN"', () {
      final r = SmsPrivacy.redactBody('Spent Rs 900 on Card ending 1234 at STORE');
      expect(r, isNot(contains('1234')));
      final r2 = SmsPrivacy.redactBody('A/c ending 4321 debited Rs 100');
      expect(r2, isNot(contains('4321')));
    });

    test('a standalone masked tail like XX1234 is redacted', () {
      final r = SmsPrivacy.redactBody('Purchase of Rs 250 on XX1234 approved');
      expect(r, isNot(contains('1234')));
    });

    test('a bare UPI reference token stays [ref] and is not partially masked', () {
      final r = SmsPrivacy.redactBody('Paid Rs 100. UPI Ref 987654 to store.');
      expect(r, contains('[ref]'));
      expect(r, isNot(contains('987654')));
    });
  });

  group('SmsPrivacy body hash and stable id', () {
    test('hashes normalized body text with sha256', () {
      final h1 = SmsPrivacy.bodyHash(' HDFC   Bank\nRs. 10 debited ', salt: 'test-salt');
      final h2 = SmsPrivacy.bodyHash('hdfc bank rs. 10 debited', salt: 'test-salt');

      expect(h1, h2);
      expect(h1, hasLength(64));
      expect(h1, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('body hash is salted so identical bodies differ across installs', () {
      final a = SmsPrivacy.bodyHash('Rs 500 debited a/c XX1234', salt: 'saltA');
      final b = SmsPrivacy.bodyHash('Rs 500 debited a/c XX1234', salt: 'saltB');

      expect(a, isNot(equals(b)));
    });

    test('body hash is stable for the same salt', () {
      final a = SmsPrivacy.bodyHash('Rs 500 debited a/c XX1234', salt: 'saltA');
      final b = SmsPrivacy.bodyHash('Rs 500 DEBITED  a/c XX1234', salt: 'saltA');

      expect(a, equals(b)); // normalization still applies
    });

    test('uses provider id when available and synthetic sha256 otherwise', () {
      final receivedAt = DateTime(2026, 7, 9, 18, 45);
      final withProvider = RawSms(
        providerId: '42',
        sender: 'VM-HDFCBK',
        body: 'Rs. 10 debited',
        receivedAt: receivedAt,
      );
      final withoutProvider = RawSms(
        sender: 'VM-HDFCBK',
        body: 'Rs. 10 debited',
        receivedAt: receivedAt,
      );

      expect(SmsPrivacy.stableSmsId(withProvider), 'provider:42');
      expect(SmsPrivacy.stableSmsId(withoutProvider), startsWith('synthetic:'));
      expect(
        SmsPrivacy.stableSmsId(withoutProvider),
        hasLength('synthetic:'.length + 64),
      );
      expect(
        SmsPrivacy.stableSmsId(withoutProvider),
        SmsPrivacy.stableSmsId(withoutProvider),
      );
    });
  });
}
