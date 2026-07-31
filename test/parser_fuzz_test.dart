import 'dart:math';

import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the parser's known-bank sender fragments so the 2-of-N guardrail can
/// be independently re-derived on any emitted transaction.
const _knownBankFragments = [
  'hdfc', 'icici', 'sbi', 'axis', 'kotak', 'yesbank',
  'idfc', 'indusind', 'federal', 'canara', 'pnb',
];

bool _isKnownBankSender(String sender) {
  final lower = sender.toLowerCase();
  return _knownBankFragments.any(lower.contains);
}

/// The "no false data" guardrail (spec §6): a real transaction shows >= 2 of
/// {amount, masked account, balance, UPI/ref, known bank sender}. Amount is
/// always present on an emitted row, so at least one *other* signal is required.
int _otherSignalCount(ParsedTxn t) {
  var n = 0;
  if (t.accountLast4 != null) n++;
  if (t.balancePaise != null) n++;
  if (t.refNumber != null) n++;
  if (_isKnownBankSender(t.sender)) n++;
  return n;
}

const _senders = [
  'VM-HDFCBK', 'AD-SBIINB', 'VK-AXISBK', 'AX-KOTAKB', 'VM-ICICIB',
  'JD-AMAZON', 'TX-PROMOS', 'BZ-NEWS', '', '12345', 'x', 'idfc-bank',
];

const _fragments = [
  'Rs.1,250.00', '₹500', 'INR 9999', 'Rs.', 'Rs.abc', 'Rs.0.00', 'Rs.99999999999',
  'debited', 'credited', 'spent', 'paid', 'withdrawn', 'refunded', 'reversed', 'charged',
  'from A/c XX1234', 'card ending 5678', 'acct no 9999', 'account XX0000',
  'UPI Ref 123456789012', 'txn id ABCD1234EF', 'rrn 998877665544', 'ref:',
  'Avl Bal Rs.10,000.00', 'available limit Rs.5,000.00', 'credit limit Rs.1,00,000',
  'to swiggy@okhdfcbank', 'from payer@paytm', 'a@b',
  'OTP 123456', 'one time password', 'exclusive offer sale discount cashback',
  '😀🎉💸🏦', '\n\t\r', '   ', '', 'null', 'undefined', '<script>', '"; DROP TABLE',
  'on 27-06-25', 'valid for 10 min', 'do not share', '👍', '\u0000\u0001',
];

void main() {
  const parser = SmsTransactionParser();
  final rng = Random(20260711); // fixed seed → deterministic, reproducible fuzz

  String randomBody() {
    final count = rng.nextInt(8); // 0..7 fragments
    final parts = [for (var i = 0; i < count; i++) _fragments[rng.nextInt(_fragments.length)]];
    var body = parts.join(rng.nextBool() ? ' ' : '');
    // Occasionally truncate mid-string to simulate a cut-off SMS.
    if (body.isNotEmpty && rng.nextInt(4) == 0) {
      body = body.substring(0, rng.nextInt(body.length));
    }
    // Occasionally blow up the length.
    if (rng.nextInt(50) == 0) body = body * (1 + rng.nextInt(200));
    return body;
  }

  ParsedTxn? run(String sender, String body) => parser.parseOne(
        RawSms(sender: sender, body: body, receivedAt: DateTime(2025, 6, 27, 10)),
        scanBatchId: 'fuzz',
        bodyHashSalt: 'fuzz-salt',
      );

  test('never throws and never emits a row failing the 2-of-N guardrail', () {
    for (var i = 0; i < 5000; i++) {
      final sender = _senders[rng.nextInt(_senders.length)];
      final body = randomBody();

      ParsedTxn? parsed;
      expect(() => parsed = run(sender, body), returnsNormally,
          reason: 'threw on sender="$sender" body="$body"');

      if (parsed != null) {
        // 2-of-N: amount (always present) + at least one more signal.
        expect(_otherSignalCount(parsed!), greaterThanOrEqualTo(1),
            reason: 'emitted a row with < 2 signals: "$body"');
        // Money is a non-negative integer paise; confidence is a valid probability.
        expect(parsed!.amountPaise, greaterThanOrEqualTo(0));
        expect(parsed!.confidence, inInclusiveRange(0, 1));
        // The review flag and status stay internally consistent.
        final autoAdded = parsed!.reviewStatus == ReviewStatus.autoAdded;
        final needsReview = parsed!.reviewStatus == ReviewStatus.needsReview;
        expect(autoAdded || needsReview, isTrue);
      }
    }
  });

  test('adversarial fixed inputs are handled without throwing', () {
    final inputs = [
      '',
      '   ',
      '\n\n\n',
      '😀😀😀😀',
      '\u0000\u0001\u0002',
      'Rs.',
      'Rs.,,,...',
      '₹₹₹₹',
      'debited credited spent paid refunded reversed',
      'Rs.1 Rs.2 Rs.3 Rs.4 Rs.5 debited credited',
      'a' * 100000,
      'HDFC Rs.999999999999999999999 debited',
    ];
    for (final sender in ['VM-HDFCBK', '', 'RANDOM']) {
      for (final body in inputs) {
        expect(() => run(sender, body), returnsNormally, reason: 'threw on "$body"');
      }
    }
  });
}
