import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/seasonal_estimator.dart';
import 'package:flutter_test/flutter_test.dart';

/// Confirmed held-out MAPE acceptance bound for the SeasonalEstimator (Decision
/// D3). The spec-default blend (0.6 x same-month median + 0.4 x trailing-3)
/// lands well inside this on a stable seasonal series; a change that regresses
/// the estimator past this bound fails CI.
const double kSeasonalMapeBound = 0.20;

/// A stable, smooth seasonal spend curve (rupees) repeated identically across
/// years, so a held-out month is genuinely predictable from prior years plus
/// the recent trailing run — the exact signal the estimator is built to model.
const Map<int, int> _seasonalRupees = {
  1: 8000, 2: 8000, 3: 9000, 4: 10000, 5: 11000, 6: 11000,
  7: 10000, 8: 10000, 9: 11000, 10: 13000, 11: 15000, 12: 14000,
};

int _paiseFor(int month) => _seasonalRupees[month]! * 100;

ParsedTxn _spend({required int year, required int month}) => ParsedTxn(
      smsId: 'grocery:$year-$month',
      sender: 'VM-HDFCBK',
      direction: TransactionDirection.debit,
      instrument: PaymentInstrument.bank,
      type: TxnType.upi,
      amountPaise: _paiseFor(month),
      txnDate: DateTime(year, month, 12),
      merchant: 'BigBasket',
      payeeType: PayeeType.merchant,
      categoryKey: 'groceries',
      confidence: 0.95,
      reviewStatus: ReviewStatus.confirmed,
      source: TxnSource.sms,
      coverageBucket: CoverageBucket.datedEvent,
      rawBodyRedacted: 'redacted',
      bodyHash: 'h',
      scanBatchId: 'b',
    );

void main() {
  // Three identical seasonal years of one discretionary category.
  final history = <ParsedTxn>[
    for (final year in [2023, 2024, 2025])
      for (var month = 1; month <= 12; month++) _spend(year: year, month: month),
  ];

  const estimator = SeasonalEstimator();

  /// True hold-out: predict [target] using only transactions strictly before it.
  CategorySeasonalEstimate predict(DateTime target) {
    final cutoff = DateTime(target.year, target.month, 1);
    final priorOnly = history.where((t) => t.txnDate.isBefore(cutoff)).toList();
    final estimate = estimator.estimate(
      targetMonth1to12: target.month,
      discretionaryHistory: priorOnly,
      ownedOwnerKeys: const {},
      now: cutoff,
    );
    final grocery = estimate.byCategory['groceries'];
    expect(grocery, isNotNull, reason: 'no estimate for ${target.year}-${target.month}');
    return grocery!;
  }

  test('held-out MAPE stays within the confirmed bound (D3)', () {
    // Hold out several months spanning the low, rising, and festival-peak
    // seasons so the blend is exercised, not just an easy flat stretch.
    final holdouts = [
      DateTime(2025, 4),
      DateTime(2025, 6),
      DateTime(2025, 9),
      DateTime(2025, 10),
      DateTime(2025, 11),
    ];

    var totalApe = 0.0;
    for (final target in holdouts) {
      final actual = _paiseFor(target.month);
      final predicted = predict(target).amountPaise;
      totalApe += (predicted - actual).abs() / actual;
    }
    final mape = totalApe / holdouts.length;

    // A real gate: the estimate is neither trivially perfect nor a passthrough.
    expect(mape, greaterThan(0));
    expect(mape, lessThanOrEqualTo(kSeasonalMapeBound), reason: 'MAPE $mape > $kSeasonalMapeBound');
  });

  test('a two-prior-year same-month estimate carries seasonal confidence', () {
    final estimate = predict(DateTime(2025, 11));
    expect(estimate.confidence, kSeasonalConfidenceSeasonal);
  });
}
