import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn spend({
  required String yyyymm,
  required int amountPaise,
  String categoryKey = 'food',
  TransactionDirection direction = TransactionDirection.debit,
  PaymentInstrument instrument = PaymentInstrument.bank,
  TxnType type = TxnType.upi,
  String? ownerKey,
  int day = 12,
}) {
  final parts = yyyymm.split('-');
  final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), day);
  return ParsedTxn(
    smsId: 'sms:$yyyymm:$categoryKey:$amountPaise:$day',
    sender: 'VM-HDFCBK',
    direction: direction,
    instrument: instrument,
    type: type,
    amountPaise: amountPaise,
    txnDate: date,
    payeeType: PayeeType.merchant,
    categoryKey: categoryKey,
    confidence: 0.95,
    reviewStatus: ReviewStatus.confirmed,
    source: TxnSource.sms,
    ownerKey: ownerKey,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'r',
    bodyHash: 'h',
    scanBatchId: 'b',
  );
}

final _now = DateTime(2026, 7, 15);

void main() {
  const estimator = SeasonalEstimator();

  SeasonalEstimate estimate(
    List<ParsedTxn> history, {
    int targetMonth = 3,
    Set<String> owned = const {},
  }) => estimator.estimate(
    targetMonth1to12: targetMonth,
    discretionaryHistory: history,
    ownedOwnerKeys: owned,
    now: _now,
  );

  group('blend', () {
    test('blends same-month median with the trailing average', () {
      final history = [
        // Prior-year March occurrences (same-month median = 15000).
        spend(yyyymm: '2024-03', amountPaise: 10000),
        spend(yyyymm: '2025-03', amountPaise: 20000),
        // Trailing 3 months before July 2026 (avg = 6000).
        spend(yyyymm: '2026-04', amountPaise: 6000),
        spend(yyyymm: '2026-05', amountPaise: 6000),
        spend(yyyymm: '2026-06', amountPaise: 6000),
        // Filler so history is not "thin".
        spend(yyyymm: '2025-11', amountPaise: 5000),
        spend(yyyymm: '2025-12', amountPaise: 5000),
        spend(yyyymm: '2026-01', amountPaise: 5000),
        spend(yyyymm: '2026-02', amountPaise: 5000),
      ];

      final result = estimate(history).byCategory['food']!;

      // 0.6*15000 + 0.4*6000 = 11400.
      expect(result.amountPaise, 11400);
      expect(result.confidence, kSeasonalConfidenceSeasonal);
    });
  });

  group('same-month availability', () {
    test('falls back to the trailing average when the month is absent', () {
      final history = [
        for (final m in ['2025-10', '2025-11', '2025-12', '2026-01', '2026-02'])
          spend(yyyymm: m, amountPaise: 4000),
        spend(yyyymm: '2026-04', amountPaise: 9000),
        spend(yyyymm: '2026-05', amountPaise: 9000),
        spend(yyyymm: '2026-06', amountPaise: 9000),
      ];

      final result = estimate(history, targetMonth: 3).byCategory['food']!;

      expect(result.amountPaise, 9000);
      expect(result.confidence, kSeasonalConfidenceRecentOnly);
    });
  });

  group('thin history', () {
    test('uses recent-average-only with degraded confidence', () {
      final history = [
        spend(yyyymm: '2026-04', amountPaise: 10000),
        spend(yyyymm: '2026-05', amountPaise: 10000),
        spend(yyyymm: '2026-06', amountPaise: 10000),
      ];

      final result = estimate(history).byCategory['food']!;

      expect(result.amountPaise, 10000);
      expect(result.confidence, kSeasonalConfidenceThin);
    });
  });

  group('exclusions (one-owner + card + transfer/atm)', () {
    test('excludes card, atm, transfer, and owner-owned rupees', () {
      final history = [
        // These must NOT contribute to seasonal cash.
        spend(yyyymm: '2026-04', amountPaise: 99999, instrument: PaymentInstrument.card),
        spend(yyyymm: '2026-05', amountPaise: 99999, type: TxnType.atm),
        spend(yyyymm: '2026-06', amountPaise: 99999, type: TxnType.transfer),
        spend(yyyymm: '2026-06', amountPaise: 99999, ownerKey: 'owned:rent'),
      ];

      final result = estimate(history, owned: {'owned:rent'});

      expect(result.byCategory.containsKey('food'), isFalse);
    });
  });

  group('robustness', () {
    test('a single anomalous prior year does not poison the median', () {
      final history = [
        spend(yyyymm: '2022-03', amountPaise: 1000000), // anomaly
        spend(yyyymm: '2023-03', amountPaise: 1000),
        spend(yyyymm: '2024-03', amountPaise: 1000),
        spend(yyyymm: '2025-03', amountPaise: 1000),
        spend(yyyymm: '2026-04', amountPaise: 2000),
        spend(yyyymm: '2026-05', amountPaise: 2000),
        spend(yyyymm: '2026-06', amountPaise: 2000),
      ];

      final result = estimate(history).byCategory['food']!;

      // median(March) = 1000; 0.6*1000 + 0.4*2000 = 1400 — anomaly ignored.
      expect(result.amountPaise, 1400);
    });

    test('refund credits net against debits in the category month', () {
      final history = [
        spend(yyyymm: '2026-04', amountPaise: 10000),
        spend(yyyymm: '2026-05', amountPaise: 10000),
        spend(yyyymm: '2026-06', amountPaise: 10000),
        // A ₹30 refund in June nets June to 7000; trailing avg = 9000.
        spend(
          yyyymm: '2026-06',
          amountPaise: 3000,
          direction: TransactionDirection.credit,
          day: 20,
        ),
      ];

      final result = estimate(history).byCategory['food']!;

      expect(result.amountPaise, 9000);
    });
  });

  group('named constants', () {
    test('encode the D3 spec defaults', () {
      expect(kSeasonalSameMonthWeight, 0.6);
      expect(kSeasonalTrailingWeight, 0.4);
      expect(kSeasonalTrailingN, 3);
    });
  });
}
