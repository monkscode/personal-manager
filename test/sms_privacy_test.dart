import 'dart:convert';
import 'dart:io';

import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_privacy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The body *shapes* that leaked before the redaction gaps were closed.
///
/// The shapes are what matter — single-`x` tail, bare tail after `Card`, bare
/// balance, keyword-less account number. The values are synthetic: this
/// repository is public, so no real tail or balance belongs here even in the
/// test that proves they get removed.
const _leakingBodies = <String>[
  'Rs.20000.00 withdrawn from HDFC Bank Card x2222 at MAIN STREET ATM '
      'on 17-07-26 Avl bal: 33333.00',
  'Paid Rs.500.00 On HDFC Bank Card 7116 at KANDOI BHOGILAL MULCHA '
      'on 12-07-26 Bal 12345.67',
  'Dear UPI user A/C X3456 debited by 1250.0 on 27-06-25 trf to STORE '
      'Refno 501234567890 -SBI',
  'For IMPS -Federal bank- 900112233445 Avl bal 4500.00',
];

List<String> _goldenBodies() {
  final bodies = <String>[];
  for (final file in Directory('test/golden').listSync().whereType<File>()) {
    final entries = jsonDecode(file.readAsStringSync()) as List<dynamic>;
    for (final entry in entries) {
      bodies.add((entry as Map<String, dynamic>)['body'] as String);
    }
  }
  return bodies;
}

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

  group('SmsPrivacy.redactBody closes the card-tail and balance gaps', () {
    test('the observed leaking bodies keep no tail and no balance', () {
      for (final body in _leakingBodies) {
        final redacted = SmsPrivacy.redactBody(body);
        expect(
          redacted,
          isNot(matches(RegExp(r'\d{4}'))),
          reason: 'a 4-digit run survived redaction of: $body',
        );
        for (final leak in const [
          '7301',
          '7116',
          '3456',
          '33333.00',
          '12345.67',
          '1250.0',
          '900112233445',
          '4500.00',
        ]) {
          expect(
            redacted,
            isNot(contains(leak)),
            reason: '"$leak" survived redaction of: $body',
          );
        }
      }
    });

    test('every card and account tail spelling is redacted', () {
      const inputs = <String>[
        'Spent on HDFC Bank Card x2222 today',
        'Paid On HDFC Bank Card 7116 at STORE',
        'Dear UPI user A/C X3456 debited',
        'Spent Rs 900 on Card ending 1234 at STORE',
        'Purchase on **1234 approved',
        'Purchase on XX1234 approved',
        'ICICI Bank: Acct XX5678 debited',
      ];
      for (final input in inputs) {
        final redacted = SmsPrivacy.redactBody(input);
        expect(redacted, contains('[account]'), reason: input);
        expect(
          redacted,
          isNot(matches(RegExp(r'\d{4}'))),
          reason: 'a tail survived: $input',
        );
      }
    });

    test('bare balances with no currency token are redacted', () {
      for (final input in const <String>[
        'Avl bal: 33333.00',
        'Bal 12345.67',
        'Avl Bal 4500.00',
        'debited by 1250.0',
        'credited by 9999.50',
      ]) {
        final redacted = SmsPrivacy.redactBody(input);
        expect(redacted, contains('[amount]'), reason: input);
        expect(
          redacted,
          isNot(matches(RegExp(r'\d'))),
          reason: 'a balance digit survived: $input',
        );
      }
    });

    test('redaction removes the digits but keeps the noun for review', () {
      final redacted = SmsPrivacy.redactBody(
        'HDFC Credit Card ending 4321 was used',
      );
      expect(redacted, contains('Card'));
      expect(redacted, contains('[account]'));
      expect(redacted, isNot(contains('4321')));
    });

    test('no golden-corpus body keeps a run of 4 or more digits', () {
      final bodies = _goldenBodies();
      expect(bodies, isNotEmpty);
      for (final body in bodies) {
        final redacted = SmsPrivacy.redactBody(body);
        expect(
          redacted,
          isNot(matches(RegExp(r'\d{4}'))),
          reason: 'a 4-digit run survived redaction of: $body\n  -> $redacted',
        );
      }
    });
  });

  group('SmsPrivacy.stableSmsId is salted', () {
    RawSms sms() => RawSms(
      sender: 'VM-HDFCBK',
      body: 'Rs.20000.00 withdrawn from HDFC Bank Card x2222',
      receivedAt: DateTime(2026, 7, 17, 20, 20),
    );

    test('the same body hashes differently under two salts', () {
      expect(
        SmsPrivacy.stableSmsId(sms(), salt: 'saltA'),
        isNot(equals(SmsPrivacy.stableSmsId(sms(), salt: 'saltB'))),
      );
    });

    test('the same body is stable under one salt', () {
      expect(
        SmsPrivacy.stableSmsId(sms(), salt: 'saltA'),
        SmsPrivacy.stableSmsId(sms(), salt: 'saltA'),
      );
    });

    test('a provider id still wins and is unaffected by the salt', () {
      final withProvider = RawSms(
        providerId: '42',
        sender: 'VM-HDFCBK',
        body: 'Rs. 10 debited',
        receivedAt: DateTime(2026, 7, 9),
      );
      expect(SmsPrivacy.stableSmsId(withProvider, salt: 'saltA'), 'provider:42');
      expect(SmsPrivacy.stableSmsId(withProvider, salt: 'saltB'), 'provider:42');
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

      expect(SmsPrivacy.stableSmsId(withProvider, salt: 's'), 'provider:42');
      expect(
        SmsPrivacy.stableSmsId(withoutProvider, salt: 's'),
        startsWith('synthetic:'),
      );
      expect(
        SmsPrivacy.stableSmsId(withoutProvider, salt: 's'),
        hasLength('synthetic:'.length + 64),
      );
      expect(
        SmsPrivacy.stableSmsId(withoutProvider, salt: 's'),
        SmsPrivacy.stableSmsId(withoutProvider, salt: 's'),
      );
    });
  });
}
