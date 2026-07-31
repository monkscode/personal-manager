# TASK-18 — Algorithm guesses marked user-confirmed; due dates in the past

**Severity:** Important ×2 · **Phase:** 2 · **Depends on:** TASK-01 (shares the cadence-advance code)

---

## Defect 1 — algorithm-detected commitments are stamped user-confirmed

`lib/services/recurring_obligation_candidates.dart:68-71` →
`lib/services/reconciliation_matcher.dart:141` →
`lib/services/forecast_adapter.dart:572-575`

`_toObligation` sets:

```dart
userCadenceStatus: algorithmDetected,   // "Algorithm-detected until the user confirms
                                        //  the cadence in review"
...
reviewStatus: ObligationReviewStatus.confirmed,   // <-- two lines later
```

The comment and the code directly contradict each other.

The matcher converts `reviewStatus == confirmed` into `isUserConfirmed: true`
(`reconciliation_matcher.dart:141`), and `_isHard` returns true on
`event.isUserConfirmed` (`forecast_adapter.dart:572-575`).

**The flag is load-bearing.** `kReserveHardConfidence = 0.8`, but a plain 3-occurrence
commitment has confidence `0.7` (`lib/services/recurring_debit_detector.dart:183`). So
`isUserConfirmed` is the *only* reason these events skip the review lane and are treated
as hard commitments in the reserve plan.

An algorithm's guess is being presented to the user as their own confirmed decision.

### Fix

Set `reviewStatus: needsReview` for algorithm-detected records. Then verify the downstream
consequence: these commitments will now correctly land in the review lane rather than
silently hardening the forecast. Some tests will need updating — that is the correct
direction, not a regression.

Note TASK-02 makes `reviewStatus` a user-owned column that scans no longer overwrite, so
once a user *does* confirm, it will stick. These two tasks are complementary.

---

## Defect 2 — `nextExpected` can be in the past; `now` is accepted and ignored

`lib/services/recurring_debit_detector.dart:102-113, 116-127, 194`

`detect` and `possibleRecurring` both take `required DateTime now` and **never read it**.

```dart
nextExpected = _addCadence(sorted.last.txnDate, cadence);
```

This advances exactly **one** period from the last *observed* payment.

`test/recurring_debit_detector_test.dart:66-78` bakes the bug in: history ends 10 April,
`_now` is 1 July, and the test asserts `nextExpected == 2026-05-10` — two months in the
past.

That value flows into `ObligationRecord.dueDate`
(`recurring_obligation_candidates.dart:61`), and the matcher uses `obligation.dueDate`
verbatim (`reconciliation_matcher.dart:102-104`). So the engine files a **live monthly
commitment as a `futureEarmark` dated in the past** — excluded from the ledger.

### Fix

Roll `nextExpected` forward by whole cadence periods until it is `>= now`:

```dart
var next = _addCadence(sorted.last.txnDate, cadence);
while (next.isBefore(now)) {
  next = _addCadence(next, cadence);
}
```

Then **update the test at `:66-78`** — it currently asserts the wrong value.

**Coordinate with TASK-01:** `_addCadence` also has the month-end overflow bug
(`recurring_debit_detector.dart:268-276`). If TASK-01 is merged, the clamped helper is
already available and this loop will behave correctly for month-end cadences. If not,
expect `31 Jan → 3 Mar` and do TASK-01 first.

---

## Related, lower confidence — one skipped month unlocks a real commitment

A bounced auto-debit produces a ~60-day gap, `_cadence` returns null, and twelve months of
history never locks into a recurring commitment.

It degrades to a review candidate rather than disappearing, so it is **not silent** — but
it is a meaningful false negative. Consider a tolerance for one missed period. Record the
decision here either way.

---

## Tests to write first

Add to `test/recurring_obligation_candidates_test.dart`:

- [ ] An algorithm-detected candidate has `reviewStatus == needsReview`, not `confirmed`.
- [ ] It is therefore **not** `isUserConfirmed` downstream, and does **not** pass `_isHard`
      at confidence 0.7.
- [ ] After a user confirms it, it *does* harden (and TASK-02 keeps that across rescans).

Add to `test/recurring_debit_detector_test.dart`:

- [ ] History ending 10 April with `now` = 1 July → `nextExpected` is **10 July**, not
      10 May. (This replaces the assertion at `:66-78`.)
- [ ] `nextExpected` is never before `now` for any cadence.
- [ ] Month-end cadence: history ending 31 Jan, `now` = 15 Mar → `nextExpected` is
      31 Mar (via the clamped helper).
- [ ] `now` is genuinely used — a test that changes only `now` changes the result.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Algorithm-detected records use `needsReview`
- [ ] `nextExpected` rolls forward past `now`
- [ ] The stale assertion at `recurring_debit_detector_test.dart:66-78` is corrected
- [ ] Skipped-month tolerance decided and recorded
- [ ] All seven tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Stop marking algorithm guesses as user-confirmed and roll due dates forward`
