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
  /// A future-dated anchor is rejected outright. [BalanceAnchor.freshnessAsOf]
  /// classifies a *negative* age as `current`, so one bad SMS timestamp would
  /// otherwise produce an anchor that is permanently fresh and permanently wins
  /// selection — pinning the opening balance to a reading that never happened.
  ///
  /// Anchor *freshness* (current/amber/stale) is still decided downstream by
  /// the ledger engine; only the impossible case is filtered here.
  static BalanceAnchor? select({
    BalanceAnchor? smsAnchor,
    BalanceAnchor? manualAnchor,
    required DateTime now,
  }) {
    final sms = _rejectFutureDated(smsAnchor, now);
    final manual = _rejectFutureDated(manualAnchor, now);
    if (sms == null) return manual;
    if (manual == null) return sms;
    // Newest wins; on an exact tie the SMS bank balance is preferred.
    return manual.asOf.isAfter(sms.asOf) ? manual : sms;
  }

  static BalanceAnchor? _rejectFutureDated(
    BalanceAnchor? anchor,
    DateTime now,
  ) => anchor != null && anchor.asOf.isAfter(now) ? null : anchor;
}
