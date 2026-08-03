# TASK-24 — Forecast and money minors (11 items)

**Severity:** Minor · **Phase:** 3 · **Depends on:** TASK-21 through TASK-23 merged first

Eleven small items across the forecast and money slice. Independent; any order.

> **Premise check (2026-08-03).** All eleven sites were read before anything changed.
> Six items (M2, M3, M4, M5, M10, M11) were exactly as described. Three carried premises
> that did not survive: **M1** (the arithmetic fix changes no output, and the remedy the
> file proposes would make the overshoot *larger*), **M7** (the overpayment half was
> already correct, and the whole branch is unreachable from `lib/`), and **M9** (not
> reachable, as the file itself half-suspected). **M8** was already done by TASK-22.
> Every line number had drifted. Details inline.

---

## M1 — reserve contribution ceiling drift

`lib/services/reserve_planner.dart:198, 201, 209-215`

`(remainingPaise / numOpportunities).ceil()` is **double division on integer paise** (exact
below 2^53, but avoidable with `~/` plus a remainder).

More visibly: the **last** contribution re-ceils the residual after earlier contributions
were already ceiled, so `Σ contributions` can **exceed** `remainingPaise` by up to 99
paise. The spec defines one uniform `ceil(remaining / count / 100) * 100`.

`test/reserve_planner_test.dart:29-32` asserts only `greaterThanOrEqualTo(6000000)` — the
one assertion that would have pinned this.

**Corrected premises — two of the three claims here do not hold.**

1. *The double division changes no output.* `(remainingPaise / n).ceil()` is exact for
   every value below 2^53 paise (₹9×10^13). The file concedes this and it is decisive: the
   fix is **project-rule compliance** ("no `double` may touch a monetary value"), not a
   behaviour change. Nothing about the plan moves. Said plainly so nobody later mistakes
   the accompanying test for regression coverage.
2. *The proposed remedy makes the stated symptom worse.* The file complains that
   `Σ contributions` can exceed the target by up to 99 paise, then prescribes the spec's
   uniform `ceil(remaining / count / 100) * 100`. That rule gives **every** instalment the
   ceiled value, overshooting by up to `count × 99` paise. Measured on ₹10,000.50 over 7
   opportunities: the current residual-absorbing scheme totals ₹10,001.00 (50 paise over);
   uniform instalments total ₹10,003.00 (250 paise over). Some overshoot is unavoidable
   while instalments are whole rupees, so the residual-absorbing last instalment was
   **kept** — it is what holds the overshoot under one rupee.
3. *The non-whole-rupee contribution is unreachable.* `ceiledPerOpportunity.clamp(...)`
   could yield a fraction of a rupee, but only when `remaining / count` is comparable to
   100 paise — i.e. a target near `₹1 × count`, far below `kReserveMinimumPaise` (₹10,000),
   below which the obligation is offered for enabling rather than scheduled.

- [x] Integer division throughout; `_ceilToRupee` extracted. No `double` touches money.
- [x] Test bounds the overshoot at both ends — `>= target` **and** `< target + 100` — and
      asserts every instalment is a whole number of rupees. **GUARD:** it passes against
      the unfixed code, because the invariants already held above the ₹10,000 threshold.

---

## M2 — dead early return

`lib/services/reserve_planner.dart:192` (verified — unreachable exactly as described;
`now` is added unconditionally at line 166).

- [x] Removed. The rewritten distribution loop needs no guard: it iterates the
      opportunities it has and stops once the target is met.

---

## M3 — a bill due today is marked overdue

`lib/services/reserve_planner.dart:125` (verified).

`dueDate.isBefore(now)` marks a bill due **today at 00:00** as overdue for any `now` later
in the day.

- [x] Day-only comparison on both sides. **RED:** a bill due 2026-07-22 read at
      2026-07-22 14:30 gave `isOverdue Expected: false Actual: <true>`. Guard added for
      a bill due the day before, which must still be overdue.

---

## M4 — stale comment on a load-bearing decision

`lib/services/forecast_adapter.dart:154-155` (was quoted as 161-162)

> Target-month events from reconciliation are always hard (already resolved by the
> reconciliation engine)

**False.** The code partitions them like everything else, and
`test/forecast_adapter_test.dart:752-790` asserts the opposite.

- [x] Corrected. Verified against the source first: the loop at `forecast_adapter.dart:166`
      partitions `candidateEvents`, which begins as `[...reconciliation.events]`, through
      the same `_isHard` gate as everything else. The comment was simply false.

---

## M5 — hard-line dedupe key can collapse two real events

