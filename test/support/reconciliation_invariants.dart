import 'package:expense_insight/data/forecast_models.dart';
import 'package:expense_insight/data/sms_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// Buckets whose rupees the forecast actually accounts for: a dated event is
/// subtracted (or added) on the ledger, and an anchor-included amount is already
/// inside the opening balance. Everything else is an *exclusion* and owes the
/// user a reason.
const _countedBuckets = {
  CoverageBucket.datedEvent,
  CoverageBucket.anchorIncluded,
};

/// Asserts the two invariants this layer advertises as enforced (spec §7):
///
/// > **One owner per rupee.** Every input amount is attributed to exactly one
/// > owner. No amount may be counted twice, and none may vanish.
///
/// > **No silent exclusion.** The forecast may not silently drop a material
/// > known amount and still show a confident surplus. Anything excluded must
/// > produce a coverage line naming what was excluded and why.
///
/// The bucket total is a structural guard rather than a bug detector: the engine
/// already asserts one assignment per input and copies each item's amount
/// verbatim, so the sum can only break if an assignment loses its amount or a
/// new [CoverageBucket] appears that nobody added here. The teeth are in the
/// coverage-line pairing below — that is the half every dropped-duplicate defect
/// breached while the id-completeness assertion stayed green.
void expectRupeeConservation(
  ForecastReconciliationResult result,
  List<ReconciliationItem> items,
) {
  int bucketTotal(CoverageBucket bucket) => result.assignments
      .where((assignment) => assignment.coverageBucket == bucket)
      .fold<int>(0, (sum, assignment) => sum + (assignment.amountPaise ?? 0));

  final inputTotal = items.fold<int>(
    0,
    (sum, item) => sum + (item.amountPaise ?? 0),
  );
  // Named one by one on purpose: a bucket added later must fail here and be
  // classified as counted or excluded, not silently join the total.
  final assignedTotal =
      bucketTotal(CoverageBucket.datedEvent) +
      bucketTotal(CoverageBucket.quantifiedExcluded) +
      bucketTotal(CoverageBucket.anchorIncluded) +
      bucketTotal(CoverageBucket.reviewPending);
  expect(
    assignedTotal,
    inputTotal,
    reason: 'every input rupee must land in exactly one coverage bucket',
  );

  final explained = {
    for (final line in result.coverageLines)
      if (line.ownerKey != null) line.ownerKey!,
  };
  for (final assignment in result.assignments) {
    if (_countedBuckets.contains(assignment.coverageBucket)) continue;
    expect(
      explained,
      contains(assignment.ownerKey),
      reason:
          '${assignment.itemId} was excluded into '
          '${assignment.coverageBucket.name} with no coverage line naming it',
    );
  }
}
