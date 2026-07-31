# TASK-24 — Forecast and money minors (11 items)

**Severity:** Minor · **Phase:** 3 · **Depends on:** TASK-21 through TASK-23 merged first

Eleven small items across the forecast and money slice. Independent; any order.

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

- [ ] Use integer division with an explicit remainder distribution.
- [ ] Tighten the test to bound the overshoot, not just the floor.

---

## M2 — dead early return

`lib/services/reserve_planner.dart:192`

`if (opportunities.isEmpty) return []` is unreachable — `now` is unconditionally added at
line 166.

- [ ] Remove it, or make line 166 conditional if the guard was the real intent.

---

## M3 — a bill due today is marked overdue

`lib/services/reserve_planner.dart:125`

`dueDate.isBefore(now)` marks a bill due **today at 00:00** as overdue for any `now` later
in the day.

- [ ] Compare day-only values.

---

## M4 — stale comment on a load-bearing decision

`lib/services/forecast_adapter.dart:161-162`

> Target-month events from reconciliation are always hard (already resolved by the
> reconciliation engine)

**False.** The code partitions them like everything else, and
`test/forecast_adapter_test.dart:752-790` asserts the opposite.

- [ ] Correct the comment.

---

## M5 — hard-line dedupe key can collapse two real events

`lib/services/forecast_explorer.dart:299-302`

Key is `ownerKey:millis:amount`, so two genuinely distinct events sharing an owner key,
date and amount collapse to **one** why-log line while the ledger subtracts **both**. The
why-log then fails to reconcile against `committedOutflowPaise`.

The opposite-direction case *is* tested (`test/forecast_adapter_test.dart:1402`).

- [ ] Include the item id in the key, or aggregate with a count ("2 × ₹1,180").

---

## M6 — `expectedInflowPaise` means two different things

`lib/services/forecast_explorer.dart:154-156` vs `lib/services/forecast_adapter.dart:721-739`

- `ForecastMonthPlan.expectedInflowPaise` sums **all** inflows.
- `ForecastSalaryStrip.expectedPaise` sums **salary only**.

Same word, two definitions, both exposed from the same forecast layer. The spec explicitly
forbids this.

Relatedly, `committed / expected / free` does **not** reconcile:
`opening + expected − committed ≠ closing` whenever a non-salary inflow exists.

- [ ] Rename one of them so the distinction is visible at the call site.
- [ ] Add a test asserting the three-way reconciliation holds.

---

## M7 — `outstandingPaise` left null where it is knowable

`lib/services/card_cycle_estimator.dart:66-86`

`0` in the paid branch, `statementTotal − paid` in the partial branch, but **null** in the
unpaid branch — where it is knowable (`= statementTotalPaise`).

Overpayment (`amountPaid > statementTotal`) is silently discarded.

- [ ] Set `outstandingPaise` in the unpaid branch. Decide and record what an overpayment
      should do (credit balance? review?).

---

## M8 — `money_test.dart` is three tests deep

Covers none of `tryParseRupeesToPaise`'s null paths, despite `money.dart:57-69`
implementing non-trivial Indian-vs-Western grouping rules and `money.dart:35-38`
implementing an int64 overflow guard.

- [ ] Untested inputs: `"1,2345"`, `"12,34,567"`, `"1,234,567"`, and an overflow value.
      (TASK-22 also adds these — if it is merged, verify rather than duplicate.)

---

## M9 — microsecond arithmetic on a local `DateTime`

`lib/services/forecast_ledger_engine.dart:46`

`nextMonth.subtract(const Duration(microseconds: 1))` operates on the **underlying
instant** of a local `DateTime`. In a zone with a midnight DST transition on the 1st, the
carry-forward `asOf` can land at `00:59:59.999999` on the 1st — which would make every
event dated at midnight on the 1st "already in anchor" and drop it from the month.

Not reachable in IST. Worth a UTC-normalised month boundary anyway.

- [ ] Normalise the month boundary rather than subtracting a microsecond.

---

## M10 — the 90-day window moves with time of day

`lib/services/cash_coverage_metrics.dart:33-38`

Wall-clock subtraction compared with `isAfter`, so the window edge shifts through the day
and a transaction **exactly** 90 days old is excluded.

Fine for a messaging ratio; worth day-normalising for determinism.

- [ ] Normalise to day boundaries.

---

## M11 — past-due obligations labelled "future"

`lib/services/forecast_reconciliation_engine.dart:224-234`

**Any** item outside the target month — including a **past-due unpaid** obligation — is
assigned `CoverageReason.futureEarmark` with `CoverageAction.none`. Money the user already
owes is labelled "future" and offers no action. `_forwardEarmarks`
(`forecast_adapter.dart:741-754`) then hides it entirely below the ₹10,000 floor.

Note TASK-01 removes the largest *source* of spurious out-of-month items (the date
overflow), but genuine past-due obligations remain mislabelled.

- [ ] Distinguish past-due from future. Give past-due a real action.

---

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] All eleven items addressed, or explicitly closed with a reason recorded here
- [ ] Tests added for M1, M3, M5, M6, M7 and M11 — the ones with observable behaviour change
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Tidy forecast rounding, naming and coverage edge cases`