`lib/services/forecast_explorer.dart:299-302` (verified)

Key is `ownerKey:millis:amount`, so two genuinely distinct events sharing an owner key,
date and amount collapse to **one** why-log line while the ledger subtracts **both**. The
why-log then fails to reconcile against `committedOutflowPaise`.

The opposite-direction case *is* tested (`test/forecast_adapter_test.dart:1402`).

- [x] The event's index in the month's event list is now part of the key — `ForecastEvent`
      has no id to use, and the index is stable within the pass that builds the lines.
      **RED:** two ₹1,180 debits to `commitment:actfibernet` on the same day gave an
      itemised total of `Expected: <236000> Actual: <118000>` against a
      `committedOutflowPaise` of 236000.

---

## M6 — `expectedInflowPaise` means two different things

`lib/services/forecast_explorer.dart:154-156` vs `lib/services/forecast_adapter.dart:721-739`

- `ForecastMonthPlan.expectedInflowPaise` sums **all** inflows.
- `ForecastSalaryStrip.expectedPaise` sums **salary only**.

Same word, two definitions, both exposed from the same forecast layer. The spec explicitly
forbids this.

Relatedly, `committed / expected / free` does **not** reconcile:
`opening + expected − committed ≠ closing` whenever a non-salary inflow exists.

- [x] `ForecastSalaryStrip.expectedPaise` renamed to **`expectedSalaryPaise`**. That is the
      one of the two whose name was lying: `ForecastMonthPlan.expectedInflowPaise` already
      says "inflow" and means it. One `lib/` consumer (`real_insights.dart:451`) and ~20
      test fixtures updated.
- [x] Three-way reconciliation test added at the plan level:
      `opening + expectedInflow - committedOutflow == closing`. **GUARD** — it passes
      against the unfixed code, because that identity always held. The file's
      "`committed / expected / free` does not reconcile" observation is about the *salary
      strip*, where it is true and intended: the strip is a salary view, not a balance
      identity, and the rename is what makes that legible at the call site.

---

## M7 — `outstandingPaise` left null where it is knowable

`lib/services/card_cycle_estimator.dart:66-86`

`0` in the paid branch, `statementTotal − paid` in the partial branch, but **null** in the
unpaid branch — where it is knowable (`= statementTotalPaise`).

Overpayment (`amountPaid > statementTotal`) is silently discarded.

**Corrected premises.**

1. *The overpayment is not silently discarded.* The `amountPaid >= statementTotal` branch
   sets `paymentStatus = paid` and `outstanding = 0`, which is correct on both counts — a
   settled statement owes nothing, and it never goes negative. What is *not* recorded is
   the size of the resulting credit balance, and `CardCycleEstimate` has no field for one.
   **Decision: leave it.** A card credit balance is not a bank cash-flow event and adding a
   field for it would be modelling the card, not the forecast. Recorded rather than fixed.
2. *The whole block is unreachable from `lib/`.* The only production caller,
   `sms_analysis_snapshot._cardEstimates`, calls
   `estimator.estimate(txns, statementMonth: targetMonth)` — no `statementTotalPaise`, no
   `amountPaidPaise`, no `cycle`. So `statementTotalPaise != null` is false in production
   and none of the three branches runs. This is the same shape as TASK-13's recorded
   finding that `CardCycle` is never constructed in `lib/`.

- [x] `outstandingPaise` set to `statementTotalPaise` in the unpaid branch. **RED:**
      `Expected: <500000> Actual: <null>`. Correct, but reachable only from tests today.
- [x] Overpayment behaviour asserted as a **GUARD** (`paid`, `outstanding == 0`) — it
      passed unfixed, per correction 1.

---

## M8 — `money_test.dart` is three tests deep

Covers none of `tryParseRupeesToPaise`'s null paths, despite `money.dart:57-69`
implementing non-trivial Indian-vs-Western grouping rules and `money.dart:35-38`
implementing an int64 overflow guard.

- [x] **Verified, not duplicated.** TASK-22 added exactly these four plus a scientific-
      notation rejection, in a `MoneyParser.tryParseRupeesToPaise` group in
      `test/money_test.dart`, including the int64 boundary at 92233720368547758.07 /
      .08. All are labelled guards there — the parser already implemented the rules.

---

## M9 — microsecond arithmetic on a local `DateTime`

`lib/services/forecast_ledger_engine.dart:46`

`nextMonth.subtract(const Duration(microseconds: 1))` operates on the **underlying
instant** of a local `DateTime`. In a zone with a midnight DST transition on the 1st, the
carry-forward `asOf` can land at `00:59:59.999999` on the 1st — which would make every
event dated at midnight on the 1st "already in anchor" and drop it from the month.

