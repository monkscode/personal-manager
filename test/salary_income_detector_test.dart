import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/salary_income_detector.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn credit({
  required String yyyymm,
  required int amountPaise,
  int day = 1,
  String accountLast4 = '1111',
  PayeeType payeeType = PayeeType.unknown,
  PaymentInstrument instrument = PaymentInstrument.bank,
  String sender = 'VM-HDFCBK',
  String? merchant,
}) {
  final parts = yyyymm.split('-');
  final date = DateTime(int.parse(parts[0]), int.parse(parts[1]), day);
  return ParsedTxn(
    smsId: 'c:$yyyymm:$amountPaise:$accountLast4',
    sender: sender,
    direction: TransactionDirection.credit,
    instrument: instrument,
    type: TxnType.upi,
    amountPaise: amountPaise,
    txnDate: date,
    accountLast4: accountLast4,
    merchant: merchant,
    payeeType: payeeType,
    categoryKey: 'income',
    confidence: 0.95,
    reviewStatus: ReviewStatus.confirmed,
    source: TxnSource.sms,
    coverageBucket: CoverageBucket.datedEvent,
    rawBodyRedacted: 'r',
    bodyHash: 'h',
    scanBatchId: 'b',
  );
}

const _detector = SalaryIncomeDetector();
final _now = DateTime(2026, 7, 15);

