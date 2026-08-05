import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_analysis_snapshot.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/services/forecast_adapter.dart';
import 'package:expense_insight/services/sms_live_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

const _achDebitAlert =
    'UPDATE: [amount] debited from HDFC Bank [account] on 05-AUG-26. '
    'Info: ACH D- HDFC BANK LTD-[number]. Avl bal:[amount]';
const _mandateAlert =
    'PAYMENT ALERT! \n[amount] deducted from HDFC Bank A/C No [account] '
    'towards HDFC LTD UMRN: HDFC[number]';

ParsedTxn txn({
  required String smsId,
  required String sender,
  required String merchant,
  required String body,
  String? accountLast4,
  int? balancePaise,
  int amountPaise = 6141500,
  DateTime? date,
}) => ParsedTxn(
  smsId: smsId,
  sender: sender,
  direction: TransactionDirection.debit,
  instrument: PaymentInstrument.bank,
  type: TxnType.pos,
  amountPaise: amountPaise,
  txnDate: date ?? DateTime(2026, 8, 5),
  accountLast4: accountLast4,
  merchant: merchant,
  payeeType: PayeeType.unknown,
  categoryKey: 'other',
  confidence: 0.9,
  reviewStatus: ReviewStatus.autoAdded,
  source: TxnSource.sms,
  coverageBucket: CoverageBucket.datedEvent,
  balancePaise: balancePaise,
  rawBodyRedacted: body,
  bodyHash: 'h:${body.hashCode}',
  scanBatchId: 'b',
);

List<ParsedTxn> devicePair() => [
  txn(
    smsId: 'provider:12552',
    sender: 'VM-HDFCBK-S',
    merchant: 'hdfc bank ltd',
    balancePaise: 2902221,
    body: _achDebitAlert,
  ),
  txn(
    smsId: 'provider:12554',
    sender: 'JD-HDFCBK-S',
    merchant: 'hdfc ltd',
    accountLast4: '7106',
    body: _mandateAlert,
  ),
];

SmsAnalysisSnapshot reduceOf(List<ParsedTxn> history) =>
    SmsAnalysisSnapshot.reduce(
      history: history,
      obligations: const [],
      riskDecisions: const [],
      configuredPlans: const [],
      now: DateTime(2026, 8, 5, 12),
    );

void main() {
  test('the working set counts one ACH debit once', () {
    final marked = const SmsLiveNormalizer().markSupersededRedeliveries(
      devicePair(),
    );
    // Guard: the fixture really does carry a suppression, so a 1-vs-2 result
    // below cannot pass for the wrong reason.
    expect(marked.where((t) => t.supersededBySmsId != null), hasLength(1));

    final snapshot = reduceOf(marked);
    expect(snapshot.currentMonthTxns, hasLength(1));
    expect(snapshot.currentMonthTxns.single.smsId, 'provider:12552');
  });

  test('normalize applies the suppression on the live path', () {
    final out = const SmsLiveNormalizer().normalize(devicePair());
    expect(
      out.where((t) => t.supersededBySmsId != null).map((t) => t.smsId),
      ['provider:12554'],
    );
  });

  test('a suppressed re-delivery is named in the coverage lines', () {
    final marked = const SmsLiveNormalizer().markSupersededRedeliveries(
      devicePair(),
    );
    final snapshot = reduceOf(marked);

    final named = snapshot.supersededRedeliveries;
    expect(named, hasLength(1));
    expect(named.single.smsId, 'provider:12554');
    expect(named.single.amountPaise, 6141500);
  });

  test('the suppressed rupee reaches a duplicateSuppressed coverage line', () {
    final marked = const SmsLiveNormalizer().markSupersededRedeliveries(
      devicePair(),
    );
    final snapshot = reduceOf(marked);
    final lines = supersededCoverageLines(snapshot);

    expect(lines, hasLength(1));
    expect(lines.single.reason, CoverageReason.duplicateSuppressed);
    expect(lines.single.amountPaise, 6141500);
    expect(lines.single.label.toLowerCase(), contains('hdfc'));
  });
}
