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
      expect(
        result.coverageLines.map((line) => line.reason),
        everyElement(CoverageReason.untrackedCash),
      );
      expect(result.coverageLines, hasLength(2));
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
}
