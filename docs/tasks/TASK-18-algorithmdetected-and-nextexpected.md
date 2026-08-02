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

## Decision — no skipped-month tolerance (not added)

A bounced auto-debit produces a ~60-day gap, `_cadence` returns null, and twelve months of
history never locks into a recurring commitment. It degrades to an
`irregularRepeatingDebit` review candidate, so it is surfaced, not silent.

**Not adding a tolerance.** The two failure directions are not symmetric. Today's false
negative costs a review prompt — the user sees the group and can confirm it. A tolerance
that reads a ~60-day gap as monthly also makes a genuinely bi-monthly series look monthly,
which *doubles* that commitment in the forecast and overstates required-in-bank. Given this
layer exists to answer "how much do I need in the bank", inflating a commitment silently is
the worse error, and the safe failure already has a user-visible escape hatch.

Revisit if review-queue volume becomes the complaint; a tolerance keyed on "the amount and
day-of-month both still match the established pattern" would be far narrower than widening
the raw gap window.

## Correction — the roll-forward must step from the original day

Iterating `next = _addCadence(next, cadence)` on the *clamped result* drifts a month-end
cadence: 31 Jan → 28 Feb → 28 Mar → 28 Apr. Each step is therefore measured from the last
observed date with a period multiplier, so 31 Jan + 2 periods is 31 March.

---

## Tests to write first

Add to `test/recurring_obligation_candidates_test.dart`:

- [x] An algorithm-detected candidate has `reviewStatus == needsReview`, not `confirmed`.
      — **RED** (`confirmed`)

Add to `test/reconciliation_matcher_test.dart` — the downstream consequence is measured
where `_isHard`'s inputs are actually produced:

- [x] It is therefore **not** `isUserConfirmed` downstream, and does **not** pass `_isHard`
      at confidence 0.7.
- [x] After a user confirms it, it *does* harden (and TASK-02 keeps that across rescans).

Add to `test/recurring_debit_detector_test.dart`:

- [x] History ending 10 April with `now` = 1 July → `nextExpected` is **10 July**, not
      10 May. (This replaces the assertion at `:66-78`.) — **RED**
- [x] `nextExpected` is never before `now` for any cadence. — **RED**
- [x] Month-end cadence: history ending 31 Jan, `now` = 15 Mar → `nextExpected` is
      31 Mar (via the clamped helper). — **RED** (28 Feb — the drift above)
- [x] `now` is genuinely used — a test that changes only `now` changes the result. — **RED**

**Three further stale assertions were found and corrected**, all the same defect the plan
named at `:66-78`: `quarterly cadence locks` expected Oct 2025, `annual cadence locks`
expected Jun 2026, and `a month-end monthly cadence advances to the last day` expected Feb
2026 — every one a date already in the past relative to the test's own `now`. The month-end
one now reads from 5 Feb so it still proves the clamp rather than the roll-forward.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Algorithm-detected records use `needsReview`
- [x] `nextExpected` rolls forward past `now`
- [x] The stale assertion at `recurring_debit_detector_test.dart:66-78` is corrected, plus
      three others carrying the same past date
- [x] Skipped-month tolerance decided and recorded — not added, reasoning above
- [x] All seven tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **728 passing** (was 722)
- [x] Suggested commit: `Stop marking algorithm guesses as user-confirmed and roll due dates forward`
