import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/cash_coverage_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn cashTxn({
  required int amountPaise,
  required DateTime date,
  TxnType type = TxnType.atm,
  TransactionDirection direction = TransactionDirection.debit,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String categoryKey = 'cash',
  String smsId = 'sms',
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK',
  direction: direction,
  instrument: instrument,
  type: type,
  amountPaise: amountPaise,
  txnDate: date,
  payeeType: PayeeType.unknown,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h',
  scanBatchId: 'b',
);

/// Builds a window with a single ATM withdrawal and a single tracked
/// discretionary bank debit so ratios are exact.
List<ParsedTxn> window(int atmPaise, int discPaise, {DateTime? at}) {
  final date = at ?? DateTime(2026, 6, 15);
  return [
    if (atmPaise > 0)
      cashTxn(amountPaise: atmPaise, date: date, type: TxnType.atm, smsId: 'atm'),
    if (discPaise > 0)
      cashTxn(
        amountPaise: discPaise,
        date: date,
        type: TxnType.pos,
        categoryKey: 'shopping',
        smsId: 'disc',
      ),
  ];
}

void main() {
  const metrics = CashCoverageMetrics();
  final now = DateTime(2026, 6, 30);

  group('constants', () {
    test('encode the confirmed D6 cash materiality thresholds', () {
      expect(kCashMaterialityMinAtmPaise, 500000);
      expect(kCashNoCaveatMaxRatio, 0.10);
      expect(kCashCaveatMaxRatio, 0.25);
      expect(kCashHeavyMaxRatio, 0.40);
      expect(kCashDrainWindowDays, 90);
    });
  });

  group('cashDrainRatio', () {
    test('is atm / (atm + tracked discretionary bank debit)', () {
      expect(metrics.cashDrainRatio(window(500000, 4500000)), closeTo(0.10, 1e-9));
    });

    test('is zero when there is no ATM cash', () {
      expect(metrics.cashDrainRatio(window(0, 4500000)), 0);
    });

    test('excludes transfers and ATM from the tracked discretionary base', () {
      final w = [
        cashTxn(amountPaise: 500000, date: now, type: TxnType.atm, smsId: 'a'),
        cashTxn(
          amountPaise: 9000000,
          date: now,
          type: TxnType.transfer,
          categoryKey: 'transfer',
          smsId: 't',
        ),
      ];
      // Transfer is not tracked discretionary spend, so the ratio collapses to
      // atm / atm = 1.0 rather than being diluted by the transfer.
      expect(metrics.cashDrainRatio(w), 1.0);
      expect(metrics.trackedDiscretionaryBankDebitPaise(w), 0);
    });
  });

  group('level threshold boundaries', () {
    test('below ₹5,000 ATM total → none regardless of ratio', () {
      expect(
        metrics.level(window(kCashMaterialityMinAtmPaise - 1, 0)),
        CashCoverageLevel.none,
      );
    });

    test('material ATM but ratio below 10% → none', () {
      expect(metrics.level(window(500000, 4600000)), CashCoverageLevel.none);
    });

    test('exactly 10% ratio → caveat', () {
      expect(metrics.level(window(500000, 4500000)), CashCoverageLevel.caveat);
    });

    test('exactly 25% ratio → caveat (upper edge)', () {
      expect(metrics.level(window(2500000, 7500000)), CashCoverageLevel.caveat);
    });

    test('just above 25% → cash-heavy', () {
      expect(metrics.level(window(2600000, 7400000)), CashCoverageLevel.cashHeavy);
    });

    test('exactly 40% ratio → cash-heavy (upper edge)', () {
      expect(metrics.level(window(4000000, 6000000)), CashCoverageLevel.cashHeavy);
    });

    test('above 40% → low coverage', () {
      expect(
        metrics.level(window(4100000, 5900000)),
        CashCoverageLevel.lowCoverage,
      );
    });
  });

  group('trailing window and current-month-to-date', () {
    test('trailingWindow drops events older than 90 days', () {
      final history = [
        cashTxn(amountPaise: 500000, date: now.subtract(const Duration(days: 10)), smsId: 'recent'),
        cashTxn(amountPaise: 900000, date: now.subtract(const Duration(days: 120)), smsId: 'old'),
      ];
      final trailing = metrics.trailingWindow(history, now);
      expect(trailing.map((t) => t.smsId), ['recent']);
    });

    test('current-month-to-date ATM is reported separately when material', () {
      final history = [
        cashTxn(amountPaise: 600000, date: DateTime(2026, 6, 5), type: TxnType.atm, smsId: 'thismonth'),
        cashTxn(amountPaise: 700000, date: DateTime(2026, 5, 20), type: TxnType.atm, smsId: 'lastmonth'),
      ];
      expect(metrics.currentMonthToDateAtmPaise(history, now), 600000);
      expect(metrics.isCurrentMonthCashMaterial(history, now), isTrue);
    });

    test('current-month cash below the materiality floor is not flagged', () {
      final history = [
        cashTxn(amountPaise: 400000, date: DateTime(2026, 6, 5), type: TxnType.atm, smsId: 'thismonth'),
      ];
      expect(metrics.isCurrentMonthCashMaterial(history, now), isFalse);
    });
  });

  group('TASK-24 M10 — the trailing window is day-normalised', () {
    test('does not move with the time of day', () {
      // A midday transaction on the window's edge day: with a wall-clock
      // cutoff it is inside the window at 00:05 and outside it at 23:55 on the
      // very same day.
      final txn = cashTxn(amountPaise: 100000, date: DateTime(2026, 4, 1, 12));
      final morning = metrics.trailingWindow([txn], DateTime(2026, 6, 30, 0, 5));
      final evening = metrics.trailingWindow([
        txn,
      ], DateTime(2026, 6, 30, 23, 55));

      expect(morning.length, evening.length);
    });

    test('includes a transaction exactly 90 days old', () {
      final asOf = DateTime(2026, 6, 30);
      final exactly90 = cashTxn(
        amountPaise: 100000,
        date: asOf.subtract(const Duration(days: kCashDrainWindowDays)),
      );

      expect(metrics.trailingWindow([exactly90], asOf), hasLength(1));
    });

    test('still excludes a transaction 91 days old (guard)', () {
      final asOf = DateTime(2026, 6, 30);
      final tooOld = cashTxn(
        amountPaise: 100000,
        date: asOf.subtract(const Duration(days: kCashDrainWindowDays + 1)),
      );

      expect(metrics.trailingWindow([tooOld], asOf), isEmpty);
    });
  });

}
