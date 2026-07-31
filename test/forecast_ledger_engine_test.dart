import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/services/forecast_ledger_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ForecastLedgerEngine', () {
    test('tracks the minimum in-month balance and shortfall date', () {
      final anchor = BalanceAnchor(
        amountPaise: 1000000,
        asOf: DateTime(2026, 8),
        accountLast4: '1234',
        source: BalanceAnchorSource.smsBankBalance,
      );
      final result = const ForecastLedgerEngine().buildMonth(
        targetMonth: DateTime(2026, 8),
        anchor: anchor,
        now: DateTime(2026, 8),
        events: [
          ForecastEvent(
            date: DateTime(2026, 8, 2),
            amountPaise: 1800000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.gmailBill,
            ownerKey: 'gmail:rent-aug',
            label: 'Rent',
            confidence: 1,
          ),
          ForecastEvent(
            date: DateTime(2026, 8, 30),
            amountPaise: 7700000,
            direction: LedgerDirection.inflow,
            source: ForecastEventSource.salary,
            ownerKey: 'salary:aug',
            label: 'Salary',
            confidence: 0.9,
          ),
        ],
      );

      expect(result.openingBalancePaise, 1000000);
      expect(result.closingBalancePaise, 6900000);
      expect(result.minimumBalancePaise, -800000);
      expect(result.minimumBalanceDate, DateTime(2026, 8, 2));
      expect(result.shortfallPaise, 800000);
      expect(result.events.map((event) => event.label), ['Rent', 'Salary']);
      expect(
        result.lines.map((line) => line.label),
        containsAll(['Opening balance', 'Rent', 'Salary']),
      );
    });

    test('rolls each month forward from the previous projected close', () {
      final anchor = BalanceAnchor(
        amountPaise: 1000000,
        asOf: DateTime(2026, 7, 31, 23, 59),
        accountLast4: '1234',
        source: BalanceAnchorSource.smsBankBalance,
      );
      final results = const ForecastLedgerEngine().buildRollingMonths(
        firstMonth: DateTime(2026, 8),
        monthCount: 2,
        anchor: anchor,
        now: DateTime(2026, 8),
        events: [
          ForecastEvent(
            date: DateTime(2026, 8, 1),
            amountPaise: 500000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.recurring,
            ownerKey: 'sip:aug',
            label: 'SIP',
            confidence: 1,
          ),
          ForecastEvent(
            date: DateTime(2026, 9, 1),
            amountPaise: 700000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.recurring,
            ownerKey: 'sip:sep',
            label: 'SIP increase',
            confidence: 1,
          ),
        ],
      );

      expect(results, hasLength(2));
      expect(results[0].openingBalancePaise, 1000000);
      expect(results[0].closingBalancePaise, 500000);
      expect(results[1].openingBalancePaise, 500000);
      expect(
        results[1].anchor.source,
        BalanceAnchorSource.projectedCarryForward,
      );
      expect(results[1].closingBalancePaise, -200000);
      expect(results[1].shortfallPaise, 200000);
    });

    test(
      'carries a projected negative close into the next opening balance',
      () {
        final results = const ForecastLedgerEngine().buildRollingMonths(
          firstMonth: DateTime(2026, 8),
          monthCount: 2,
          anchor: BalanceAnchor(
            amountPaise: 100000,
            asOf: DateTime(2026, 7, 31, 23, 59),
            source: BalanceAnchorSource.manualUserEntry,
          ),
          now: DateTime(2026, 8),
          events: [
            ForecastEvent(
              date: DateTime(2026, 8, 1),
              amountPaise: 300000,
              direction: LedgerDirection.outflow,
              source: ForecastEventSource.manual,
              ownerKey: 'manual:aug-gap',
              label: 'August gap',
              confidence: 1,
            ),
          ],
        );

        expect(results[0].closingBalancePaise, -200000);
        expect(results[1].openingBalancePaise, -200000);
      },
    );

    test('does not replay current-month events already inside the anchor', () {
      final result = const ForecastLedgerEngine().buildMonth(
        targetMonth: DateTime(2026, 8),
        anchor: BalanceAnchor(
          amountPaise: 1000000,
          asOf: DateTime(2026, 8, 10),
          source: BalanceAnchorSource.smsBankBalance,
        ),
        now: DateTime(2026, 8, 10),
        events: [
          ForecastEvent(
            date: DateTime(2026, 8, 5),
            amountPaise: 300000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.currentActual,
            ownerKey: 'actual:electricity',
            label: 'Electricity already paid',
            confidence: 1,
          ),
          ForecastEvent(
            date: DateTime(2026, 8, 12),
            amountPaise: 100000,
            direction: LedgerDirection.outflow,
            source: ForecastEventSource.gmailBill,
            ownerKey: 'gmail:mobile',
            label: 'Mobile bill',
            confidence: 1,
          ),
        ],
      );

      expect(result.closingBalancePaise, 900000);
      expect(result.events.map((event) => event.label), ['Mobile bill']);
      expect(
        result.lines
            .singleWhere((line) => line.label == 'Electricity already paid')
            .status,
        ForecastLineStatus.alreadyInAnchor,
      );
    });

    test('marks stale anchors as provisional coverage', () {
      final result = const ForecastLedgerEngine().buildMonth(
        targetMonth: DateTime(2026, 8),
        anchor: BalanceAnchor(
          amountPaise: 1000000,
          asOf: DateTime(2026, 8, 1),
          source: BalanceAnchorSource.smsBankBalance,
        ),
        now: DateTime(2026, 8, 7),
        events: const [],
      );

      expect(result.anchorFreshness, AnchorFreshness.stale);
      expect(result.coverageLines.single.reason, CoverageReason.staleAnchor);
      expect(result.coverageLines.single.action, CoverageAction.confirmBalance);
    });

    test(
      'applies same-date outflows before inflows for minimum-balance safety',
      () {
        final result = const ForecastLedgerEngine().buildMonth(
          targetMonth: DateTime(2026, 8),
          anchor: BalanceAnchor(
            amountPaise: 100000,
            asOf: DateTime(2026, 8),
            source: BalanceAnchorSource.manualUserEntry,
          ),
          now: DateTime(2026, 8),
          events: [
            ForecastEvent(
              date: DateTime(2026, 8, 5),
              amountPaise: 200000,
              direction: LedgerDirection.inflow,
              source: ForecastEventSource.salary,
              ownerKey: 'salary:aug',
              label: 'Salary',
              confidence: 1,
            ),
            ForecastEvent(
              date: DateTime(2026, 8, 5),
              amountPaise: 150000,
              direction: LedgerDirection.outflow,
              source: ForecastEventSource.recurring,
              ownerKey: 'emi:aug',
              label: 'EMI',
              confidence: 1,
            ),
          ],
        );

        expect(result.minimumBalancePaise, -50000);
        expect(result.shortfallPaise, 50000);
        expect(result.events.map((event) => event.label), ['EMI', 'Salary']);
      },
    );

    test('decays projected carry-forward opening confidence for far months', () {
      final anchor = BalanceAnchor(
        amountPaise: 1000000,
        asOf: DateTime(2026, 8),
        accountLast4: '1234',
        source: BalanceAnchorSource.smsBankBalance,
      );
      final results = const ForecastLedgerEngine().buildRollingMonths(
        firstMonth: DateTime(2026, 8),
        monthCount: 4,
        anchor: anchor,
        now: DateTime(2026, 8),
        events: const [],
      );

      double openingConfidence(ForecastMonthResult r) => r.lines
          .firstWhere((line) => line.status == ForecastLineStatus.opening)
          .confidence;

      // Month 0 uses the real anchor's freshness (fresh => 1.0).
      expect(results[0].anchor.source, BalanceAnchorSource.smsBankBalance);
      expect(openingConfidence(results[0]), 1.0);

      // Projected months decay strictly the further out they are.
      expect(
        results[1].anchor.source,
        BalanceAnchorSource.projectedCarryForward,
      );
      final c1 = openingConfidence(results[1]);
      final c2 = openingConfidence(results[2]);
      final c3 = openingConfidence(results[3]);
      expect(c1, greaterThan(c2));
      expect(c2, greaterThan(c3));
      expect(c3, greaterThanOrEqualTo(0.2));

      // A projection is not a stale SMS: no stale-anchor coverage line.
      for (var i = 1; i < 4; i++) {
        expect(
          results[i].coverageLines.where(
            (line) => line.reason == CoverageReason.staleAnchor,
          ),
          isEmpty,
        );
      }
    });

    test('floors deep projected carry-forward confidence at 0.2', () {
      final results = const ForecastLedgerEngine().buildRollingMonths(
        firstMonth: DateTime(2026, 8),
        monthCount: 12,
        anchor: BalanceAnchor(
          amountPaise: 1000000,
          asOf: DateTime(2026, 8),
          accountLast4: '1234',
          source: BalanceAnchorSource.smsBankBalance,
        ),
        now: DateTime(2026, 8),
        events: const [],
      );

      final deepest = results.last.lines
          .firstWhere((line) => line.status == ForecastLineStatus.opening)
          .confidence;
      expect(deepest, 0.2);
    });
  });
}
