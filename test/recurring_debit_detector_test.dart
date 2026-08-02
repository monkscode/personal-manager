import 'package:expense_insight/data/models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/recurring_debit_detector.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn debit({
  required DateTime date,
  required int amountPaise,
  String merchant = 'ICICI Pru MF',
  String categoryKey = 'investment',
  TxnType type = TxnType.upi,
  String? smsId,
}) => ParsedTxn(
  smsId: smsId ?? 'sms:${date.toIso8601String()}',
  sender: 'VM-ICICIB',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: type,
  amountPaise: amountPaise,
  txnDate: date,
  merchant: merchant,
  payeeType: PayeeType.merchant,
  categoryKey: categoryKey,
  confidence: 0.95,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h',
  scanBatchId: 'b',
);

List<ParsedTxn> monthly({
  required int count,
  required int amountPaise,
  int startYear = 2026,
  int startMonth = 1,
  int day = 10,
  String merchant = 'ICICI Pru MF',
}) => [
  for (var i = 0; i < count; i++)
    debit(
      date: DateTime(startYear, startMonth + i, day),
      amountPaise: amountPaise,
      merchant: merchant,
      smsId: 'sms:$i',
    ),
];

final _now = DateTime(2026, 7, 1);

void main() {
  const detector = RecurringDebitDetector();

  List<RecurringCommitment> detect(
    List<ParsedTxn> history, {
    List<ContribPlan> plans = const [],
  }) => detector.detect(history, configuredPlans: plans, now: _now);

  List<ReviewCandidate> candidates(
    List<ParsedTxn> history, {
    List<ContribPlan> plans = const [],
  }) => detector.possibleRecurring(history, configuredPlans: plans, now: _now);

  group('locking cadences', () {
    test('a true monthly SIP locks as a monthly commitment', () {
      final result = detect(monthly(count: 4, amountPaise: 500000));

      expect(result, hasLength(1));
      final c = result.single;
      expect(c.cadence, RecurringCadence.monthly);
      expect(c.amountPaise, 500000);
      expect(c.occurrences, 4);
      expect(c.merchantNorm, 'icici pru mf');
      expect(c.categoryKey, 'investment');
      expect(c.confidence, greaterThanOrEqualTo(kRecurringBaseConfidence));
      // History ends 10 April and `now` is 1 July, so the next occurrence is
      // 10 July. The old assertion here was 10 May — two months in the past,
      // which the engine filed as a futureEarmark and excluded from the ledger.
      expect(c.nextExpected, DateTime(2026, 7, 10));
    });

    test('nextExpected is never in the past, for any cadence', () {
      for (final history in [
        monthly(count: 4, amountPaise: 500000),
        [
          debit(date: DateTime(2025, 1, 15), amountPaise: 300000, smsId: 'q1'),
          debit(date: DateTime(2025, 4, 15), amountPaise: 300000, smsId: 'q2'),
          debit(date: DateTime(2025, 7, 15), amountPaise: 300000, smsId: 'q3'),
        ],
      ]) {
        for (final commitment in detect(history)) {
          expect(commitment.nextExpected.isBefore(_now), isFalse);
        }
      }
    });

    test('now genuinely drives the answer', () {
      final history = monthly(count: 4, amountPaise: 500000);
      final early = detector
          .detect(history, configuredPlans: const [], now: DateTime(2026, 5, 1))
          .single;
      final late = detector
          .detect(history, configuredPlans: const [], now: DateTime(2026, 9, 1))
          .single;
      expect(early.nextExpected, DateTime(2026, 5, 10));
      expect(late.nextExpected, DateTime(2026, 9, 10));
    });

    test('a month-end cadence rolls forward without drifting off the 31st', () {
      final history = [
        debit(date: DateTime(2025, 10, 31), amountPaise: 200000, smsId: 'm1'),
        debit(date: DateTime(2025, 11, 30), amountPaise: 200000, smsId: 'm2'),
        debit(date: DateTime(2025, 12, 31), amountPaise: 200000, smsId: 'm3'),
        debit(date: DateTime(2026, 1, 31), amountPaise: 200000, smsId: 'm4'),
      ];
      final commitment = detector
          .detect(history, configuredPlans: const [], now: DateTime(2026, 3, 15))
          .single;
      // Advancing from the original day each time, not from the clamped result:
      // 31 Jan + 2 months is 31 March, not 28 March.
      expect(commitment.nextExpected, DateTime(2026, 3, 31));
    });

    test('a late-night to early-morning monthly pair is still monthly', () {
      // 27 days and 11 hours truncates to 27 with `inDays`, falling outside the
      // (28, 33) window and unlocking a real commitment.
      final result = detect([
        debit(
          date: DateTime(2026, 1, 30, 22, 0),
          amountPaise: 500000,
          smsId: 't1',
        ),
        debit(
          date: DateTime(2026, 2, 27, 9, 0),
          amountPaise: 500000,
          smsId: 't2',
        ),
        debit(
          date: DateTime(2026, 3, 30, 14, 0),
          amountPaise: 500000,
          smsId: 't3',
        ),
      ]);

      expect(result, hasLength(1));
      expect(result.single.cadence, RecurringCadence.monthly);
    });

    test('the time of day does not change the cadence', () {
      List<RecurringCommitment> at(int hour) => detect([
        for (var i = 0; i < 4; i++)
          debit(
            date: DateTime(2026, 1 + i, 10, hour),
            amountPaise: 500000,
            smsId: 'h$i',
          ),
      ]);

      expect(at(0).single.cadence, at(23).single.cadence);
      expect(at(0), hasLength(at(23).length));
    });

    test('quarterly cadence locks', () {
      final result = detect([
        debit(date: DateTime(2025, 1, 15), amountPaise: 300000, smsId: 'a'),
        debit(date: DateTime(2025, 4, 15), amountPaise: 300000, smsId: 'b'),
        debit(date: DateTime(2025, 7, 15), amountPaise: 300000, smsId: 'c'),
      ]);

      expect(result.single.cadence, RecurringCadence.quarterly);
      // Rolled forward past `now` (1 Jul 2026): Oct 25, Jan 26, Apr 26, Jul 26.
      expect(result.single.nextExpected, DateTime(2026, 7, 15));
    });

    test('annual cadence locks', () {
      final result = detect([
        debit(date: DateTime(2023, 6, 10), amountPaise: 1200000, smsId: 'a'),
        debit(date: DateTime(2024, 6, 10), amountPaise: 1200000, smsId: 'b'),
        debit(date: DateTime(2025, 6, 10), amountPaise: 1200000, smsId: 'c'),
      ]);

      expect(result.single.cadence, RecurringCadence.annual);
      // 10 Jun 2026 is already behind `now`, so the next one is a year later.
      expect(result.single.nextExpected, DateTime(2027, 6, 10));
    });

    test('a month-end monthly cadence advances to the last day, not overflow', () {
      final result = detector.detect(
        [
          debit(date: DateTime(2025, 11, 30), amountPaise: 300000, smsId: 'a'),
          debit(date: DateTime(2025, 12, 31), amountPaise: 300000, smsId: 'b'),
          debit(date: DateTime(2026, 1, 31), amountPaise: 300000, smsId: 'c'),
        ],
        configuredPlans: const [],
        // Read from mid-February so the first future occurrence is the one the
        // clamp has to get right.
        now: DateTime(2026, 2, 5),
      );

      expect(result.single.cadence, RecurringCadence.monthly);
      // 31 Jan + 1 month must be 28 Feb, not 3 March (which skips February).
      expect(result.single.nextExpected, DateTime(2026, 2, 28));
    });

    test('a month-end monthly cadence lands on 29 Feb in a leap year', () {
      final result = detect([
        debit(date: DateTime(2027, 11, 30), amountPaise: 300000, smsId: 'a'),
        debit(date: DateTime(2027, 12, 31), amountPaise: 300000, smsId: 'b'),
        debit(date: DateTime(2028, 1, 31), amountPaise: 300000, smsId: 'c'),
      ]);

      expect(result.single.cadence, RecurringCadence.monthly);
      expect(result.single.nextExpected, DateTime(2028, 2, 29));
    });
  });

  group('amount jitter tolerance', () {
    test('amounts within ±10%/₹50 still lock', () {
      final result = detect([
        debit(date: DateTime(2026, 1, 10), amountPaise: 100000, smsId: 'a'),
        debit(date: DateTime(2026, 2, 10), amountPaise: 105000, smsId: 'b'),
        debit(date: DateTime(2026, 3, 10), amountPaise: 98000, smsId: 'c'),
      ]);

      expect(result, hasLength(1));
      expect(result.single.cadence, RecurringCadence.monthly);
    });

    test('amounts beyond tolerance do not lock and surface as a candidate', () {
      final history = [
        debit(date: DateTime(2026, 1, 10), amountPaise: 100000, smsId: 'a'),
        debit(date: DateTime(2026, 2, 10), amountPaise: 100000, smsId: 'b'),
        debit(date: DateTime(2026, 3, 10), amountPaise: 150000, smsId: 'c'),
      ];

      expect(detect(history), isEmpty);
      expect(
        candidates(history).single.kind,
        ReviewCandidateKind.irregularRepeatingDebit,
      );
    });
  });

  group('false-cadence negatives', () {
    test('a single one-off does not lock and yields no candidate', () {
      final history = [
        debit(date: DateTime(2026, 3, 10), amountPaise: 100000),
      ];
      expect(detect(history), isEmpty);
      expect(candidates(history), isEmpty);
    });

    test('fewer than three occurrences does not lock', () {
      final history = monthly(count: 2, amountPaise: 100000);
      expect(detect(history), isEmpty);
      expect(
        candidates(history).single.kind,
        ReviewCandidateKind.possibleRecurringDebit,
      );
    });

    test('irregular gaps with 3+ occurrences do not lock', () {
      final history = [
        debit(date: DateTime(2026, 1, 10), amountPaise: 100000, smsId: 'a'),
        debit(date: DateTime(2026, 1, 25), amountPaise: 100000, smsId: 'b'),
        debit(date: DateTime(2026, 5, 2), amountPaise: 100000, smsId: 'c'),
      ];
      expect(detect(history), isEmpty);
      expect(
        candidates(history).single.kind,
        ReviewCandidateKind.irregularRepeatingDebit,
      );
    });
  });

  group('review candidates', () {
    test('carry the amount range and latest dates', () {
      final history = [
        debit(date: DateTime(2026, 1, 10), amountPaise: 90000, smsId: 'a'),
        debit(date: DateTime(2026, 2, 10), amountPaise: 130000, smsId: 'b'),
        debit(date: DateTime(2026, 2, 25), amountPaise: 110000, smsId: 'c'),
      ];
      final candidate = candidates(history).single;
      expect(candidate.minAmountPaise, 90000);
      expect(candidate.maxAmountPaise, 130000);
      expect(candidate.latestDates, isNotEmpty);
    });
  });

  group('reinforcement by configured contributions', () {
    test('a configured plan locks a matching 2-occurrence group once', () {
      final history = monthly(count: 2, amountPaise: 500000);
      final plans = [
        const ContribPlan(
          enabled: true,
          amount: '5000',
          frequency: 'monthly',
          month: 'Feb',
        ),
      ];

      final result = detect(history, plans: plans);

      expect(result, hasLength(1));
      expect(result.single.matchedConfiguredPlan, isTrue);
      expect(result.single.configuredPlanKey, isNotNull);
      expect(result.single.cadence, RecurringCadence.monthly);
      // Not double-counted: the same group is no longer a bare candidate.
      expect(candidates(history, plans: plans), isEmpty);
    });

    test('a matching plan raises a locked group confidence', () {
      final history = monthly(count: 3, amountPaise: 500000);
      final plans = [
        const ContribPlan(
          enabled: true,
          amount: '5000',
          frequency: 'monthly',
          month: 'Feb',
        ),
      ];

      final base = detect(history).single.confidence;
      final reinforced = detect(history, plans: plans).single;

      expect(reinforced.confidence, greaterThan(base));
      expect(reinforced.matchedConfiguredPlan, isTrue);
    });

    test('a disabled plan does not reinforce', () {
      final history = monthly(count: 2, amountPaise: 500000);
      final plans = [
        const ContribPlan(
          enabled: false,
          amount: '5000',
          frequency: 'monthly',
          month: 'Feb',
        ),
      ];
      expect(detect(history, plans: plans), isEmpty);
    });
  });

  group('kRecurringDayOfMonthVarianceDays boundary', () {
    // Same amount, same merchant, monthly gaps all inside (28, 33) — the only
    // variable is how far the day of month drifts across the three debits.
    List<RecurringCommitment> detectOnDays(List<int> days) => detect([
      for (var i = 0; i < days.length; i++)
        debit(
          date: DateTime(2026, 1 + i, days[i]),
          amountPaise: 500000,
          smsId: 'sms:$i',
        ),
    ]);

    test('a drift of exactly the variance window still locks', () {
      // circularDaySpread([10, 12, 14]) == 4.
      final result = detectOnDays([10, 12, 14]);

      expect(result, hasLength(1));
      expect(result.single.cadence, RecurringCadence.monthly);
    });

    test('one day wider than the window does not lock', () {
      // circularDaySpread([10, 12, 15]) == 5.
      expect(detectOnDays([10, 12, 15]), isEmpty);
    });
  });

  group('named constants', () {
    test('encode the spec §3 thresholds', () {
      expect(kRecurringMinOccurrences, 3);
      expect(kRecurringConfiguredMatchMinOccurrences, 2);
      expect(kRecurringDayOfMonthVarianceDays, 4);
      expect(kRecurringAmountJitterRatio, 0.10);
      expect(kRecurringAmountJitterFloorPaise, 5000);
    });
  });
}
