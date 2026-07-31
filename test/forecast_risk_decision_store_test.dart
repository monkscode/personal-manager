import 'package:expense_insight/data/forecast_risk_decision_store.dart';
import 'package:expense_insight/data/forecast_risk_models.dart';
import 'package:expense_insight/data/sms_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  Future<ForecastRiskDecisionStore> openStore() async {
    final db = await SmsDatabase.openWithFactory(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    addTearDown(db.close);
    return ForecastRiskDecisionStore(db);
  }

  group('ForecastRiskDecisionStore', () {
    test('risk decision upsert replaces the same owner and month', () async {
      final store = await openStore();
      const pending = ForecastRiskDecision(
        ownerKey: 'seasonal:utilities',
        targetMonth: '2026-08',
        status: ForecastRiskDecisionStatus.confirmed,
        amountOverridePaise: 240000,
      );

      await store.upsert(pending, now: DateTime(2026, 7, 22));
      await store.upsert(
        pending.copyWith(status: ForecastRiskDecisionStatus.dismissed),
        now: DateTime(2026, 7, 23),
      );

      final rows = await store.all();
      expect(rows, hasLength(1));
      expect(rows.single.status, ForecastRiskDecisionStatus.dismissed);
    });

    test(
      'stores and retrieves multiple decisions by different owners',
      () async {
        final store = await openStore();

        await store.upsert(
          const ForecastRiskDecision(
            ownerKey: 'seasonal:utilities',
            targetMonth: '2026-08',
            status: ForecastRiskDecisionStatus.confirmed,
            amountOverridePaise: 240000,
          ),
          now: DateTime(2026, 7, 22),
        );
        await store.upsert(
          const ForecastRiskDecision(
            ownerKey: 'gmail:lic',
            targetMonth: '2026-08',
            status: ForecastRiskDecisionStatus.pending,
          ),
          now: DateTime(2026, 7, 22),
        );

        final rows = await store.all();
        expect(rows, hasLength(2));
        expect(rows.map((r) => r.ownerKey).toSet(), {
          'seasonal:utilities',
          'gmail:lic',
        });
      },
    );

    test('allows the same owner with different target months', () async {
      final store = await openStore();

      await store.upsert(
        const ForecastRiskDecision(
          ownerKey: 'seasonal:utilities',
          targetMonth: '2026-08',
          status: ForecastRiskDecisionStatus.confirmed,
        ),
        now: DateTime(2026, 7, 22),
      );
      await store.upsert(
        const ForecastRiskDecision(
          ownerKey: 'seasonal:utilities',
          targetMonth: '2026-09',
          status: ForecastRiskDecisionStatus.pending,
        ),
        now: DateTime(2026, 7, 22),
      );

      final rows = await store.all();
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.targetMonth).toSet(), {'2026-08', '2026-09'});
    });

    test('rejects invalid yyyy-mm target month format', () async {
      final store = await openStore();

      expect(
        () => store.upsert(
          const ForecastRiskDecision(
            ownerKey: 'seasonal:utilities',
            targetMonth: '2026/08',
            status: ForecastRiskDecisionStatus.confirmed,
          ),
          now: DateTime(2026, 7, 22),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects negative amount overrides', () async {
      final store = await openStore();

      expect(
        () => store.upsert(
          ForecastRiskDecision(
            ownerKey: 'seasonal:utilities',
            targetMonth: '2026-08',
            status: ForecastRiskDecisionStatus.confirmed,
            amountOverridePaise: -100,
          ),
          now: DateTime(2026, 7, 22),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
