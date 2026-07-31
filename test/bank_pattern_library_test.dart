import 'package:expense_insight/services/bank_pattern_library.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  group('kBankPatterns registry', () {
    test('covers at least the five required banks', () {
      final keys = kBankPatterns.map((p) => p.bankKey).toSet();
      expect(keys, containsAll(<String>['sbi', 'hdfc', 'icici', 'axis', 'kotak']));
    });

    test('bank keys are unique and lowercase', () {
      final keys = kBankPatterns.map((p) => p.bankKey).toList();
      expect(keys.toSet().length, keys.length);
      for (final key in keys) {
        expect(key, key.toLowerCase(), reason: 'bankKey must be lowercase: $key');
      }
    });

    test('every sender id is uppercase and non-empty', () {
      for (final pattern in kBankPatterns) {
        expect(pattern.senderIds, isNotEmpty, reason: pattern.bankKey);
        for (final id in pattern.senderIds) {
          expect(id, isNotEmpty);
          expect(id, id.toUpperCase(), reason: 'sender id must be uppercase: $id');
        }
      }
    });

    test('sender ids do not collide across banks', () {
      final seen = <String, String>{};
      for (final pattern in kBankPatterns) {
        for (final id in pattern.senderIds) {
          expect(
            seen.containsKey(id),
            isFalse,
            reason: 'sender id $id claimed by both ${seen[id]} and ${pattern.bankKey}',
          );
          seen[id] = pattern.bankKey;
        }
      }
    });

    test('is immutable — cannot be mutated at runtime', () {
      expect(
        () => kBankPatterns.add(
          const BankSmsPattern(bankKey: 'x', senderIds: ['X']),
        ),
        throwsUnsupportedError,
      );
      expect(
        () => kBankPatterns.first.senderIds.add('X'),
        throwsUnsupportedError,
      );
    });
  });

  group('bankPatternForSender', () {
    test('resolves real-world tagged senders to the right bank', () {
      expect(bankPatternForSender('VM-HDFCBK')?.bankKey, 'hdfc');
      expect(bankPatternForSender('AD-SBIINB-T')?.bankKey, 'sbi');
      expect(bankPatternForSender('AX-ICICIT')?.bankKey, 'icici');
      expect(bankPatternForSender('AD-AXISBK')?.bankKey, 'axis');
      expect(bankPatternForSender('VK-KOTAKB')?.bankKey, 'kotak');
    });

    test('returns null for an unknown sender', () {
      expect(bankPatternForSender('VM-RANDOMX'), isNull);
      expect(bankPatternForSender('AMAZON'), isNull);
    });
  });

  group('compiled per-bank regexes', () {
    test('each defined regex is a usable RegExp', () {
      for (final pattern in kBankPatterns) {
        for (final regex in [pattern.debit, pattern.credit, pattern.balance]) {
          if (regex != null) {
            // Exercising it must not throw.
            expect(() => regex.hasMatch('probe'), returnsNormally);
          }
        }
      }
    });

    test('SBI patterns match a real debit alert', () {
      final sbi = bankPatternForSender('AD-SBIINB')!;
      const body =
          'Dear Customer, Rs.500.00 debited from A/c XX1234 on 05-07-26 '
          'to VPA merchant@sbi (UPI Ref 512345678901). Avl Bal Rs.10,000.00 -SBI';
      expect(sbi.debit!.hasMatch(body), isTrue);
      expect(sbi.balance!.hasMatch(body), isTrue);
      expect(sbi.credit!.hasMatch(body), isFalse);
    });

    test('HDFC patterns match a real credit alert', () {
      final hdfc = bankPatternForSender('VM-HDFCBK')!;
      const body =
          'HDFC Bank: Rs.2,000.00 credited to A/c XX9876 on 05-Jul-26. '
          'Avl bal Rs.12,000.00';
      expect(hdfc.credit!.hasMatch(body), isTrue);
      expect(hdfc.balance!.hasMatch(body), isTrue);
      expect(hdfc.debit!.hasMatch(body), isFalse);
    });

    test('ICICI/Axis/Kotak debit patterns match debit alerts', () {
      final icici = bankPatternForSender('AX-ICICIB')!;
      expect(
        icici.debit!.hasMatch('Rs 750.00 debited from ICICI Bank A/c XX4321'),
        isTrue,
      );
      final axis = bankPatternForSender('AD-AXISBK')!;
      expect(
        axis.debit!.hasMatch('INR 1,299.00 spent on Axis Bank Card XX5678'),
        isTrue,
      );
      final kotak = bankPatternForSender('VK-KOTAKB')!;
      expect(
        kotak.debit!.hasMatch('Rs.320 debited from Kotak Bank A/c XX0011'),
        isTrue,
      );
    });
  });
}
