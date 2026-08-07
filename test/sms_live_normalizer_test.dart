import 'package:expense_insight/data/self_transfer_decision_store.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a [ParsedTxn] with the fields the normalizer keys off. Bodies mirror
/// (redacted) real device messages so the dedup/enrich logic is grounded in the
/// user's actual SMS formats.
ParsedTxn txn({
  required String smsId,
  String sender = 'VM-HDFCBK-S',
  TransactionDirection direction = TransactionDirection.debit,
  TxnType type = TxnType.pos,
  int amountPaise = 1000000,
  DateTime? date,
  String? merchant,
  String? upiVpaNorm,
  String? accountLast4,
  String? refNumber,
  ReviewStatus reviewStatus = ReviewStatus.autoAdded,
  String categoryKey = 'other',
  int? balancePaise,
  required String body,
}) => ParsedTxn(
  smsId: smsId,
  sender: sender,
  direction: direction,
  instrument: PaymentInstrument.bank,
  type: type,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 7, 5),
  accountLast4: accountLast4,
  refNumber: refNumber,
  merchant: merchant,
  upiVpaNorm: upiVpaNorm,
  payeeType: PayeeType.unknown,
  categoryKey: categoryKey,
  confidence: 0.9,
  reviewStatus: reviewStatus,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  balancePaise: balancePaise,
  rawBodyRedacted: body,
  bodyHash: 'h:${body.hashCode}',
  scanBatchId: 'b',
);

void main() {
  const normalizer = SmsLiveNormalizer();

  group('dedup — same event delivered under multiple DLT headers', () {
    test('collapses cross-sender identical content to one row', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          sender: 'AD-HDFCBK-S',
          amountPaise: 6141500,
          body: '[AD-HDFCBK-S] debit 6141500p :: [amount] debited [account] '
              '05-12-25, 10:57:27 UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
        txn(
          smsId: 'b',
          sender: 'VM-HDFCBK-S',
          amountPaise: 6141500,
          body: '[VM-HDFCBK-S] debit 6141500p :: [amount] debited [account] '
              '05-12-25, 10:57:27 UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
      ]);
      expect(rows, hasLength(1));
    });

    test('keeps distinct same-day same-amount SIPs (different payee/ref)', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          amountPaise: 1000000,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/111111111111/FUND ALPHA',
        ),
        txn(
          smsId: 'b',
          amountPaise: 1000000,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/222222222222/FUND BETA',
        ),
      ]);
      expect(rows, hasLength(2));
    });

    test('keeps sequential ATM withdrawals (different balance/timestamp)', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'a',
          type: TxnType.atm,
          amountPaise: 2000000,
          balancePaise: 5432100,
          body: '[JD-HDFCBK-S] debit 2000000p :: [amount] withdrawn from HDFC '
              'Bank Card [account] at MAIN STREET ATM on 17-07-26:20:20:43 '
              'Avl bal: [amount]',
        ),
        txn(
          smsId: 'b',
          type: TxnType.atm,
          amountPaise: 2000000,
          balancePaise: 3432100,
          body: '[JD-HDFCBK-S] debit 2000000p :: [amount] withdrawn from HDFC '
              'Bank Card [account] at MAIN STREET ATM on 17-07-26:20:21:42 '
              'Avl bal: [amount]',
        ),
      ]);
      expect(rows, hasLength(2));
    });
  });

  group('collision — genuine same-day repeats are never silently dropped', () {
    // The redacted shape a bare Axis/UPI debit reduces to. It carries no ref,
    // no intra-body timestamp and no balance, so two of them are byte-identical
    // no matter how many distinct payments produced them.
    const contentless = '[amount] debited [account] Axis Bank';

    test('keeps both payments when their reference numbers differ', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          accountLast4: '1234',
          refNumber: 'REF111',
          body: contentless,
        ),
        txn(
          smsId: 'provider:2',
          amountPaise: 10000,
          accountLast4: '1234',
          refNumber: 'REF222',
          body: contentless,
        ),
      ]);

      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.reviewReason),
        everyElement(isNot(ReviewReason.dedupCollision)),
      );
    });

    test('routes indistinguishable payments to a collision set, drops neither', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          accountLast4: '1234',
          body: contentless,
        ),
        txn(
          smsId: 'provider:2',
          amountPaise: 10000,
          accountLast4: '1234',
          body: contentless,
        ),
      ]);

      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.reviewStatus),
        everyElement(ReviewStatus.needsReview),
      );
      expect(
        rows.map((r) => r.reviewReason),
        everyElement(ReviewReason.dedupCollision),
      );
      expect(rows.first.collisionSetId, isNotNull);
      expect(rows.first.collisionSetId, rows.last.collisionSetId);
    });

    test('collapses the same message seen twice to exactly one row', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          accountLast4: '1234',
          body: contentless,
        ),
        txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          accountLast4: '1234',
          body: contentless,
        ),
      ]);

      expect(rows, hasLength(1));
      expect(rows.single.reviewReason, isNot(ReviewReason.dedupCollision));
    });

    test('does not re-open a collision the user has already resolved', () {
      final rows = normalizer.dedup([
        txn(
          smsId: 'provider:1',
          amountPaise: 10000,
          accountLast4: '1234',
          reviewStatus: ReviewStatus.confirmed,
          body: contentless,
        ),
        txn(
          smsId: 'provider:2',
          amountPaise: 10000,
          accountLast4: '1234',
          reviewStatus: ReviewStatus.confirmed,
          body: contentless,
        ),
      ]);

      expect(rows, hasLength(2));
      expect(
        rows.map((r) => r.reviewStatus),
        everyElement(ReviewStatus.confirmed),
      );
    });
  });

  group('enrich — fill a stable merchant/category for blank rows', () {
    test('writes the UPI P2M payee as a lowercase merchant owner key', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/549148394747/ACME DIGITAL PRIVAT',
        ),
      );
      expect(out.merchant, 'acme digital privat');
    });

    test('writes a known-merchant name and its category', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          body: '[amount] spent on HDFC Bank Card [account] at RAZ*SWIGGY '
              'on 2026-07-11:22:03:27',
        ),
      );
      expect(out.merchant, 'swiggy');
      expect(out.categoryKey, 'food');
    });

    test('does NOT write the bank-name fallback as a merchant', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          type: TxnType.other,
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited from your '
              'account towards NEFT',
        ),
      );
      expect(out.merchant, isNull);
    });

    test('is a no-op on rows that already have a good merchant + category', () {
      final original = txn(
        smsId: 'a',
        merchant: 'swiggy',
        categoryKey: 'food',
        body: 'anything',
      );
      final out = normalizer.enrich(original);
      expect(out.merchant, 'swiggy');
      expect(out.categoryKey, 'food');
    });

    test('resolves the HDFC To-line payee, not the bank name', () {
      final out = normalizer.enrich(
        txn(
          smsId: 'a',
          body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\n'
              'To CRED Club\nOn 01/08/26\n[ref]',
        ),
      );
      expect(out.merchant, 'cred club');
    });

    test('gives the same owner key to the same To payee across months', () {
      // The assertion that matters for recurring detection: two months of the
      // same payee must collapse to one owner key, or no obligation forms.
      final july = normalizer.enrich(
        txn(
          smsId: 'jul',
          date: DateTime(2026, 7, 1),
          body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\n'
              'To ACME DIGITAL PRIVATE LIMI\nOn 01/07/26\n[ref]',
        ),
      );
      final august = normalizer.enrich(
        txn(
          smsId: 'aug',
          date: DateTime(2026, 8, 1),
          body: 'Sent [amount]\nFrom HDFC Bank A/C [account]\n'
              'To ACME DIGITAL PRIVATE LIMI\nOn 01/08/26\n[ref]',
        ),
      );
      expect(july.merchant, august.merchant);
      expect(july.merchant, isNotNull);
      expect(july.merchant, isNot(contains('hdfc')));
    });

    test('gives the same owner key to the same payee across months', () {
      final july = normalizer.enrich(
        txn(
          smsId: 'jul',
          date: DateTime(2026, 7, 5),
          body: '[VM-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/111/ACME DIGITAL PRIVAT',
        ),
      );
      final august = normalizer.enrich(
        txn(
          smsId: 'aug',
          date: DateTime(2026, 8, 5),
          body: '[AD-HDFCBK-S] debit 1000000p :: [amount] debited '
              'UPI/P2M/999/ACME DIGITAL PRIVAT',
        ),
      );
      expect(july.merchant, august.merchant);
      expect(july.merchant, isNotEmpty);
    });
  });

  _confirmedSelfTransfers();
}

