# TASK-21 — 11 of 12 forecast months have no discretionary spend

**Severity:** Critical · **Phase:** 3 · **Depends on:** TASK-16 (reuse its netting helper)

The 12-month chart and every future month's "extra" are **false-safe** — the one direction
the spec forbids.

---

## The defect

`lib/services/forecast_adapter.dart:363-407` (the projection loop),
`lib/data/sms_analysis_snapshot.dart:179-184`,
`lib/services/forecast_ledger_engine.dart:34`

`SeasonalEstimator` is invoked **once**, for `targetMonth1to12: now.month`, and its output
becomes reconciliation items dated inside the target month only
(`lib/services/reconciliation_matcher.dart:437-441`).

The future-month loop in `_horizonEvents` adds:
- recurring commitments
- projected salary
- future obligation events
- canonical obligation projections

**— never a seasonal estimate.**

So for horizon offsets 1 through 11, the ledger models rent, EMIs and SIPs against full
salary with **no groceries, fuel, eating out, or shopping**.

### Failing scenario

User with ₹85,000 salary, ₹40,000 of fixed commitments, and a stable ₹28,000/month of
tracked discretionary spend.

- August (offset 0) forecasts correctly.
- September through July each project a closing balance **~₹28,000 too high**.
- The error **compounds through the carry-forward chain**.
- By offset 11 the projected opening balance is overstated by roughly **₹3,00,000**.

### And it is invisible

`buildRollingMonths` passes `coverageLines: offset == 0 ? coverageLines : const []`, so
months 1-11 have **no channel** through which to report a quantified exclusion.

The spec rule being broken:

> **No silent exclusion.** The forecast may not silently drop a material known amount and
> still show a confident surplus.

And the horizon-completeness requirement:

> Deterministic seasonal estimates, with their confidence, are part of what makes a
> horizon month complete.

---

## Blocker you must fix first

`lib/services/seasonal_estimator.dart:168-173`

`_isPriorYearTargetMonth` requires `year < currentYear`, where `currentYear = now.year`.

Forecasting **January 2027 from December 2026** excludes **January 2026** — the single most
relevant same-month observation — leaving only Jan 2025 and earlier. That also downgrades
confidence from `kSeasonalConfidenceSeasonal` to `kSeasonalConfidenceSingleYear`.

It is harmless today because the only caller passes `targetMonth1to12: now.month`. But it
**directly blocks this task**: the moment you call the estimator for future months, any
horizon crossing a year boundary silently loses its best data.

**Fix:** the condition should be *"strictly before the target month's period"*, not
*"before the current year"*.

---

## The fix

Two acceptable outcomes. Pick one and be explicit about which.

### Option A (preferred) — estimate per horizon month

`SeasonalEstimator` already takes `targetMonth1to12`. Call it for each horizon month and
date the result inside that month. This gives a genuinely seasonal 12-month view —
December's higher spend shows up in December.

Requires the blocker fix above. Reuse TASK-16's `max(0, S − D_mtd)` netting for offset 0
only; future months have no month-to-date spend, so they take the full `S`.

### Option B (minimum acceptable) — disclose the gap

Emit a per-month `quantifiedExcluded` coverage line stating the omitted discretionary
amount, so the surplus stops reading as confident. This requires plumbing `coverageLines`
through for offsets 1-11, which `buildRollingMonths` currently suppresses.

**Option B alone leaves the numbers wrong** — it just stops them lying about their own
confidence. Prefer A. If you take B, open a follow-up for A.

---

## Tests to write first

Add to `test/forecast_adapter_test.dart`:

- [ ] The ₹85k/₹40k/₹28k scenario → month 6's projected closing balance accounts for
      discretionary spend; it is **not** ~₹28,000 × 6 higher than reality.
- [ ] Every horizon month 0-11 either contains a seasonal estimate **or** carries a
      coverage line naming the omission. Assert this for all 12 — that is the invariant.
- [ ] Carry-forward does not compound a discretionary gap across months.
- [ ] A December-to-January horizon uses the prior January's data (the blocker fix).

Add to `test/seasonal_estimator_test.dart`:

- [ ] Forecasting January 2027 with `now` = December 2026 includes January 2026 in its
      sample, and reports `kSeasonalConfidenceSeasonal` rather than `SingleYear`.
- [ ] The estimator still excludes the target month's own partial data.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `_isPriorYearTargetMonth` compares against the target period, not the current year
- [ ] Option A or B implemented, and which one is recorded here
- [ ] Every horizon month has either an estimate or a disclosure line
- [ ] All six tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Model discretionary spend across the whole forecast horizon`
