import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/forecast_reconciliation_engine.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/reconciliation_invariants.dart';

void main() {
  BalanceAnchor anchorAt(DateTime asOf) => BalanceAnchor(
    amountPaise: 10000000,
    asOf: asOf,
    source: BalanceAnchorSource.smsBankBalance,
  );

  /// Every reconciliation in this file goes through here so rupee conservation
  /// is asserted on every fixture, not only where someone remembered to.
  ForecastReconciliationResult reconcile({
    required DateTime targetMonth,
    required BalanceAnchor anchor,
    required List<ReconciliationItem> items,
    DateTime? now,
  }) {
    final result = const ForecastReconciliationEngine().reconcileMonth(
      targetMonth: targetMonth,
      anchor: anchor,
      items: items,
      now: now,
    );
    expectRupeeConservation(result, items);
    return result;
  }

  void expectEveryInputAssigned(
    ForecastReconciliationResult result,
    List<ReconciliationItem> items,
  ) {
    expect(result.assignments.map((item) => item.itemId).toSet(), {
      for (final item in items) item.id,
    });
    expect(result.assignments, hasLength(items.length));
  }

  group('ForecastReconciliationEngine', () {
    test(
      'assigns a duplicated rupee to the higher-precedence Gmail owner once',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: BalanceAnchor(
            amountPaise: 10000000,
            asOf: DateTime(2026, 8),
            source: BalanceAnchorSource.smsBankBalance,
          ),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'gmail-lic',
              label: 'LIC premium',
              amountPaise: 4700000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 14),
              matchKey: 'lic:47000:annual',
            ),
            ReconciliationItem(
              id: 'sms-lic',
              label: 'LIC auto-debit candidate',
              amountPaise: 4700000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.recurringCommitment,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2026, 8, 14),
              matchKey: 'lic:47000:annual',
            ),
          ],
        );

        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'LIC premium');
        expect(result.events.single.ownerKey, 'gmailBill:gmail-lic');
        expect(result.assignments, hasLength(2));
        expect(
          result.assignments.where(
            (item) => item.coverageBucket == CoverageBucket.datedEvent,
          ),
          hasLength(1),
        );
        expect(
          result.assignments
              .singleWhere((item) => item.itemId == 'sms-lic')
              .status,
          ForecastLineStatus.reconciled,
        );
      },
    );

    test(
      'holds past-due unmatched current-month obligations for review after a post-due anchor',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8, 10)),
          now: DateTime(2026, 8, 10),
          items: [
            ReconciliationItem(
              id: 'electricity',
              label: 'Electricity bill',
              amountPaise: 250000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 5),
            ),
          ],
        );

        expect(result.events, isEmpty);
        expect(
          result.coverageLines.single.reason,
          CoverageReason.possiblyAlreadyPaid,
        );
        expect(result.coverageLines.single.action, CoverageAction.markUnpaid);
        expect(
          result.assignments.single.coverageBucket,
          CoverageBucket.reviewPending,
        );
      },
    );

    test(
      'keeps card purchases out of the bank ledger and counts the statement once',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'amazon-card',
              label: 'Amazon card purchase',
              amountPaise: 129900,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.cardPurchase,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 3),
              instrument: ReconciliationInstrument.card,
              cardCycleKey: 'hdfc-4321:2026-08',
            ),
            ReconciliationItem(
              id: 'hdfc-statement',
              label: 'HDFC card statement',
              amountPaise: 500000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.cardStatement,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 20),
              cardCycleKey: 'hdfc-4321:2026-08',
            ),
          ],
        );

        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'HDFC card statement');
        expect(result.events.single.amountPaise, 500000);
        expect(
          result.assignments
              .singleWhere((item) => item.itemId == 'amazon-card')
              .coverageBucket,
          CoverageBucket.quantifiedExcluded,
        );
        expect(
          result.coverageLines.single.reason,
          CoverageReason.cardCycleOnly,
        );
      },
    );

    test(
      'uses the actual card payment debit instead of duplicating the statement',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'hdfc-statement',
              label: 'HDFC card statement',
              amountPaise: 500000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.cardStatement,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 20),
              matchKey: 'card:hdfc:aug',
            ),
            ReconciliationItem(
              id: 'hdfc-payment',
              label: 'HDFC card payment',
              amountPaise: 500000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.cardPayment,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 18),
              matchKey: 'card:hdfc:aug',
            ),
          ],
        );

        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'HDFC card payment');
        expect(result.events.single.date, DateTime(2026, 8, 18));
        expect(
          result.assignments
              .singleWhere((item) => item.itemId == 'hdfc-statement')
              .status,
          ForecastLineStatus.reconciled,
        );
      },
    );

    test(
      'routes card refunds to card-cycle coverage instead of phantom bank cash',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'card-refund',
              label: 'Amazon card refund',
              amountPaise: 49900,
              direction: LedgerDirection.inflow,
              owner: ForecastOwner.refund,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 12),
              instrument: ReconciliationInstrument.card,
              refundOfId: 'amazon-card',
            ),
          ],
        );

        expect(result.events, isEmpty);
        expect(
          result.coverageLines.single.reason,
          CoverageReason.cardCycleOnly,
        );
        expect(
          result.assignments.single.coverageBucket,
          CoverageBucket.quantifiedExcluded,
        );
      },
    );

    test(
      'keeps material ATM cash as a bank event plus an untracked-cash caveat',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'atm-1',
              label: 'ATM withdrawal',
              amountPaise: 600000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.atmCash,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 8),
            ),
          ],
        );

        expect(result.events.single.source, ForecastEventSource.untrackedCash);
        expect(
          result.coverageLines.single.reason,
          CoverageReason.untrackedCash,
        );
      },
    );

    test(
      'uses primary transfer bridge instead of subtracting secondary obligation twice',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'secondary-rent',
              label: 'Rent paid from secondary account',
              amountPaise: 1800000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.nonPrimaryAccountObligation,
              source: ForecastItemSource.manual,
              dueDate: DateTime(2026, 8, 6),
              accountScope: AccountScope.secondary,
            ),
            ReconciliationItem(
              id: 'primary-transfer',
              label: 'Transfer to own secondary account',
              amountPaise: 1800000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.transfer,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 4),
              transferBridgeToId: 'secondary-rent',
            ),
          ],
        );

        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'Transfer to own secondary account');
        expect(
          result.coverageLines
              .singleWhere(
                (line) => line.reason == CoverageReason.outOfPrimaryScope,
              )
              .label,
          'Rent paid from secondary account',
        );
      },
    );

    test(
      'flags unknown account hints while still subtracting from the primary forecast',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'broadband',
              label: 'Broadband bill',
              amountPaise: 120000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 15),
              accountScope: AccountScope.unknown,
            ),
          ],
        );

        expect(result.events, hasLength(1));
        expect(
          result.coverageLines.single.reason,
          CoverageReason.accountHintUncertain,
        );
      },
    );

    test(
      'surfaces unscheduled annual obligations instead of guessing a due month',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'annual-insurance',
              label: 'Annual insurance',
              amountPaise: 4700000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.annualUnscheduled,
              source: ForecastItemSource.gmail,
              recurrence: ReconciliationRecurrence.annual,
            ),
          ],
        );

        expect(result.events, isEmpty);
        expect(
          result.coverageLines.single.reason,
          CoverageReason.unscheduledObligation,
        );
        expect(result.coverageLines.single.action, CoverageAction.setDueMonth);
      },
    );

    test(
      'requires confirmation before promoting algorithmic P2P outflows and income',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: [
            ReconciliationItem(
              id: 'p2p-rent',
              label: 'Possible recurring P2P rent',
              amountPaise: 1500000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.recurringP2pOutflow,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2026, 8, 3),
              userCadenceStatus: UserCadenceStatus.algorithmDetected,
              confidence: 0.82,
            ),
            ReconciliationItem(
              id: 'p2p-income',
              label: 'Possible roommate transfer',
              amountPaise: 600000,
              direction: LedgerDirection.inflow,
              owner: ForecastOwner.p2pIncomeCandidate,
              source: ForecastItemSource.sms,
              dueDate: DateTime(2026, 8, 5),
              userCadenceStatus: UserCadenceStatus.algorithmDetected,
              confidence: 0.9,
            ),
          ],
        );

        expect(result.events, isEmpty);
        expect(
          result.coverageLines.map((line) => line.reason),
          containsAll([
            CoverageReason.p2pConfirmationRequired,
            CoverageReason.reviewNeeded,
          ]),
        );
      },
    );

    test('keeps amountless obligations in review instead of dropping them', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [
          ReconciliationItem(
            id: 'amountless-gmail',
            label: 'Gmail bill without amount',
            amountPaise: null,
            amountStatus: AmountStatus.missing,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.gmailBill,
            source: ForecastItemSource.gmail,
            dueDate: DateTime(2026, 8, 21),
          ),
        ],
      );

      expect(result.events, isEmpty);
      expect(result.coverageLines.single.reason, CoverageReason.reviewNeeded);
      expect(
        result.assignments.single.coverageBucket,
        CoverageBucket.reviewPending,
      );
    });

    test(
      'assigns out-of-month known items to an explicit future coverage bucket',
      () {
        final items = [
          ReconciliationItem(
            id: 'sep-insurance',
            label: 'September insurance',
            amountPaise: 4700000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.gmailBill,
            source: ForecastItemSource.gmail,
            dueDate: DateTime(2026, 9, 14),
          ),
        ];
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: items,
        );

        expectEveryInputAssigned(result, items);
        expect(result.events, isEmpty);
        expect(
          result.coverageLines.single.reason,
          CoverageReason.futureEarmark,
        );
        expect(
          result.assignments.single.coverageBucket,
          CoverageBucket.quantifiedExcluded,
        );
      },
    );

    test(
      'matches card statement and actual payment by card cycle without a match key',
      () {
        final items = [
          ReconciliationItem(
            id: 'hdfc-statement-cycle',
            label: 'HDFC card statement',
            amountPaise: 500000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.cardStatement,
            source: ForecastItemSource.gmail,
            dueDate: DateTime(2026, 8, 20),
            cardCycleKey: 'hdfc-4321:2026-08',
          ),
          ReconciliationItem(
            id: 'hdfc-payment-cycle',
            label: 'HDFC card payment',
            amountPaise: 500000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.cardPayment,
            source: ForecastItemSource.sms,
            actualDate: DateTime(2026, 8, 18),
            cardCycleKey: 'hdfc-4321:2026-08',
          ),
        ];
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: items,
        );

        expectEveryInputAssigned(result, items);
        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'HDFC card payment');
        expect(
          result.assignments
              .singleWhere((item) => item.itemId == 'hdfc-statement-cycle')
              .status,
          ForecastLineStatus.reconciled,
        );
      },
    );

    test(
      'uses a bridge transfer instead of also subtracting an unknown-account obligation',
      () {
        final items = [
          ReconciliationItem(
            id: 'unknown-rent',
            label: 'Rent with unknown payment account',
            amountPaise: 1800000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.gmailBill,
            source: ForecastItemSource.manual,
            dueDate: DateTime(2026, 8, 6),
            accountScope: AccountScope.unknown,
          ),
          ReconciliationItem(
            id: 'rent-funding-transfer',
            label: 'Transfer that may fund rent',
            amountPaise: 1800000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.transfer,
            source: ForecastItemSource.sms,
            actualDate: DateTime(2026, 8, 4),
            transferBridgeToId: 'unknown-rent',
          ),
        ];
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: items,
        );

        expectEveryInputAssigned(result, items);
        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'Transfer that may fund rent');
        expect(
          result.coverageLines.single.reason,
          CoverageReason.transferBridgeReview,
        );
      },
    );

    test(
      'marks actual, overdue, and future expected lines with paid/unpaid state',
      () {
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8, 10),
          items: [
            ReconciliationItem(
              id: 'paid-mobile',
              label: 'Mobile bill paid',
              amountPaise: 100000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.sms,
              actualDate: DateTime(2026, 8, 8),
              paymentStatus: ReconciliationPaymentStatus.paid,
            ),
            ReconciliationItem(
              id: 'overdue-electricity',
              label: 'Overdue electricity',
              amountPaise: 250000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 5),
            ),
            ReconciliationItem(
              id: 'future-broadband',
              label: 'Future broadband',
              amountPaise: 120000,
              direction: LedgerDirection.outflow,
              owner: ForecastOwner.gmailBill,
              source: ForecastItemSource.gmail,
              dueDate: DateTime(2026, 8, 15),
            ),
          ],
        );

        ForecastLineStatus statusFor(String id) => result.assignments
            .singleWhere((assignment) => assignment.itemId == id)
            .status;

        expect(statusFor('paid-mobile'), ForecastLineStatus.paid);
        expect(statusFor('overdue-electricity'), ForecastLineStatus.overdue);
        expect(statusFor('future-broadband'), ForecastLineStatus.unpaid);
      },
    );

    test('surfaces partial card outstanding as quantified coverage', () {
      final items = [
        ReconciliationItem(
          id: 'partial-card',
          label: 'Partial HDFC card outstanding',
          amountPaise: 200000,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.cardStatement,
          source: ForecastItemSource.gmail,
          dueDate: DateTime(2026, 8, 20),
          paymentStatus: ReconciliationPaymentStatus.partial,
          cardCycleKey: 'hdfc-4321:2026-08',
        ),
      ];
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: items,
      );

      expectEveryInputAssigned(result, items);
      expect(result.events, isEmpty);
      expect(
        result.coverageLines.single.reason,
        CoverageReason.partialCardOutstanding,
      );
    });

    test('uses monthly ATM total for material untracked-cash caveats', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [
          ReconciliationItem(
            id: 'atm-1-small',
            label: 'ATM withdrawal 1',
            amountPaise: 300000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.atmCash,
            source: ForecastItemSource.sms,
            actualDate: DateTime(2026, 8, 8),
          ),
          ReconciliationItem(
            id: 'atm-2-small',
            label: 'ATM withdrawal 2',
            amountPaise: 300000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.atmCash,
            source: ForecastItemSource.sms,
            actualDate: DateTime(2026, 8, 9),
          ),
        ],
      );

      expect(result.events, hasLength(2));
      // One line for the month, carrying the monthly total — the spec's message
      // is "₹X cash withdrawn this month", not one caveat per withdrawal.
      expect(result.coverageLines, hasLength(1));
      expect(result.coverageLines.single.reason, CoverageReason.untrackedCash);
      expect(result.coverageLines.single.amountPaise, 600000);
    });

    test(
      'user-confirmed obligation wins over unconfirmed commitment at same owner precedence',
      () {
        // Both items have owner=recurringCommitment (same precedence=30) and
        // the same matchKey so they land in one reconciliation group.
        // The unconfirmed 'commit:vodafone' sorts alphabetically before the
        // confirmed 'obl:vodafone', but the confirmed obligation must win.
        final items = [
          ReconciliationItem(
            id: 'commit:vodafone',
            label: 'Vodafone auto-debit candidate',
            amountPaise: 50000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.recurringCommitment,
            source: ForecastItemSource.sms,
            dueDate: DateTime(2026, 8, 12),
            matchKey: 'vodafone:500:monthly',
            isUserConfirmed: false,
            confidence: 0.7,
          ),
          ReconciliationItem(
            id: 'obl:vodafone',
            label: 'Vodafone recharge',
            amountPaise: 50000,
            direction: LedgerDirection.outflow,
            owner: ForecastOwner.recurringCommitment,
            source: ForecastItemSource.sms,
            dueDate: DateTime(2026, 8, 12),
            matchKey: 'vodafone:500:monthly',
            isUserConfirmed: true,
            obligationDedupeKey: 'sms_recurring:vodafone:monthly',
            confidence: 0.7,
          ),
        ];
        final result = reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: items,
        );

        expectEveryInputAssigned(result, items);
        // The confirmed obligation must win the group (event label matches).
        expect(result.events, hasLength(1));
        expect(result.events.single.label, 'Vodafone recharge');
        expect(
          result.events.single.ownerKey,
          'recurringCommitment:obl:vodafone',
        );
        expect(result.events.single.isUserConfirmed, isTrue);
        // The unconfirmed commitment must be reconciled as a duplicate.
        expect(
          result.assignments
              .singleWhere((a) => a.itemId == 'commit:vodafone')
              .status,
          ForecastLineStatus.reconciled,
        );
      },
    );
  });

  group('untracked-cash aggregation threshold (M2)', () {
    ReconciliationItem atm(String id, int amountPaise, int day) =>
        ReconciliationItem(
          id: id,
          label: 'ATM $id',
          amountPaise: amountPaise,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.atmCash,
          source: ForecastItemSource.sms,
          actualDate: DateTime(2026, 8, day),
        );

    test('a monthly total exactly at the threshold states the caveat once', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [atm('a', 200000, 4), atm('b', 200000, 9), atm('c', 100000, 20)],
      );

      expect(result.coverageLines, hasLength(1));
      expect(
        result.coverageLines.single.amountPaise,
        ForecastReconciliationEngine.materialCashThresholdPaise,
      );
      expect(result.coverageLines.single.label, 'Cash withdrawn this month');
    });

    test('one paise under the threshold states no caveat at all', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [atm('a', 200000, 4), atm('b', 299999, 9)],
      );

      expect(result.events, hasLength(2));
      expect(result.coverageLines, isEmpty);
    });
  });

  group('why-log obligation origin labels (M3)', () {
    ReconciliationItem obligation(ForecastItemSource source) =>
        ReconciliationItem(
          id: 'annual:$source',
          label: 'LIC premium',
          amountPaise: 4700000,
          direction: LedgerDirection.outflow,
          owner: ForecastOwner.annualUnscheduled,
          source: source,
          dueDate: DateTime(2026, 8, 14),
        );

    ForecastEventSource sourceFor(ForecastItemSource source) {
      final item = obligation(source);
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [item],
      );
      return result.events.single.source;
    }

    test('an SMS-detected annual obligation does not read "Gmail bill"', () {
      expect(sourceFor(ForecastItemSource.sms), ForecastEventSource.recurring);
    });

    test('a manual obligation is traceable to manual entry', () {
      // `ForecastEventSource.manual` was unreachable from every path before
      // this, despite `ObligationSourceType.manual` existing.
      expect(sourceFor(ForecastItemSource.manual), ForecastEventSource.manual);
    });

    test('a Gmail-sourced obligation still reads as a Gmail bill', () {
      expect(
        sourceFor(ForecastItemSource.gmail),
        ForecastEventSource.gmailBill,
      );
    });
  });

  group('duplicate item ids degrade to review (M4)', () {
    // Reachable in production: obligation item ids are `obl:<dedupeKey>` and
    // `recurring_obligation_candidates` deliberately reuses `configuredPlanKey`
    // as that dedupe key, so an SMS-recurring record and a configured-plan
    // record collide on the id.
    final colliding = [
      ReconciliationItem(
        id: 'obl:sip-hdfc',
        label: 'HDFC SIP (SMS recurring)',
        amountPaise: 500000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.recurringCommitment,
        source: ForecastItemSource.sms,
        dueDate: DateTime(2026, 8, 12),
      ),
      ReconciliationItem(
        id: 'obl:sip-hdfc',
        label: 'HDFC SIP (configured plan)',
        amountPaise: 700000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.configuredContribution,
        source: ForecastItemSource.configuredPlan,
        dueDate: DateTime(2026, 8, 12),
      ),
    ];

    test('the forecast survives the collision instead of blanking', () {
      expect(
        () => const ForecastReconciliationEngine().reconcileMonth(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: colliding,
        ),
        returnsNormally,
      );
    });

    test('neither colliding item is guessed onto the ledger', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: colliding,
      );

      expect(result.events, isEmpty);
      expect(result.assignments, hasLength(2));
      expect(
        result.assignments.map((a) => a.coverageBucket).toSet(),
        {CoverageBucket.reviewPending},
      );
    });

    test('an unrelated item in the same batch still reaches the ledger', () {
      final rent = ReconciliationItem(
        id: 'obl:rent',
        label: 'Rent',
        amountPaise: 1800000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.recurringCommitment,
        source: ForecastItemSource.sms,
        dueDate: DateTime(2026, 8, 5),
      );

      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [...colliding, rent],
      );

      expect(result.events.single.label, 'Rent');
    });
  });

  group('unconfirmed other income is gated (M6)', () {
    ReconciliationItem residual(UserCadenceStatus status) =>
        ReconciliationItem(
          id: 'refund-excess',
          label: 'Refund exceeding the original debit',
          amountPaise: 250000,
          direction: LedgerDirection.inflow,
          owner: ForecastOwner.otherIncome,
          source: ForecastItemSource.sms,
          actualDate: DateTime(2026, 8, 11),
          userCadenceStatus: status,
        );

    test('an algorithm-detected residual cannot raise the balance', () {
      final item = residual(UserCadenceStatus.algorithmDetected);
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [item],
      );

      expect(result.events, isEmpty);
      expect(result.coverageLines.single.reason, CoverageReason.reviewNeeded);
      expect(result.coverageLines.single.action, CoverageAction.confirmIncome);
      expect(
        result.assignments.single.coverageBucket,
        CoverageBucket.reviewPending,
      );
    });

    test('a user-confirmed other income is credited normally', () {
      final result = reconcile(
        targetMonth: DateTime(2026, 8),
        anchor: anchorAt(DateTime(2026, 8)),
        now: DateTime(2026, 8),
        items: [residual(UserCadenceStatus.userConfirmed)],
      );

      expect(result.events.single.direction, LedgerDirection.inflow);
      expect(result.events.single.source, ForecastEventSource.otherIncome);
    });
  });

  group('a tie below the winner is not resolved at all (M7)', () {
    // M7 asked whether `_hasUnresolvableTie` should look past `ordered[0..1]`.
    // It should not. A tie among *non-winners* has no outcome to change:
    // `_chooseWinners` returns either every bridging transfer, every dated card
    // payment, or `[ordered.first]` — never a pick between tied losers — and
    // every loser then takes the same suppression path. Widening the check
    // would only send groups like this one to review instead of booking them.
    List<ReconciliationItem> group(String firstTiedId, String secondTiedId) => [
      ReconciliationItem(
        id: 'gmail-lic',
        label: 'LIC premium',
        amountPaise: 4700000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.gmailBill,
        source: ForecastItemSource.gmail,
        dueDate: DateTime(2026, 8, 14),
        matchKey: 'lic:47000:annual',
      ),
      ReconciliationItem(
        id: firstTiedId,
        label: 'LIC auto-debit candidate',
        amountPaise: 4700000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.recurringCommitment,
        source: ForecastItemSource.sms,
        dueDate: DateTime(2026, 8, 14),
        matchKey: 'lic:47000:annual',
      ),
      ReconciliationItem(
        id: secondTiedId,
        label: 'LIC standing instruction',
        amountPaise: 4700000,
        direction: LedgerDirection.outflow,
        owner: ForecastOwner.recurringCommitment,
        source: ForecastItemSource.sms,
        dueDate: DateTime(2026, 8, 14),
        matchKey: 'lic:47000:annual',
      ),
    ];

    ForecastReconciliationResult run(List<ReconciliationItem> items) =>
        reconcile(
          targetMonth: DateTime(2026, 8),
          anchor: anchorAt(DateTime(2026, 8)),
          now: DateTime(2026, 8),
          items: items,
        );

    test('the strict precedence winner is still booked', () {
      final result = run(group('sms-a', 'sms-b'));

      expect(result.events.single.label, 'LIC premium');
      expect(
        result.assignments
            .where((a) => a.itemId != 'gmail-lic')
            .map((a) => a.status)
            .toSet(),
        {ForecastLineStatus.reconciled},
      );
    });

    test('swapping the tied members changes nothing about the outcome', () {
      // The tie is broken deterministically by id, but nothing downstream reads
      // that order — so "resolved arbitrarily" has no observable meaning here.
      final forward = run(group('sms-a', 'sms-b'));
      final reversed = run(group('sms-b', 'sms-a'));

      expect(
        reversed.events.map((e) => e.ownerKey),
        forward.events.map((e) => e.ownerKey),
      );
      expect(
        {for (final a in reversed.assignments) a.itemId: a.status},
        {for (final a in forward.assignments) a.itemId: a.status},
      );
    });
  });
}
