import 'dart:convert';
import 'dart:io';

import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Confirmed parser acceptance targets (Decision D9). A change that regresses
/// precision/recall below these against the checked-in, redacted golden corpus
/// fails CI — this is what makes "the parser works" measurable.
const double kGoldenPrecisionTarget = 0.90;
const double kGoldenRecallTarget = 0.90;

/// Governance: minimum labelled samples per major bank (Decision D9).
const int kGoldenMinSamplesPerBank = 5;

const _bankFiles = <String>['sbi.json', 'hdfc.json', 'icici.json', 'axis.json', 'kotak.json'];

class _Sample {
  _Sample(Map<String, dynamic> j)
      : sender = j['sender'] as String,
        body = j['body'] as String,
        receivedAt = DateTime.parse(j['receivedAt'] as String),
        isTxn = j['isTxn'] as bool,
        direction = j['direction'] as String?,
        amountPaise = j['amountPaise'] as int?,
        autoAdd = j['autoAdd'] as bool?,
        merchant = j['merchant'] as String?,
        instrument = j['instrument'] as String?;

  final String sender;
  final String body;
  final DateTime receivedAt;
  final bool isTxn;
  final String? direction;
  final int? amountPaise;

  /// Optional. The corpus went years without asserting either, which is why a
  /// merchant of `amazon on 26-06-25. available limit rs` and a credit-card
  /// purchase filed as a bank debit both survived in sample 2 unnoticed.
  final String? merchant;
  final String? instrument;

  /// Explicitly `false` on a real transaction that must never be auto-added —
  /// an AutoPay pre-notice, say, which is genuine signal but not a dated
  /// actual. Null means the sample makes no claim either way.
  final bool? autoAdd;
}

void main() {
  const parser = SmsTransactionParser();

  List<_Sample> load(String file) {
    final raw = File(p.join('test', 'golden', file)).readAsStringSync();
    return (jsonDecode(raw) as List)
        .map((e) => _Sample(e as Map<String, dynamic>))
        .toList();
  }

  ParsedTxn? parse(_Sample s) => parser.parseOne(
        RawSms(sender: s.sender, body: s.body, receivedAt: s.receivedAt),
        scanBatchId: 'golden',
        bodyHashSalt: 'golden-salt',
      );

  test('the corpus meets the checked-in governance (>= N per major bank)', () {
    expect(_bankFiles.length, greaterThanOrEqualTo(5));
    for (final file in _bankFiles) {
      expect(
        load(file).length,
        greaterThanOrEqualTo(kGoldenMinSamplesPerBank),
        reason: '$file must carry >= $kGoldenMinSamplesPerBank samples',
      );
    }
  });

  test('parser precision/recall meet the confirmed targets (D9)', () {
    var truePositive = 0, falsePositive = 0, falseNegative = 0;
    for (final file in _bankFiles) {
      for (final s in load(file)) {
        final predictedTxn = parse(s) != null;
        if (s.isTxn && predictedTxn) truePositive++;
        if (!s.isTxn && predictedTxn) falsePositive++;
        if (s.isTxn && !predictedTxn) falseNegative++;
      }
    }
    final precision = truePositive / (truePositive + falsePositive);
    final recall = truePositive / (truePositive + falseNegative);
    expect(
      precision,
      greaterThanOrEqualTo(kGoldenPrecisionTarget),
      reason: 'precision $precision (tp=$truePositive fp=$falsePositive)',
    );
    expect(
      recall,
      greaterThanOrEqualTo(kGoldenRecallTarget),
      reason: 'recall $recall (tp=$truePositive fn=$falseNegative)',
    );
  });

  test('extracted direction and amount match the labels for detected txns', () {
    for (final file in _bankFiles) {
      for (final s in load(file)) {
        final parsed = parse(s);
        if (!s.isTxn || parsed == null) continue;
        if (s.direction != null) {
          expect(parsed.direction.storageValue, s.direction, reason: 'direction: "${s.body}"');
        }
        if (s.amountPaise != null) {
          expect(parsed.amountPaise, s.amountPaise, reason: 'amount: "${s.body}"');
        }
      }
    }
  });

  test('no noise sample is ever auto-added at the 0.8 threshold (closes D9)', () {
    expect(kAutoAddConfidenceThreshold, 0.8);
    for (final file in _bankFiles) {
      for (final s in load(file)) {
        final parsed = parse(s);
        if (parsed != null && parsed.reviewStatus == ReviewStatus.autoAdded) {
          expect(s.isTxn, isTrue, reason: 'a non-txn was auto-added: "${s.body}"');
          expect(
            s.autoAdd,
            isNot(false),
            reason: 'a review-only sample was auto-added: "${s.body}"',
          );
        }
        if (s.autoAdd ?? false) {
          expect(
            parsed?.reviewStatus,
            ReviewStatus.autoAdded,
            reason: 'a clean sample was held back from auto-add: "${s.body}"',
          );
        }
      }
    }
  });

  test('merchant and instrument match the labels the corpus states', () {
    for (final file in _bankFiles) {
      for (final s in load(file)) {
        final parsed = parse(s);
        if (parsed == null) continue;
        if (s.merchant != null) {
          expect(parsed.merchant, s.merchant, reason: 'merchant: "${s.body}"');
        }
        if (s.instrument != null) {
          expect(
            parsed.instrument.storageValue,
            s.instrument,
            reason: 'instrument: "${s.body}"',
          );
        }
      }
    }
  });

  test('the corpus carries the hard negatives the gate depends on', () {
    final noise = [
      for (final file in _bankFiles)
        for (final s in load(file))
          if (!s.isTxn) s.body.toLowerCase(),
    ];

    // Without these the precision gate only ever sees OTP and offer copy, which
    // the sender/verb checks reject for free — it proves almost nothing.
    expect(noise.any((b) => b.contains('pre-approved')), isTrue);
    expect(noise.any((b) => b.contains('could not be processed')), isTrue);
    expect(noise.any((b) => b.contains('below the required minimum')), isTrue);
    expect(noise.any((b) => b.contains('balance in a/c')), isTrue);
  });
}
