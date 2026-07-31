import 'package:flutter_test/flutter_test.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/reserve_planner.dart';

void main() {
  group('ReservePlanner', () {
    test('spreads an unfunded annual premium over remaining opportunities', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 6000000, dueDate: DateTime(2027, 2, 12)),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      final schedule = result.schedules.single;
      expect(schedule.contributions.map((c) => c.date), [
        DateTime(2026, 7, 22),
        DateTime(2026, 8, 1),
        DateTime(2026, 9, 1),
        DateTime(2026, 10, 1),
        DateTime(2026, 11, 1),
        DateTime(2026, 12, 1),
        DateTime(2027, 1, 1),
        DateTime(2027, 2, 1),
      ]);
      expect(schedule.nextContributionPaise, 750000);
      expect(
        schedule.contributions.fold<int>(0, (sum, c) => sum + c.amountPaise),
        greaterThanOrEqualTo(6000000),
      );
    });

    test('missed funding increases the remaining monthly contribution', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(
                amountPaise: 6000000,
                fundedPaise: 750000,
                dueDate: DateTime(2027, 2, 12),
              ),
            ],
            now: DateTime(2026, 10, 2),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.nextContributionPaise, 1050000);
    });

    test('one opportunity requests the full unfunded amount', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(amountPaise: 4700000, dueDate: DateTime(2026, 8, 1)),
            ],
            now: DateTime(2026, 7, 31),
            expectedSalaryDay: null,
          )
          .schedules
          .single;
      expect(schedule.nextContributionPaise, 4700000);
    });

    test(
      'smaller future obligation is offered for explicit reserve enablement',
      () {
        final result = const ReservePlanner().build(
          obligations: [
            _lic(amountPaise: 800000, dueDate: DateTime(2026, 12, 1)),
          ],
          now: DateTime(2026, 7, 22),
          expectedSalaryDay: 1,
        );
        expect(result.schedules, isEmpty);
        expect(result.availableToEnable.single.dedupeKey, 'lic:annual');
      },
    );

    test('fully funded obligation has no contributions', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(
                amountPaise: 2000000,
                fundedPaise: 2000000,
                dueDate: DateTime(2027, 1, 15),
              ),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.isFullyFunded, true);
      expect(schedule.contributions, isEmpty);
      expect(schedule.nextContributionPaise, 0);
    });

    test('excludes paid obligations', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(
            amountPaise: 2000000,
            dueDate: DateTime(2027, 1, 15),
            paymentStatus: ReconciliationPaymentStatus.paid,
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, isEmpty);
      expect(result.availableToEnable, isEmpty);
    });

    test('excludes dismissed obligations', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(
            amountPaise: 2000000,
            dueDate: DateTime(2027, 1, 15),
            reviewStatus: ObligationReviewStatus.dismissed,
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, isEmpty);
      expect(result.availableToEnable, isEmpty);
    });

    test('excludes monthly recurrence obligations', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(
            amountPaise: 2000000,
            dueDate: DateTime(2027, 1, 15),
            recurrence: ReconciliationRecurrence.monthly,
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, isEmpty);
      expect(result.availableToEnable, isEmpty);
    });

    test('explicit enable below Rs 10,000 creates schedule', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(
            amountPaise: 800000,
            dueDate: DateTime(2026, 12, 1),
            reserveEnabled: true,
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, hasLength(1));
      expect(result.availableToEnable, isEmpty);
    });

    test('high-confidence obligation auto-eligible for reserve', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(
            amountPaise: 2000000,
            dueDate: DateTime(2027, 1, 15),
            confidence: 0.85,
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, hasLength(1));
    });

    test('handles December-to-January boundary', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 3000000, dueDate: DateTime(2027, 1, 15)),
        ],
        now: DateTime(2026, 12, 15),
        expectedSalaryDay: 1,
      );
      final schedule = result.schedules.single;
      expect(
        schedule.contributions.map((c) => c.date),
        containsAll([DateTime(2026, 12, 15), DateTime(2027, 1, 1)]),
      );
    });

    test('handles leap day in due date', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 2000000, dueDate: DateTime(2028, 2, 29)),
        ],
        now: DateTime(2028, 1, 15),
        expectedSalaryDay: 1,
      );
      final schedule = result.schedules.single;
      expect(schedule.dueDate, DateTime(2028, 2, 29));
      expect(schedule.contributions.any((c) => c.date.month == 2), true);
    });

    test('salary after due date uses fallback', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 2000000, dueDate: DateTime(2026, 8, 5)),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 10,
      );
      final schedule = result.schedules.single;
      // Should have immediate opportunity and no monthly opportunity since salary is after due date
      expect(schedule.contributions.length, 1);
      expect(schedule.contributions.first.date, DateTime(2026, 7, 22));
    });

    test('null salary day creates deterministic calendar fallback dates', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(amountPaise: 2000000, dueDate: DateTime(2026, 12, 15)),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: null,
          )
          .schedules
          .single;
      // Should have immediate plus one fallback date per remaining month (day 1)
      expect(schedule.contributions.map((c) => c.date), [
        DateTime(2026, 7, 22), // immediate
        DateTime(2026, 8, 1), // Aug 1
        DateTime(2026, 9, 1), // Sep 1
        DateTime(2026, 10, 1), // Oct 1
        DateTime(2026, 11, 1), // Nov 1
        DateTime(2026, 12, 1), // Dec 1 (before due date)
      ]);
    });

    test('deterministic when salary day is null', () {
      final result1 = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 2000000, dueDate: DateTime(2026, 12, 15)),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: null,
      );
      final result2 = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 2000000, dueDate: DateTime(2026, 12, 15)),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: null,
      );
      expect(
        result1.schedules.single.contributions.map((c) => c.date).toList(),
        result2.schedules.single.contributions.map((c) => c.date).toList(),
      );
    });

    test('whole-rupee ceiling on monthly contributions', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(amountPaise: 6543210, dueDate: DateTime(2027, 2, 12)),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      // Each contribution should be rounded up to whole rupees
      for (final contribution in schedule.contributions) {
        expect(contribution.amountPaise % 100, 0);
      }
    });

    test('uses outstanding amount when present', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(
                amountPaise: 2000000,
                amountPaidPaise: 500000,
                outstandingPaise: 1200000,
                dueDate: DateTime(2027, 1, 15),
              ),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.targetPaise, 1200000);
    });

    test('uses amountPaise minus amountPaidPaise when no outstanding', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(
                amountPaise: 2000000,
                amountPaidPaise: 500000,
                dueDate: DateTime(2027, 1, 15),
              ),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.targetPaise, 1500000);
    });

    test('marks overdue when due date is in the past', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(amountPaise: 2000000, dueDate: DateTime(2026, 7, 1)),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.isOverdue, true);
    });

    test('contributionInMonth sums contributions in a month', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 6000000, dueDate: DateTime(2027, 2, 12)),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      final augustTotal = result.contributionInMonth(DateTime(2026, 8, 1));
      expect(augustTotal, 750000);
    });

    test('reserve progress distinct from payment progress', () {
      final schedule = const ReservePlanner()
          .build(
            obligations: [
              _lic(
                amountPaise: 2000000,
                amountPaidPaise: 500000,
                fundedPaise: 800000,
                dueDate: DateTime(2027, 1, 15),
              ),
            ],
            now: DateTime(2026, 7, 22),
            expectedSalaryDay: 1,
          )
          .schedules
          .single;
      expect(schedule.fundedPaise, 800000);
      expect(schedule.targetPaise, 1500000);
      expect(schedule.remainingPaise, 700000);
    });

    test('multiple obligations create multiple schedules', () {
      final result = const ReservePlanner().build(
        obligations: [
          _lic(amountPaise: 2000000, dueDate: DateTime(2027, 1, 15)),
          _lic(
            amountPaise: 3000000,
            dueDate: DateTime(2027, 6, 20),
            dedupeKey: 'lic:2',
          ),
        ],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, hasLength(2));
    });

    test('empty obligations returns empty plan', () {
      final result = const ReservePlanner().build(
        obligations: [],
        now: DateTime(2026, 7, 22),
        expectedSalaryDay: 1,
      );
      expect(result.schedules, isEmpty);
      expect(result.availableToEnable, isEmpty);
    });
  });
}

