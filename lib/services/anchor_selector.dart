import '../data/forecast_models.dart';

/// Resolves the effective balance anchor from the two possible sources — an
/// SMS-derived bank balance and a manual (user-entered) balance — per the
/// dated-ledger rules in the design §7.
///
/// Selection rule: the newest `asOf` wins; on an exact timestamp tie the SMS
/// bank balance beats a manual entry (positive bank evidence over a typed
/// number).
class AnchorSelector {
  const AnchorSelector._();

  /// Returns the anchor that should drive the opening balance, or `null` when
  /// neither source has one.
  ///
  /// [now] is part of the stable selection contract so callers thread the same
  /// clock they use elsewhere. Anchor *freshness* (current/amber/stale) is not
  /// decided here — it is applied downstream by the ledger engine via
  /// [BalanceAnchor.freshnessAsOf].
  static BalanceAnchor? select({
    BalanceAnchor? smsAnchor,
    BalanceAnchor? manualAnchor,
    required DateTime now,
  }) {
    if (smsAnchor == null) return manualAnchor;
    if (manualAnchor == null) return smsAnchor;
    // Newest wins; on an exact tie the SMS bank balance is preferred.
    return manualAnchor.asOf.isAfter(smsAnchor.asOf) ? manualAnchor : smsAnchor;
  }
}