// ---------------------------------------------------------------------------
// A confirmed self-transfer has to reach both lenses, and the only durable
// place to say so is the user's stored decision. Marking is done here, at read
// time, for the reason the file header already gives: a correction reaches rows
// already on disk without a rescan or a migration.
//
// Both legs are marked, not just the debit. The credit is the same rupees
// arriving on the user's other account, and an unmarked ₹50,000 inbound leg is
// read by the income detector as money coming in.
// ---------------------------------------------------------------------------
void _confirmedSelfTransfers() {
  final debit = txn(
    smsId: 'debit-hdfc',
    direction: TransactionDirection.debit,
    amountPaise: 5000000,
    accountLast4: '7001',
    date: DateTime(2026, 1, 13, 14, 30),
    merchant: 'payee name',
    body: 'Sent [amount] From HDFC Bank A/C [account] To PAYEE NAME',
  );
  final credit = txn(
    smsId: 'credit-axis',
    direction: TransactionDirection.credit,
    amountPaise: 5000000,
    accountLast4: '7002',
    date: DateTime(2026, 1, 13, 14, 49),
    body: '[amount] credited A/c no. [account] UPI/P2A/[number]/PAYEE/HDFC',
  );

  group('a confirmed self-transfer is marked on both legs', () {
    test('both rows come back as selfTransfer', () {
      final out = const SmsLiveNormalizer().normalize(
        [debit, credit],
        selfTransfers: const SelfTransferDecisions({
          'debit-hdfc': SelfTransferDecision(
            creditSmsId: 'credit-axis',
            confirmed: true,
          ),
        }),
      );

      final byId = {for (final t in out) t.smsId: t};
      expect(byId['debit-hdfc']!.payeeType, PayeeType.selfTransfer);
      expect(byId['credit-axis']!.payeeType, PayeeType.selfTransfer);
    });

    test('a rejected pair is left exactly as it was', () {
      final out = const SmsLiveNormalizer().normalize(
        [debit, credit],
        selfTransfers: const SelfTransferDecisions({
          'debit-hdfc': SelfTransferDecision(
            creditSmsId: 'credit-axis',
            confirmed: false,
          ),
        }),
      );

      final byId = {for (final t in out) t.smsId: t};
      expect(byId['debit-hdfc']!.payeeType, isNot(PayeeType.selfTransfer));
      expect(byId['credit-axis']!.payeeType, isNot(PayeeType.selfTransfer));
    });

    test('with no decisions at all nothing is marked', () {
      final out = const SmsLiveNormalizer().normalize([debit, credit]);

      expect(
        out.every((t) => t.payeeType != PayeeType.selfTransfer),
        isTrue,
      );
    });
  });
}
