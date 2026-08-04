import 'package:sqflite/sqflite.dart';

import 'forecast_risk_models.dart';

class ForecastRiskDecisionStore {
  const ForecastRiskDecisionStore(this._db);

  final Database _db;

  Future<List<ForecastRiskDecision>> all() async {
    final rows = await _db.query(
      'forecast_risk_decisions',
      orderBy: 'target_month ASC, owner_key ASC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  Future<void> upsert(ForecastRiskDecision decision, {DateTime? now}) async {
    _validateTargetMonth(decision.targetMonth);
    if (decision.amountOverridePaise != null &&
        decision.amountOverridePaise! < 0) {
      throw ArgumentError.value(
        decision.amountOverridePaise,
        'amountOverridePaise',
        'must be non-negative',
      );
    }

    await _db.insert(
      'forecast_risk_decisions',
      _toRow(decision, now: now ?? DateTime.now()),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static void _validateTargetMonth(String targetMonth) {
    final pattern = RegExp(r'^\d{4}-\d{2}$');
    if (!pattern.hasMatch(targetMonth)) {
      throw ArgumentError.value(
        targetMonth,
        'targetMonth',
        'must be in yyyy-mm format',
      );
    }
  }

  static Map<String, Object?> _toRow(
    ForecastRiskDecision decision, {
    required DateTime now,
  }) {
    return {
      'owner_key': decision.ownerKey,
      'target_month': decision.targetMonth,
      'status': decision.status.storageValue,
      'amount_override_paise': decision.amountOverridePaise,
      'due_date_override': decision.dueDateOverride?.millisecondsSinceEpoch,
      'updated_at': now.millisecondsSinceEpoch,
    };
  }

  static ForecastRiskDecision _fromRow(Map<String, Object?> row) {
    return ForecastRiskDecision(
      ownerKey: row['owner_key']! as String,
      targetMonth: row['target_month']! as String,
      status: ForecastRiskDecisionStatusStorage.fromStorageValue(
        row['status']! as String,
      ),
      amountOverridePaise: row['amount_override_paise'] as int?,
      dueDateOverride: row['due_date_override'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              row['due_date_override']! as int,
            ),
      updatedAt: row['updated_at'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['updated_at']! as int),
    );
  }
}