void main() {
  group('detectSalary — day drift is circular', () {
    test('a salary that slips to the prior month-end keeps a tight window', () {
      // The weekend/holiday drift the spec calls out: normally the 1st, but
      // 31 March instead of 1 April. Measured linearly that is 30 days of
      // drift, which makes the minimum-balance date meaningless.
      final profile = _detector.detectSalary(
        [
          credit(yyyymm: '2026-03', amountPaise: 5000000, day: 31),
          credit(yyyymm: '2026-05', amountPaise: 5000000, day: 1),
          credit(yyyymm: '2026-06', amountPaise: 5000000, day: 1),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.expectedDayWindowDays, lessThanOrEqualTo(2));
    });

    test('the 28th, 29th and 30th span two days', () {
      final profile = _detector.detectSalary(
        [
          credit(yyyymm: '2026-03', amountPaise: 5000000, day: 28),
          credit(yyyymm: '2026-04', amountPaise: 5000000, day: 29),
          credit(yyyymm: '2026-05', amountPaise: 5000000, day: 30),
        ],
        now: _now,
      );

      expect(profile.expectedDayWindowDays, 2);
      expect(profile.expectedDay, 29);
    });
  });

  group('detectSalary — payer consistency', () {
    test('three credits from three different payers are not a salary', () {
      // A freelancer with three clients, or three FD maturities. Nothing here
      // has a reason to recur, so the forecast must not anchor on it.
      final profile = _detector.detectSalary(
        [
          credit(yyyymm: '2026-04', amountPaise: 5000000, merchant: 'CLIENT A'),
          credit(yyyymm: '2026-05', amountPaise: 5000000, merchant: 'CLIENT B'),
          credit(yyyymm: '2026-06', amountPaise: 5000000, merchant: 'CLIENT C'),
        ],
        now: _now,
      );

      expect(profile.confidence, isNot(SalaryConfidence.detectedStable));
    });

    test('three credits from the same payer still promote', () {
      final profile = _detector.detectSalary(
        [
          for (final m in ['2026-04', '2026-05', '2026-06'])
            credit(yyyymm: m, amountPaise: 5000000, merchant: 'ACME PAYROLL'),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.basePaise, 5000000);
    });

    test('a one-off larger credit does not displace the salary payer', () {
      final profile = _detector.detectSalary(
        [
          for (final m in ['2026-04', '2026-05', '2026-06'])
            credit(yyyymm: m, amountPaise: 5000000, merchant: 'ACME PAYROLL'),
          credit(yyyymm: '2026-05', amountPaise: 9000000, merchant: 'FD MATURITY'),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.basePaise, 5000000);
    });
  });

  group('detectSalary — stable', () {
    test('detects a stable monthly salary as the cluster median', () {
      final profile = _detector.detectSalary(
        [
          for (final m in ['2026-03', '2026-04', '2026-05', '2026-06'])
            credit(yyyymm: m, amountPaise: 5000000),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.basePaise, 5000000);
      expect(profile.expectedDay, 1);
      expect(profile.effectiveMonthSatisfied, isFalse);
    });

    test('effectiveMonthSatisfied is true once this month is already paid', () {
      final profile = _detector.detectSalary(
        [
          for (final m in ['2026-04', '2026-05', '2026-06', '2026-07'])
            credit(yyyymm: m, amountPaise: 5000000),
        ],
        now: _now,
      );

      expect(profile.effectiveMonthSatisfied, isTrue);
    });

    test('excludes a bonus/arrears month from the base', () {
      final profile = _detector.detectSalary(
        [
          credit(yyyymm: '2026-03', amountPaise: 5000000),
          credit(yyyymm: '2026-04', amountPaise: 5000000),
          credit(yyyymm: '2026-05', amountPaise: 5000000),
          credit(yyyymm: '2026-06', amountPaise: 15000000), // bonus
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.basePaise, 5000000);
    });
  });

  group('detectSalary — variable', () {
    test('uses the conservative p20 floor', () {
      final profile = _detector.detectSalary(
        [
          credit(yyyymm: '2026-01', amountPaise: 4000000),
          credit(yyyymm: '2026-02', amountPaise: 4500000),
          credit(yyyymm: '2026-03', amountPaise: 5000000),
          credit(yyyymm: '2026-04', amountPaise: 5500000),
          credit(yyyymm: '2026-05', amountPaise: 6000000),
          credit(yyyymm: '2026-06', amountPaise: 7000000),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.detectedVariable);
      expect(profile.basePaise, 4500000); // p20
      expect(profile.rangeHighPaise, greaterThan(profile.basePaise!));
    });
  });

  group('detectSalary — cold start and fallback', () {
    test('a single high credit is not promoted to salary', () {
      final profile = _detector.detectSalary(
        [credit(yyyymm: '2026-06', amountPaise: 20000000)],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.insufficientData);
      expect(profile.basePaise, isNull);
    });

    test('configured salary is used as a fallback when detection is thin', () {
      final profile = _detector.detectSalary(
        [credit(yyyymm: '2026-06', amountPaise: 20000000)],
        configuredSalaryRupees: '60000',
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.configuredFallback);
      expect(profile.basePaise, 6000000);
    });

    test('P2P credits are not promoted; salary stays insufficient', () {
      final profile = _detector.detectSalary(
        [
          for (final m in ['2026-04', '2026-05', '2026-06'])
            credit(
              yyyymm: m,
              amountPaise: 300000,
              payeeType: PayeeType.p2pIndividual,
            ),
        ],
        now: _now,
      );

      expect(profile.confidence, SalaryConfidence.insufficientData);
    });
  });

  group('detectOtherIncome', () {
    test('surfaces P2P/self-transfer income as candidates needing confirmation', () {
      final candidates = _detector.detectOtherIncome(
        [
          for (final m in ['2026-04', '2026-05', '2026-06'])
            credit(
              yyyymm: m,
              amountPaise: 300000,
              payeeType: PayeeType.p2pIndividual,
              merchant: 'Rahul',
            ),
        ],
        now: _now,
      );

      expect(candidates, isNotEmpty);
      expect(candidates.every((c) => c.needsConfirmation), isTrue);
    });
  });

  group('resolvePrimaryAccountLast4 (D1)', () {
    test('picks the account with the most credit volume in the last 90 days', () {
      final account = _detector.resolvePrimaryAccountLast4(
        [
          credit(yyyymm: '2026-06', amountPaise: 2000000, accountLast4: '1111', day: 10),
          credit(yyyymm: '2026-07', amountPaise: 1000000, accountLast4: '1111', day: 1),
          credit(yyyymm: '2026-06', amountPaise: 1000000, accountLast4: '2222', day: 15),
        ],
        now: _now,
      );

      expect(account, '1111');
    });

    test('ignores card credits and credits older than the window', () {
      final account = _detector.resolvePrimaryAccountLast4(
        [
          credit(
            yyyymm: '2026-06',
            amountPaise: 9000000,
            accountLast4: '3333',
            instrument: PaymentInstrument.card,
          ),
          credit(yyyymm: '2025-01', amountPaise: 9000000, accountLast4: '4444'),
        ],
        now: _now,
        mostRecentBalanceAccountLast4: '5555',
      );

      expect(account, '5555');
    });

    test('falls back to the latest balance account on a tie', () {
      final account = _detector.resolvePrimaryAccountLast4(
        [
          credit(yyyymm: '2026-06', amountPaise: 1000000, accountLast4: '1111'),
          credit(yyyymm: '2026-06', amountPaise: 1000000, accountLast4: '2222'),
        ],
        now: _now,
        mostRecentBalanceAccountLast4: '2222',
      );

      expect(account, '2222');
    });
  });

  group('detectOtherIncome excludes own-money movements (M5)', () {
    test('a self-transfer and a wallet top-up are not income candidates', () {
      // All three non-salary credits would otherwise be surfaced for the user
      // to confirm. Moving your own money between your own accounts is not
      // income; the spec excludes it before any recurring-income promotion.
      final candidates = _detector.detectOtherIncome([
        credit(
          yyyymm: '2026-06',
          amountPaise: 5000000,
          merchant: 'Globex Payroll',
        ),
        credit(
          yyyymm: '2026-06',
          amountPaise: 500000,
          merchant: 'Acme Consulting',
        ),
        credit(
          yyyymm: '2026-06',
          amountPaise: 900000,
          merchant: 'Self HDFC 9012',
          payeeType: PayeeType.selfTransfer,
        ),
        credit(
          yyyymm: '2026-06',
          amountPaise: 300000,
          merchant: 'Paytm Wallet',
          payeeType: PayeeType.wallet,
        ),
      ], now: _now);

      // Globex is the month's salary pick; Acme is the only real other income.
      expect(candidates.map((c) => c.label), ['Acme Consulting']);
    });
  });

  group('kSalaryMinMonthlyPaise boundary', () {
    SalaryProfile profileAt(int amountPaise) => _detector.detectSalary([
      credit(yyyymm: '2026-04', amountPaise: amountPaise),
      credit(yyyymm: '2026-05', amountPaise: amountPaise),
      credit(yyyymm: '2026-06', amountPaise: amountPaise),
    ], now: _now);

    test('a credit exactly at the floor is still salary', () {
      final profile = profileAt(kSalaryMinMonthlyPaise);

      expect(profile.confidence, SalaryConfidence.detectedStable);
      expect(profile.basePaise, kSalaryMinMonthlyPaise);
    });

    test('one paise under the floor is never salary', () {
      expect(
        profileAt(kSalaryMinMonthlyPaise - 1).confidence,
        SalaryConfidence.insufficientData,
      );
    });
  });

  group('kVariableSalaryUpperPercentile boundary', () {
    test('rangeHighPaise is the p80, not the p75 and not the maximum', () {
      // Five clean monthly credits, evenly spaced ₹1,000 apart and spread far
      // enough to be variable rather than stable. p80 falls between the 4th and
      // 5th sample, so this distinguishes it from both neighbours.
      final profile = _detector.detectSalary([
        credit(yyyymm: '2026-01', amountPaise: 1000000),
        credit(yyyymm: '2026-02', amountPaise: 1100000),
        credit(yyyymm: '2026-03', amountPaise: 1200000),
        credit(yyyymm: '2026-04', amountPaise: 1300000),
        credit(yyyymm: '2026-05', amountPaise: 1400000),
      ], now: _now);

      expect(profile.confidence, SalaryConfidence.detectedVariable);
      // rank = 0.80 × 4 = 3.2 → 13,00,000 + 0.2 × 1,00,000.
      expect(profile.rangeHighPaise, 1320000);
      // Just inside and just outside: strictly above the 4th sample (p75) and
      // strictly below the maximum (p100).
      expect(profile.rangeHighPaise, greaterThan(1300000));
      expect(profile.rangeHighPaise, lessThan(1400000));
    });
  });

  group('named constants', () {
    test('encode the D1/D4 spec defaults', () {
      expect(kVariableSalaryFloorPercentile, 0.20);
      expect(kPrimaryAccountLookbackDays, 90);
      expect(kSalaryMinCleanCredits, 3);
    });
  });
}
