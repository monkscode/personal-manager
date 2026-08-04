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
    this.updatedAt,
  });

  final String ownerKey;
  final String targetMonth; // yyyy-mm format
  final ForecastRiskDecisionStatus status;
  final int? amountOverridePaise;
  final DateTime? dueDateOverride;

  /// When this decision was last written, or null for one that has never been
  /// stored. The store has always recorded it; nothing read it back, so the
  /// age of a decision the user made was unavailable to everything above the
  /// database (TASK-27 M2).
  final DateTime? updatedAt;

  ForecastRiskDecision copyWith({
    String? ownerKey,
    String? targetMonth,
    ForecastRiskDecisionStatus? status,
    int? amountOverridePaise,
    DateTime? dueDateOverride,
    DateTime? updatedAt,
  }) {
    return ForecastRiskDecision(
      ownerKey: ownerKey ?? this.ownerKey,
      targetMonth: targetMonth ?? this.targetMonth,
      status: status ?? this.status,
      amountOverridePaise: amountOverridePaise ?? this.amountOverridePaise,
      dueDateOverride: dueDateOverride ?? this.dueDateOverride,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
