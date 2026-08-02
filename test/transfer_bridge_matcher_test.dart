import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/obligation_models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/transfer_bridge_matcher.dart';
import 'package:flutter_test/flutter_test.dart';

ParsedTxn primaryTxn({
  required DateTime date,
  required int amountPaise,
  TxnType type = TxnType.transfer,
  String merchant = 'Self HDFC 9012',
  String accountLast4 = '1234',
  String smsId = 'sms',
}) => ParsedTxn(
  smsId: smsId,
  sender: 'VM-HDFCBK',
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: type,
  amountPaise: amountPaise,
  txnDate: date,
  merchant: merchant,
  accountLast4: accountLast4,
  payeeType: PayeeType.selfTransfer,
  categoryKey: 'transfer',
  confidence: 0.9,
  reviewStatus: ReviewStatus.confirmed,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  rawBodyRedacted: 'redacted',
  bodyHash: 'h',
  scanBatchId: 'b',
);

ObligationRecord secondaryObligation({
  required int amountPaise,
  required DateTime dueDate,
  String merchant = 'LIC Premium',
  String merchantNorm = 'lic premium',
  int? id = 1,
  String? dedupeKey,
}) => ObligationRecord(
  id: id,
  sourceType: ObligationSourceType.gmail,
  dedupeKey: dedupeKey ?? 'lic:$amountPaise',
  merchant: merchant,
  merchantNorm: merchantNorm,
  categoryKey: 'insurance',
  amountPaise: amountPaise,
  amountStatus: AmountStatus.known,
  recurrence: ReconciliationRecurrence.annual,
  dueDate: dueDate,
  paymentAccountHintLast4: '9012',
  paymentAccountScope: AccountScope.secondary,
  paymentStatus: ReconciliationPaymentStatus.unpaid,
  nextExpectedSource: NextExpectedSource.explicitDueDate,
  payeeType: PayeeType.merchant,
  userCadenceStatus: UserCadenceStatus.userConfirmed,
  confidence: 0.9,
  reviewStatus: ObligationReviewStatus.confirmed,
  createdAt: DateTime(2026, 1),
  updatedAt: DateTime(2026, 1),
);

