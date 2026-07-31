/// Risk and planning decision status for forecast obligations.
enum ForecastRiskDecisionStatus { pending, confirmed, dismissed }

extension ForecastRiskDecisionStatusStorage on ForecastRiskDecisionStatus {
  String get storageValue => switch (this) {
    ForecastRiskDecisionStatus.pending => 'pending',
    ForecastRiskDecisionStatus.confirmed => 'confirmed',
    ForecastRiskDecisionStatus.dismissed => 'dismissed',
  };

  static ForecastRiskDecisionStatus fromStorageValue(String value) =>
      switch (value) {
        'pending' => ForecastRiskDecisionStatus.pending,
        'confirmed' => ForecastRiskDecisionStatus.confirmed,
        'dismissed' => ForecastRiskDecisionStatus.dismissed,
        _ => throw ArgumentError.value(value, 'status'),
      };
}

/// User-driven risk and planning decision for a forecast obligation in a
/// specific target month. Primary key is (ownerKey, targetMonth).
class ForecastRiskDecision {
  const ForecastRiskDecision({
    required this.ownerKey,
    required this.targetMonth,
    required this.status,
    this.amountOverridePaise,
    this.dueDateOverride,
  });

  final String ownerKey;
  final String targetMonth; // yyyy-mm format
  final ForecastRiskDecisionStatus status;
  final int? amountOverridePaise;
  final DateTime? dueDateOverride;

  ForecastRiskDecision copyWith({
    String? ownerKey,
    String? targetMonth,
    ForecastRiskDecisionStatus? status,
    int? amountOverridePaise,
    DateTime? dueDateOverride,
  }) {
    return ForecastRiskDecision(
      ownerKey: ownerKey ?? this.ownerKey,
      targetMonth: targetMonth ?? this.targetMonth,
      status: status ?? this.status,
      amountOverridePaise: amountOverridePaise ?? this.amountOverridePaise,
      dueDateOverride: dueDateOverride ?? this.dueDateOverride,
    );
  }
}
