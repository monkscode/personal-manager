# TASK-21 — 11 of 12 forecast months have no discretionary spend

**Severity:** Critical · **Phase:** 3 · **Depends on:** TASK-16 (reuse its netting helper) · **Done**

**Option A implemented.** Recorded per the definition of done below.

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

## One constraint the write-up above missed

`_isHard` admits an event to the ledger only when
`confidence >= kReserveHardConfidence` (0.8). Of the four seasonal confidences only
`kSeasonalConfidenceSeasonal` (0.8) clears it — `SingleYear` (0.6), `RecentOnly` (0.45) and
`Thin` (0.3) do not. So simply adding seasonal events to the horizon is **not** sufficient:
a weak estimate is partitioned into `riskLines` and never reaches the ledger, and the month
still reads as confidently in surplus.

This is also true of the target month today, so "August (offset 0) forecasts correctly" only
holds when its estimate is strong. The fix therefore does both halves: the estimate enters
the horizon *and* any month whose everyday spending did not reach the ledger — for either
reason — carries a `discretionaryNotModelled` coverage line quantifying what was left out.

## What was implemented

1. **Blocker.** `_isPriorYearTargetMonth` now compares against the **target** year, derived
   as the next occurrence of the target month at or after `now`'s month (a forecast never
   estimates a month that has passed). The target month's own partial data is still
   excluded, because its year is never strictly less than itself.
2. **Per-month estimates.** `SmsAnalysisSnapshot.reduce` calls the estimator once per
   horizon month into `horizonSeasonal` (element 0 *is* `seasonal`). `kForecastHorizonMonths`
   moved from `forecast_adapter.dart` to `forecast_models.dart` so the reducer can size the
   list without importing the adapter that consumes it.
3. **Horizon events.** `_horizonEvents` adds one seasonal event per category per future
   month. Future months have no month-to-date spend, so they take the full `S`; offset 0
   keeps TASK-16's `max(0, S − D_mtd)` netting through the reconciliation matcher, untouched.
4. **Per-month coverage.** `buildRollingMonths` gained a `horizonCoverageLines` map keyed by
   offset. It previously passed `offset == 0 ? coverageLines : const []`, so months 1-11 had
   no channel through which to report anything at all.

### Dating: one event per category per future month, on the last day

The target month spreads its residual over every remaining day (TASK-16's
`_remainingDays`). Future months do **not**. A whole-month estimate carries no intra-month
timing evidence, and spreading it per-day per-category would multiply ledger lines by ~30×
per category per month — TASK-16 already records why-log line-volume growth as a live
concern. Dating on the last day keeps the closing balance and the carry-forward chain exact.

**Known limitation:** when salary lands late in a month, spreading would show an intra-month
trough that end-dating does not. `minimumBalancePaise` for future months is therefore an
upper bound on the true trough. Month 0 — the one the headline reads — is unaffected,
because it still spreads.

## Tests

`test/seasonal_estimator_test.dart`:

- [x] Forecasting January 2027 with `now` = December 2026 includes January 2026 and reports
      `kSeasonalConfidenceSeasonal` — **RED: expected 0.8, got 0.6**
- [x] The estimator still excludes the target month's own partial data — guard (passes
      either way; it pins the half of the condition the fix must not break)

`test/sms_analysis_snapshot_test.dart`:

- [x] December is estimated higher than an ordinary month — **RED: `december.targetMonth`
      expected 12, got 8**; every horizon entry was the target month's estimate repeated
- [x] Every horizon month is estimated, not just the target month

`test/forecast_adapter_test.dart` (the ₹85k / ₹40k / ₹28k scenario):

- [x] Month 6 is not six months of discretionary spend too high — **RED: expected a
      ₹1,68,000 difference, got 0**
- [x] Carry-forward does not compound the gap — **RED: expected a ₹17,000 monthly step,
      got ₹45,000**
- [x] Every horizon month 0-11 has an estimate **or** names the omission, asserted across
      three horizons (absent / strong / too-weak) — **RED: "month 0 silently omits
      discretionary spend"**
- [x] A weak estimate is named with the amount it left out — **RED: no matching coverage
      line existed**

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `_isPriorYearTargetMonth` compares against the target period, not the current year
- [x] Option A or B implemented, and which one is recorded here — **Option A**
- [x] Every horizon month has either an estimate or a disclosure line
- [x] All six tests written failing-first, then passing — eight written; each confirmed RED
      by disabling the fix and re-running, not by assertion
- [x] `flutter analyze` clean, `flutter test` green — **815 passing** (was 807)
- [x] Suggested commit: `Model discretionary spend across the whole forecast horizon`

## Note for whoever measures this on the device

Every figure quoted in the Phase-3 task files predates TASK-33, which means it was measured
against 387 stored rows starting Nov 2025. There are now 2,058 rows starting Oct 2018, so
the estimator has real prior-year same-month data for the first time and its confidences
will move. Re-measure rather than trusting a number quoted upstream.