**Confirmed not reachable**, as the file suspected: both tests written for it pass before
and after the change. They are **GUARDS**, not regression coverage.

- [x] The boundary is now built from calendar fields — `DateTime(nextMonth.year,
      nextMonth.month, 0, 23, 59, 59, 999, 999)`, day 0 being the last day of the previous
      month — instead of instant arithmetic on a local `DateTime`. Deterministic in any
      zone. Guards pin that the anchor lands on the 31st and that an event at midnight on
      the 1st still enters its month.

---

## M10 — the 90-day window moves with time of day

`lib/services/cash_coverage_metrics.dart:33-38`

Wall-clock subtraction compared with `isAfter`, so the window edge shifts through the day
and a transaction **exactly** 90 days old is excluded.

Fine for a messaging ratio; worth day-normalising for determinism.

- [x] Both ends day-normalised, and the comparison flipped from `isAfter(cutoff)` to
      `!isBefore(cutoff)` so a transaction *exactly* 90 days old is inside the window.
      **RED:** a transaction exactly 90 days old gave `Expected: length <1> Actual: []`,
      and a midday transaction on the edge day was `Expected: <0> Actual: <1>` — inside
      the window at 00:05 and outside it at 23:55 the same day. Guard added for 91 days.

---

## M11 — past-due obligations labelled "future"

`lib/services/forecast_reconciliation_engine.dart:224-234`

**Any** item outside the target month — including a **past-due unpaid** obligation — is
assigned `CoverageReason.futureEarmark` with `CoverageAction.none`. Money the user already
owes is labelled "future" and offers no action. `_forwardEarmarks`
(`forecast_adapter.dart:741-754`) then hides it entirely below the ₹10,000 floor.

Note TASK-01 removes the largest *source* of spurious out-of-month items (the date
overflow), but genuine past-due obligations remain mislabelled.

- [x] New `CoverageReason.pastDueObligation` (labelled "Past due" in the why-log), with
      `CoverageAction.review` and `ForecastLineStatus.overdue`, for an item dated before
      the target month that is not already paid. **RED:** an unpaid bill due 14 July read
      in August gave `Expected: not futureEarmark Actual: futureEarmark`. Guard added for
      a bill due next month, which must stay a future earmark.

      Side effect worth naming: `_forwardEarmarks` filters on `futureEarmark`, so past-due
      items no longer appear there — which is the point. They surface in
      `outlook.coverageLines` with an action instead of being hidden under the ₹10,000
      forward-earmark floor.

---

## Verification

```bash
flutter analyze
flutter test
```

`flutter analyze` — No issues found. `flutter test` — **855 passing, 0 failing**
(840 after TASK-23; +15).

## Which tests are regression coverage, and which are guards

| Item | Test | RED captured? |
|---|---|---|
| M3 | bill due today is not overdue | **yes** — `Expected: false Actual: <true>` |
| M5 | two same-owner same-day debits both itemised | **yes** — `Expected: <236000> Actual: <118000>` |
| M7 | unpaid statement's outstanding | **yes** — `Expected: <500000> Actual: <null>` |
| M10 | exactly-90-days-old included | **yes** — `Expected: length <1> Actual: []` |
| M10 | window does not drift through the day | **yes** — `Expected: <0> Actual: <1>` |
| M11 | past-due is not a future earmark | **yes** — `Expected: not futureEarmark Actual: futureEarmark` |
| M1 | whole rupees, overshoot under ₹1 | no — **guard** |
| M6 | plan-level three-way reconciliation | no — **guard** |
| M7 | overpayment clears to zero | no — **guard** |
| M9 | month boundary lands on the 31st | no — **guard** |
| M9 | midnight-on-the-1st event enters its month | no — **guard** |
| M3, M10, M11 | the "still behaves" counterparts | no — **guards** |

## Definition of done

- [x] All eleven items addressed. Three closed with corrections rather than as stated:
      M1 (arithmetic fix is behaviour-neutral; the file's proposed remedy rejected with
      measurements), M7 (overpayment already correct — decision to leave the credit
      balance unmodelled recorded; whole branch unreachable from `lib/`), M9 (unreachable;
      changed for determinism, tests are guards). M8 verified as already done by TASK-22.
- [x] Tests added for M1, M3, M5, M6, M7, M9, M10 and M11 — more than the file asked for,
      and each labelled above by whether it actually failed first
- [x] `flutter analyze` clean, `flutter test` green
- [x] Commit: `Tidy forecast rounding, naming and coverage edge cases`
