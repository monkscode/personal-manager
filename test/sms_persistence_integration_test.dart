import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:expense_insight/data/transaction_repository.dart';
import 'package:expense_insight/services/forecast_ledger_engine.dart';
import 'package:expense_insight/services/sms_ingestion_policy.dart';
import 'package:expense_insight/services/sms_transaction_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  test('parse, dedup, persist, reload, and forecast from stored actuals', () async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    final repository = TransactionRepository(db);
    const parser = SmsTransactionParser();
    final now = DateTime(2026, 7, 9, 12);

    final raw = RawSms(
      providerId: 'sms-1',
      sender: 'VM-HDFCBK',
      body:
          'HDFC Bank: Rs.1250.00 debited from a/c XX1234 to swiggy@okhdfcbank UPI ref 123456789012. Avl Bal Rs.10000.00',
      receivedAt: now,
    );
    final parsed = parser.parseOne(
      raw,
      scanBatchId: 'batch-1',
      bodyHashSalt: 'test-salt',
    );
    expect(parsed, isNotNull);

    final decision = await repository.ingestParsedTxn(
      parsed!,
      isFirstScan: false,
      now: now,
    );
    expect(decision.action, IngestionAction.upsert);

    final duplicateDecision = await repository.ingestParsedTxn(
      parsed,
      isFirstScan: false,
      now: now,
    );
    expect(duplicateDecision.action, IngestionAction.skipDuplicate);

    final stored = await repository.queryByMonth('2026-07');
    expect(stored, hasLength(1));
    expect(stored.single.rawBodyRedacted, isNot(contains('10000.00')));

    final anchor = await repository.latestBalanceAnchor(primaryAccountLast4: '1234');
    expect(anchor, isNotNull);
    expect(anchor!.amountPaise, 1000000);

    final event = ForecastEvent(
      date: DateTime(2026, 7, 10),
      amountPaise: stored.single.amountPaise,
      direction: LedgerDirection.outflow,
      source: ForecastEventSource.currentActual,
      ownerKey: 'sms:${stored.single.smsId}',
      label: stored.single.merchant ?? 'SMS transaction',
      confidence: stored.single.confidence,
    );
    final result = const ForecastLedgerEngine().buildMonth(
      targetMonth: DateTime(2026, 7),
      anchor: anchor,
      events: [event],
      now: now,
    );

    expect(result.openingBalancePaise, 1000000);
    expect(result.closingBalancePaise, 875000);
    expect(result.shortfallPaise, 0);
  });
}