void main() {
  const matcher = TransferBridgeMatcher();

  group('constants', () {
    test('encode the confirmed D7 transfer-bridge windows', () {
      expect(kTransferBridgeAmountBandPaise, 5000);
      expect(kTransferBridgeDaysBeforeDue, 5);
      expect(kTransferBridgeDaysAfterDue, 2);
    });
  });

  group('TransferBridgeMatcher.match', () {
    test('unique bridge funds the obligation and prevents double-count', () {
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000,
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
      );

      final candidates = matcher.match([transfer], [obligation]);

      expect(candidates, hasLength(1));
      final candidate = candidates.single;
      expect(candidate.resolution, TransferBridgeResolution.funded);
      expect(candidate.transfer.smsId, transfer.smsId);
      expect(candidate.obligation, isNotNull);
      expect(candidate.obligation!.id, obligation.id);
    });

    test('amount just outside the ±₹50 band does not bridge', () {
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000 + kTransferBridgeAmountBandPaise + 1,
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
      );

      expect(matcher.match([transfer], [obligation]), isEmpty);
    });

    test('transfer outside the 0-5d before / 0-2d after window does not bridge', () {
      final tooEarly = primaryTxn(
        date: DateTime(2026, 8, 8), // 6 days before due
        amountPaise: 4700000,
      );
      final tooLate = primaryTxn(
        date: DateTime(2026, 8, 17), // 3 days after due
        amountPaise: 4700000,
        smsId: 'late',
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
      );

      expect(matcher.match([tooEarly], [obligation]), isEmpty);
      expect(matcher.match([tooLate], [obligation]), isEmpty);
    });

    test('boundary transfers on the window edges do bridge', () {
      final onEarlyEdge = primaryTxn(
        date: DateTime(2026, 8, 9), // exactly 5 days before
        amountPaise: 4700000,
      );
      final onLateEdge = primaryTxn(
        date: DateTime(2026, 8, 16), // exactly 2 days after
        amountPaise: 4700000,
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
      );

      expect(matcher.match([onEarlyEdge], [obligation]), hasLength(1));
      expect(matcher.match([onLateEdge], [obligation]), hasLength(1));
    });

    test('ambiguous bridge (one transfer, two obligations) routes to review', () {
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 13),
        amountPaise: 4700000,
      );
      final oblA = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
        merchant: 'LIC',
        merchantNorm: 'lic',
        id: 1,
      );
      final oblB = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 12),
        merchant: 'HDFC Life',
        merchantNorm: 'hdfc life',
        id: 2,
      );

      final candidates = matcher.match([transfer], [oblA, oblB]);

      expect(candidates, hasLength(1));
      expect(candidates.single.resolution, TransferBridgeResolution.ambiguous);
      expect(candidates.single.obligation, isNull);
      expect(candidates.single.obligations, hasLength(2));
    });

    test('two transfers competing for one obligation are ambiguous', () {
      final t1 = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000,
        smsId: 't1',
      );
      final t2 = primaryTxn(
        date: DateTime(2026, 8, 13),
        amountPaise: 4700000,
        smsId: 't2',
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
      );

      final candidates = matcher.match([t1, t2], [obligation]);

      expect(candidates, hasLength(2));
      expect(
        candidates.every(
          (c) => c.resolution == TransferBridgeResolution.ambiguous,
        ),
        isTrue,
      );
    });

    test('observed primary debit overrides stale secondary hint (no bridge)', () {
      // A direct primary-account debit of the bill itself is observed, so the
      // obligation is paid on the primary account; a coincident self-transfer
      // must not create a bridge that double-excludes it.
      final directDebit = primaryTxn(
        date: DateTime(2026, 8, 14),
        amountPaise: 4700000,
        type: TxnType.upi,
        merchant: 'LIC Premium',
        smsId: 'direct',
      );
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000,
        smsId: 'xfer',
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
        merchant: 'LIC Premium',
        merchantNorm: 'lic premium',
      );

      final candidates = matcher.match([directDebit, transfer], [obligation]);

      expect(candidates, isEmpty);
    });

    test('only secondary-scope obligations are bridged', () {
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 13),
        amountPaise: 4700000,
      );
      final primaryObligation = ObligationRecord(
        id: 5,
        sourceType: ObligationSourceType.gmail,
        dedupeKey: 'rent',
        merchant: 'Rent',
        merchantNorm: 'rent',
        categoryKey: 'housing',
        amountPaise: 4700000,
        amountStatus: AmountStatus.known,
        recurrence: ReconciliationRecurrence.monthly,
        dueDate: DateTime(2026, 8, 14),
        paymentAccountScope: AccountScope.primary,
        paymentStatus: ReconciliationPaymentStatus.unpaid,
        nextExpectedSource: NextExpectedSource.explicitDueDate,
        payeeType: PayeeType.merchant,
        userCadenceStatus: UserCadenceStatus.userConfirmed,
        confidence: 0.9,
        reviewStatus: ObligationReviewStatus.confirmed,
        createdAt: DateTime(2026, 1),
        updatedAt: DateTime(2026, 1),
      );

      expect(matcher.match([transfer], [primaryObligation]), isEmpty);
    });

    test('a direct debit from months ago does not suppress this bridge', () {
      // Unbounded, the lookup let last year's premium veto this year's
      // transfer forever, and the obligation was then counted separately.
      final staleDebit = primaryTxn(
        date: DateTime(2025, 9, 14),
        amountPaise: 4700000,
        type: TxnType.upi,
        merchant: 'LIC Premium',
        smsId: 'stale',
      );
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000,
        smsId: 'xfer',
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
        merchant: 'LIC Premium',
        merchantNorm: 'lic premium',
      );

      final candidates = matcher.match([staleDebit, transfer], [obligation]);

      expect(candidates, hasLength(1));
      expect(candidates.single.resolution, TransferBridgeResolution.funded);
    });

    test('a direct debit inside the due window still suppresses it', () {
      final directDebit = primaryTxn(
        date: DateTime(2026, 8, 16),
        amountPaise: 4700000,
        type: TxnType.upi,
        merchant: 'LIC Premium',
        smsId: 'direct',
      );
      final transfer = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 4700000,
        smsId: 'xfer',
      );
      final obligation = secondaryObligation(
        amountPaise: 4700000,
        dueDate: DateTime(2026, 8, 14),
        merchant: 'LIC Premium',
        merchantNorm: 'lic premium',
      );

      expect(matcher.match([directDebit, transfer], [obligation]), isEmpty);
    });

    test(
      'two rows sharing a dedupe key are one obligation, so two transfers '
      'aiming at it are ambiguous (M9)',
      () {
        // `dedupeKey` is the obligation's identity — it is what the repository
        // upserts on. Keyed by *instance* the matcher saw two obligations here
        // and auto-linked both transfers, which funds one bill twice. Two
        // distinct records that carry no value equality must not read as two
        // distinct obligations.
        final rowA = secondaryObligation(
          id: 1,
          amountPaise: 500000,
          dueDate: DateTime(2026, 8, 14),
          dedupeKey: 'sip:hdfc',
        );
        final rowB = secondaryObligation(
          id: 2,
          amountPaise: 900000,
          dueDate: DateTime(2026, 8, 14),
          dedupeKey: 'sip:hdfc',
        );
        final t1 = primaryTxn(
          date: DateTime(2026, 8, 12),
          amountPaise: 500000,
          smsId: 'xfer-1',
        );
        final t2 = primaryTxn(
          date: DateTime(2026, 8, 12),
          amountPaise: 900000,
          smsId: 'xfer-2',
        );

        final candidates = matcher.match([t1, t2], [rowA, rowB]);

        expect(candidates, hasLength(2));
        expect(
          candidates.map((c) => c.resolution).toSet(),
          {TransferBridgeResolution.ambiguous},
        );
        expect(candidates.every((c) => c.obligation == null), isTrue);
      },
    );

    test('distinct obligations each still fund uniquely (M9 guard)', () {
      // The same fixture with honest, distinct dedupe keys must stay funded —
      // the collapse above must key on identity, not merely on count.
      final rowA = secondaryObligation(
        id: 1,
        amountPaise: 500000,
        dueDate: DateTime(2026, 8, 14),
        dedupeKey: 'sip:hdfc',
      );
      final rowB = secondaryObligation(
        id: 2,
        amountPaise: 900000,
        dueDate: DateTime(2026, 8, 14),
        dedupeKey: 'sip:icici',
      );
      final t1 = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 500000,
        smsId: 'xfer-1',
      );
      final t2 = primaryTxn(
        date: DateTime(2026, 8, 12),
        amountPaise: 900000,
        smsId: 'xfer-2',
      );

      final candidates = matcher.match([t1, t2], [rowA, rowB]);

      expect(candidates, hasLength(2));
      expect(
        candidates.map((c) => c.resolution).toSet(),
        {TransferBridgeResolution.funded},
      );
      expect(
        candidates.map((c) => c.obligation!.dedupeKey).toSet(),
        {'sip:hdfc', 'sip:icici'},
      );
    });
  });
}
