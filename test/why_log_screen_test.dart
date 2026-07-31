import 'package:expense_insight/core/theme.dart';
import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/features/app/why_log_screen.dart';
import 'package:expense_insight/services/reserve_planner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ForecastLine _line({
  required String label,
  required int amountPaise,
  required ForecastEventSource source,
  required ForecastLineStatus status,
  DateTime? date,
  double confidence = 0.9,
  String? ownerKey,
}) => ForecastLine(
  label: label,
  amountPaise: amountPaise,
  source: source,
  status: status,
  date: date,
  confidence: confidence,
  ownerKey: ownerKey ?? label.toLowerCase(),
);

Future<void> _pump(
  WidgetTester tester, {
  required List<ForecastLine> lines,
  List<ForecastLine> earmarks = const [],
  List<ForecastCoverageLine> coverage = const [],
  List<ReserveSchedule> reserveSchedules = const [],
  List<ForecastLine> riskLines = const [],
  void Function(ForecastLine)? onTapLine,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(AppPalette.dark),
      home: WhyLogScreen(
        lines: lines,
        forwardEarmarks: earmarks,
        coverageLines: coverage,
        reserveSchedules: reserveSchedules,
        riskLines: riskLines,
        monthLabel: 'August',
        onTapLine: onTapLine,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('WhyLogScreen', () {
    testWidgets('renders each spec line type in its group', (tester) async {
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Netflix',
            amountPaise: 64900,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 12),
          ),
          _line(
            label: 'Electricity',
            amountPaise: 210000,
            source: ForecastEventSource.gmailBill,
            status: ForecastLineStatus.overdue,
            date: DateTime(2026, 8, 3),
          ),
          _line(
            label: 'Dining',
            amountPaise: 500000,
            source: ForecastEventSource.seasonal,
            status: ForecastLineStatus.estimated,
            confidence: 0.8,
            date: DateTime(2026, 8, 28),
          ),
          _line(
            label: 'Rent',
            amountPaise: 1800000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.paid,
            date: DateTime(2026, 8, 5),
          ),
          _line(
            label: 'Old SIP',
            amountPaise: 300000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.alreadyInAnchor,
            date: DateTime(2026, 8, 1),
          ),
        ],
      );

      // Group headers.
      expect(find.text('RECURRING'), findsOneWidget);
      expect(find.text('BILLS'), findsOneWidget);
      expect(find.text('SEASONAL ESTIMATES'), findsOneWidget);
      expect(find.text('ALREADY IN YOUR BALANCE'), findsOneWidget);

      // Line labels.
      expect(find.text('Netflix'), findsOneWidget);
      expect(find.text('Electricity'), findsOneWidget);
      expect(find.text('Rent'), findsOneWidget);

      // Statuses render.
      expect(find.textContaining('Unpaid'), findsWidgets);
      expect(find.textContaining('Overdue'), findsWidgets);
      expect(find.textContaining('Paid'), findsWidgets);
      // Seasonal confidence shows.
      expect(find.textContaining('est · 80%'), findsOneWidget);
    });

    testWidgets('a coverage line shows amount, reason and action', (
      tester,
    ) async {
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Rent',
            amountPaise: 1800000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 5),
          ),
        ],
        coverage: const [
          ForecastCoverageLine(
            label: 'Cash withdrawals',
            amountPaise: 1200000,
            reason: CoverageReason.untrackedCash,
            action: CoverageAction.review,
            confidence: 0.5,
          ),
        ],
      );

      expect(find.text('Needs your attention'.toUpperCase()), findsOneWidget);
      expect(find.text('Cash withdrawals'), findsOneWidget);
      // Amount.
      expect(find.text('₹12,000'), findsOneWidget);
      // Reason + action.
      expect(find.textContaining("Cash spending we can't see"), findsOneWidget);
      expect(find.textContaining('Review'), findsWidgets);
    });

    testWidgets(
      'a forward earmark renders with its due month, distinct from a dated shortfall',
      (tester) async {
        await _pump(
          tester,
          lines: [
            _line(
              label: 'Rent',
              amountPaise: 1800000,
              source: ForecastEventSource.recurring,
              status: ForecastLineStatus.unpaid,
              date: DateTime(2026, 8, 5),
            ),
          ],
          earmarks: [
            _line(
              label: 'LIC premium',
              amountPaise: 4700000,
              source: ForecastEventSource.gmailBill,
              status: ForecastLineStatus.projected,
              date: DateTime(2027, 2, 14),
              ownerKey: 'lic',
            ),
          ],
        );

        expect(find.text('COMING UP LATER'), findsOneWidget);
        expect(find.text('LIC premium'), findsOneWidget);
        // Due month appears.
        expect(find.textContaining('February'), findsOneWidget);
        // Visually distinct: the earmark tile carries its own key, the hard dated
        // line uses the standard line key.
        expect(find.byKey(const ValueKey('why-earmark-lic')), findsOneWidget);
        expect(find.byKey(const ValueKey('why-line-rent')), findsOneWidget);
      },
    );

    testWidgets('each line is tappable to its source', (tester) async {
      ForecastLine? tapped;
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Netflix',
            amountPaise: 64900,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 12),
            ownerKey: 'netflix',
          ),
        ],
        onTapLine: (l) => tapped = l,
      );

      await tester.tap(find.byKey(const ValueKey('why-line-netflix')));
      await tester.pump();
      expect(tapped, isNotNull);
      expect(tapped!.label, 'Netflix');
    });
  });

  group('WhyLogScreen reserve and risk sections', () {
    testWidgets(
      'reserve schedules render with due month, target, funded, remaining',
      (tester) async {
        await _pump(
          tester,
          lines: [
            _line(
              label: 'Rent',
              amountPaise: 1800000,
              source: ForecastEventSource.recurring,
              status: ForecastLineStatus.unpaid,
              date: DateTime(2026, 8, 5),
            ),
          ],
          reserveSchedules: [
            ReserveSchedule(
              dedupeKey: 'lic',
              label: 'LIC premium',
              dueDate: DateTime(2027, 2, 14),
              targetPaise: 4700000,
              fundedPaise: 1200000,
              remainingPaise: 3500000,
              contributions: const [],
              isFullyFunded: false,
              isOverdue: false,
            ),
          ],
        );

        expect(find.text('SET ASIDE'), findsOneWidget);
        expect(find.text('LIC premium'), findsWidgets);
        expect(find.textContaining('February'), findsOneWidget);
        expect(find.textContaining('Target'), findsOneWidget);
        expect(find.textContaining('Funded'), findsOneWidget);
        expect(find.textContaining('Remaining'), findsOneWidget);
      },
    );

    testWidgets('risk lines render with amount, date, confidence, status', (
      tester,
    ) async {
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Rent',
            amountPaise: 1800000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 5),
          ),
        ],
        riskLines: [
          _line(
            label: 'Car service',
            amountPaise: 500000,
            source: ForecastEventSource.seasonal,
            status: ForecastLineStatus.review,
            date: DateTime(2026, 8, 20),
            confidence: 0.4,
            ownerKey: 'car-service',
          ),
        ],
      );

      expect(find.text('UNCONFIRMED RISK'), findsOneWidget);
      expect(find.text('Car service'), findsWidgets);
      expect(find.textContaining('40% confidence'), findsOneWidget);
      expect(find.textContaining('Review'), findsOneWidget);
      expect(find.textContaining('20 Aug'), findsOneWidget);
    });

    testWidgets('reserve and risk appear before coverage', (tester) async {
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Rent',
            amountPaise: 1800000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 5),
          ),
        ],
        reserveSchedules: [
          ReserveSchedule(
            dedupeKey: 'lic',
            label: 'LIC premium',
            dueDate: DateTime(2027, 2, 14),
            targetPaise: 4700000,
            fundedPaise: 1200000,
            remainingPaise: 3500000,
            contributions: const [],
            isFullyFunded: false,
            isOverdue: false,
          ),
        ],
        riskLines: [
          _line(
            label: 'Car service',
            amountPaise: 500000,
            source: ForecastEventSource.seasonal,
            status: ForecastLineStatus.review,
            date: DateTime(2026, 8, 20),
            confidence: 0.4,
            ownerKey: 'car-service',
          ),
        ],
        coverage: const [
          ForecastCoverageLine(
            label: 'Cash withdrawals',
            amountPaise: 1200000,
            reason: CoverageReason.untrackedCash,
            action: CoverageAction.review,
            confidence: 0.5,
          ),
        ],
      );

      // All three sections present.
      expect(find.text('SET ASIDE'), findsOneWidget);
      expect(find.text('UNCONFIRMED RISK'), findsOneWidget);
      expect(find.text('NEEDS YOUR ATTENTION'), findsOneWidget);

      // Reserve is above risk, both above coverage.
      final reserveY = tester.getTopLeft(find.text('SET ASIDE')).dy;
      final riskY = tester.getTopLeft(find.text('UNCONFIRMED RISK')).dy;
      final coverageY = tester.getTopLeft(find.text('NEEDS YOUR ATTENTION')).dy;
      expect(reserveY, lessThan(riskY));
      expect(riskY, lessThan(coverageY));
    });

    testWidgets('empty reserves and risks do not render sections', (
      tester,
    ) async {
      await _pump(
        tester,
        lines: [
          _line(
            label: 'Rent',
            amountPaise: 1800000,
            source: ForecastEventSource.recurring,
            status: ForecastLineStatus.unpaid,
            date: DateTime(2026, 8, 5),
          ),
        ],
      );

      expect(find.text('SET ASIDE'), findsNothing);
      expect(find.text('UNCONFIRMED RISK'), findsNothing);
    });

    testWidgets('reserve metrics do not overflow at 320px + textScale 1.3', (
      tester,
    ) async {
      // Contract: no overlap/overflow at 320px width with text scale 1.3
      tester.view.physicalSize = const Size(320 * 3.0, 800 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 800),
            textScaler: TextScaler.linear(1.3),
          ),
          child: MaterialApp(
            theme: buildTheme(AppPalette.dark),
            home: WhyLogScreen(
              lines: [
                _line(
                  label: 'Rent',
                  amountPaise: 1800000,
                  source: ForecastEventSource.recurring,
                  status: ForecastLineStatus.unpaid,
                  date: DateTime(2026, 8, 5),
                ),
              ],
              forwardEarmarks: const [],
              reserveSchedules: [
                ReserveSchedule(
                  dedupeKey: 'lic',
                  label: 'LIC premium',
                  dueDate: DateTime(2027, 2, 14),
                  targetPaise: 4700000,
                  fundedPaise: 1200000,
                  remainingPaise: 3500000,
                  contributions: const [],
                  isFullyFunded: false,
                  isOverdue: false,
                ),
              ],
              monthLabel: 'August',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
