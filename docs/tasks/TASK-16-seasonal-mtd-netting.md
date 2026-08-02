# TASK-16 — Month-to-date discretionary spend double-counted

**Severity:** Critical · **Phase:** 2 · **Depends on:** nothing

**Found independently by two reviewers** (money-math and reconciliation). Highest
confidence finding in the audit.

---

## The defect

`lib/services/reconciliation_matcher.dart:422-448` (`_seasonalItems`),
`lib/services/seasonal_estimator.dart:138-149`,
`lib/services/forecast_ledger_engine.dart:117-121`

`SeasonalEstimator._monthlyNets` produces **whole-month totals**, so its estimate is a
whole-month magnitude. `_seasonalItems` emits it as a single outflow on
`kSeasonalBufferDayOfMonth = 28`, with **no netting** against discretionary debits already
observed this month.

And those debits are **already inside the balance anchor** — unmatched actual debits are
folded into owners at `reconciliation_matcher.dart:78` and never become standalone items,
so the `debits` lane never applies `D_post_anchor` either.

### Failing scenario

Today is **22 July**. Anchor ₹40,000, read this morning. ₹7,000 of food already spent this
month. Seasonal food estimate ₹10,000 at confidence 0.8 (two prior Julys, so it clears the
`_isHard` gate).

The ledger subtracts the **full ₹10,000** on 28 July.

**₹7,000 of those rupees are counted twice** — once inside the anchor, once as a forecast
obligation. Required-in-bank is overstated by exactly the month-to-date discretionary
spend, and **the error grows every day of the month**.

### The spec rule being violated

> **Current-month discretionary formula.** The amount still to come this month is
> `max(0, S − D_mtd)`, where `S` is the seasonal estimate for the month and `D_mtd` is
> discretionary spend already observed month-to-date. Each already-spent transaction is
> shown in the why-log for traceability, but is **not** subtracted twice.

That formula is not implemented anywhere. Grep confirms no month-to-date netting exists
downstream either — `forecast_ledger_engine.dart` has no seasonal handling at all.

---

## Two knock-on defects from the day-28 placement

### The minimum-balance date is fabricated

The headline *"you need ₹X more by 28 Jul"* is an artifact of a **hardcoded constant**,
not of any real due date.

The spec asks for allocation by historical day-of-month distribution, or an even spread
over the remaining days carrying a lower-confidence label. Neither is implemented.

### The estimate vanishes on the 29th

On the 29th, `eventDate` (day 28) is no longer after `anchor.asOf`, so
`forecast_reconciliation_engine.dart:253-264` reclassifies it as `possiblyAlreadyPaid`
review. **Required-in-bank drops by the full estimate overnight**, with no user-visible
cause.

---

## The fix

1. **Net month-to-date discretionary spend out of the estimate** before dating it:
   `max(0, S − D_mtd)`. You will need `D_mtd` as a real quantity — it currently isn't
   computed anywhere, because unmatched discretionary debits are folded into owners rather
   than surfaced. Expose it from the matcher.
2. **Spread the residual over the remaining days of the month** rather than dropping it on
   day 28. This removes the fabricated date *and* the day-29 cliff in one change.
3. **Emit why-log lines for the already-spent transactions**, marked as traceability-only
   and explicitly not subtracted. The spec asks for this and it currently has no data
   source.

If a full day-of-month distribution is too large for this task, an even spread over
remaining days with a lower-confidence label is explicitly permitted by the spec — take
that and note the simplification.

---

## Interaction with TASK-21

TASK-21 fixes the *other* half of the seasonal problem: months 1-11 of the horizon have
**no** discretionary estimate at all. The two tasks touch adjacent code but different
paths (month 0 here, months 1-11 there). TASK-21 also depends on a fix in
`seasonal_estimator.dart` that this task does not need.

**Prefer doing TASK-16 first** — it is the smaller change and establishes the netting
helper that TASK-21 can reuse.

---

## Refinement — `D_mtd` must be split by the anchor, not netted wholesale

Netting *all* month-to-date spend out of the estimate is only half right, and the other
half would have introduced a fresh error. A discretionary debit is inside the anchor only
if it happened **before** `anchor.asOf`:

| when it happened | inside the anchor? | must the ledger subtract it? |
|---|---|---|
| before `anchor.asOf` | yes | **no** — already in the opening balance |
| after `anchor.asOf` | no | **yes** — real cash the balance has not seen |

So `D_mtd` is netted out of the estimate in full (it is spend that has already occurred, so
the whole-month magnitude must shrink by it), **and** each already-spent transaction is
emitted as its own item. The engine then decides its bucket from its own date: pre-anchor
becomes `anchorIncluded` and is not subtracted, post-anchor becomes a dated event and is.
Netting wholesale without emitting the items would have *lost* post-anchor spend entirely.

This also closes a quieter hole: an unmatched discretionary debit previously produced **no
item at all**, so it was invisible to the completeness assertion and to the why-log.

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

- [x] The 22-July scenario → the seasonal outflow is **₹3,000** (₹10,000 − ₹7,000), not
      ₹10,000. — **RED** (₹10,000)
- [x] `D_mtd` greater than `S` → the seasonal outflow is **zero**, never negative. —
      **RED** (₹10,000)
- [x] The residual is spread across the remaining days, not dropped on day 28. — **RED**
      (a single item on the 28th)
- [x] On the 29th the estimate does **not** disappear — running the forecast on the 28th
      and the 29th gives near-identical required-in-bank (no overnight cliff). — **RED**,
      and worse than the plan claimed: the 29th produced **zero** discretionary outflow.
- [x] Already-spent discretionary transactions appear as why-log lines marked
      traceability-only and are not included in `committedOutflowPaise`. — asserted as
      `anchorIncluded` / `alreadyInAnchor`, which the ledger keeps out of `events`, so the
      adapter's committed total cannot pick them up.
- [x] Added beyond the plan: discretionary spend **after** the anchor is still subtracted.
- [x] Rupee conservation (TASK-14 helper) holds for a month with partial discretionary
      spend — every reconcile in the file routes through it.

## Consequence worth knowing: line volume

The residual is now one item per category **per remaining day**, so a 4-category estimate
early in the month produces ~120 forecast lines where there were 4. The ledger maths is
unaffected (the shares are integer paise and sum back exactly), but the why-log renders one
tile per line and will need grouping. `forecast_adapter._isSeasonalBufferShortfall` also
gets weaker: it asks whether the minimum-balance day is driven *only* by low-confidence
seasonal events, and with a spread each day carries a small slice. Both are UI/heuristic
follow-ups, recorded here rather than avoided by keeping a single lump — a lump gives the
same minimum-balance answer but misstates the intermediate path, which is what the spec's
"even spread over the remaining days" exists to fix.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `D_mtd` computed and exposed — `_discretionaryActuals`, split by the anchor
- [x] Seasonal outflow is `max(0, S − D_mtd)`
- [x] Residual spread over remaining days; `kSeasonalBufferDayOfMonth` no longer drives
      the headline date (now `@Deprecated` and referenced by nothing)
- [x] No day-29 cliff
- [x] Why-log traceability lines emitted
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **716 passing** (was 710)
- [x] Suggested commit: `Net month-to-date spend out of the seasonal estimate`