ObligationRecord _lic({
  required int amountPaise,
  required DateTime dueDate,
  int fundedPaise = 0,
  int? amountPaidPaise,
  int? outstandingPaise,
  bool reserveEnabled = false,
  ReconciliationPaymentStatus paymentStatus =
      ReconciliationPaymentStatus.unpaid,
  ObligationReviewStatus reviewStatus = ObligationReviewStatus.confirmed,
  ReconciliationRecurrence recurrence = ReconciliationRecurrence.annual,
  double confidence = 0.95,
  String dedupeKey = 'lic:annual',
}) {
  return ObligationRecord(
    dedupeKey: dedupeKey,
    merchant: 'LIC',
    merchantNorm: 'lic',
    categoryKey: 'insurance',
    sourceType: ObligationSourceType.gmail,
    amountPaise: amountPaise,
    amountStatus: AmountStatus.known,
    recurrence: recurrence,
    dueDate: dueDate,
    paymentAccountScope: AccountScope.primary,
    paymentStatus: paymentStatus,
    nextExpectedSource: NextExpectedSource.explicitDueDate,
    payeeType: PayeeType.merchant,
    userCadenceStatus: UserCadenceStatus.algorithmDetected,
    confidence: confidence,
    reviewStatus: reviewStatus,
    reserveEnabled: reserveEnabled,
    reserveFundedPaise: fundedPaise,
    amountPaidPaise: amountPaidPaise,
    outstandingPaise: outstandingPaise,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}
