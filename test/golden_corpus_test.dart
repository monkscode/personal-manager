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
        amountPaise = j['amountPaise'] as int?;

  final String sender;
  final String body;
  final DateTime receivedAt;
  final bool isTxn;
  final String? direction;
  final int? amountPaise;
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
        }
      }
    }
  });
}
