# TASK-49 — A ledger slice is not a decision

**Severity:** Important · **Phase:** 10 · **Depends on:** TASK-16, TASK-24, TASK-40

---

## The promise being broken

> **Every row on screen is a thing the user can act on.** A control that repeats without
> anything distinguishing the copies is not a choice, it is noise.

"Unconfirmed risk" on Home asked the user to Confirm, Edit or Dismiss **126 rows** where
there were six real decisions. Four of them repeated over and over — transport,
investments, utilities, groceries — with no date, no month, and nothing on screen telling
one copy from the next.

---

## What produced them

The target month's everyday spending is deliberately split **one item per category per
remaining day**, in `_seasonalItems` ([reconciliation_matcher.dart:699-739](../../lib/services/reconciliation_matcher.dart)):

```dart
final shares = _spreadPaise(residual, days.length);
for (var i = 0; i < days.length; i++) {
  items.add(ReconciliationItem(id: 'seasonal:${entry.categoryKey}:${days[i].day}', …));
}
```

That split is **correct and load-bearing**. The ledger needs a daily granularity to find a
minimum balance and the date it falls on; TASK-16 introduced the spread precisely to stop
the residual being dropped on the 28th and fabricating a "you need ₹X by 28 Jul" headline.

The defect is that the split leaked out of the ledger and into a review list. Each daily
slice failed the hard-confidence test, so each became its own risk line — and `_RiskRow`
draws only `label` and `amountPaise`, never `line.date`, so the one field separating the
slices was invisible.

**The sharpest evidence is the two paths side by side.** A *future* month builds the same
information through `_seasonalEvents`, which emits one event per category. So the identical
estimate rendered as **4 rows for next month and 124 for this month**, purely by which code
path produced it.

| Clock | "This month" | "Next month" |
|---|---|---|
| 2026-08-07 | **126 rows** (4 categories × 31 days + 2) | 7 rows |
| 2026-09-07 | **122 rows** (4 categories × 30 days + 2) | 8 rows |

---

## Two inherited claims that were wrong

**The `isPending` key does not collide.** The handoff suspected that acting on one row
would mark every copy pending, because the key is `'risk:${r.ownerKey}'` with no month or
index. `ownerKey` is `'${owner.name}:$id'` and the seasonal `id` carries the day, so the
probe measured **126 rows, 126 distinct ownerKeys**. A guard against this would have
protected nothing.

**No money was wrong.** The daily shares sum back to the residual, so the risk buffer was
already correct: ₹5,756.25 at 2026-08-07, unchanged by the fix.

---

## The fix — a group id, not a UI workaround

A slice now declares what it is a slice *of*. `ReconciliationItem.groupId` marks the daily
pieces of one category as one reviewable thing; the forecast collapses them into a single
line and keys the decision on the group.

Grouping is opt-in by construction: an event with no group id is keyed **by position**, so
two unrelated events that happen to share an owner key can never be folded together.

**Confirming a group had to be handled or it would have shipped a money defect.**
`_applyOverride` writes `amountOverridePaise` onto every event it touches, and the row now
shows the *month's* total — so applied slice by slice it would charge the whole month on
every day of the group. Proven by mutation, not by reasoning: reverting the branch turned
₹30,001 into **₹90,003**. The unit now redistributes the confirmed total across its own
days.

**A grouped row's date is not a due date.** The Edit dialog pre-fills `dueDateOverride`
from `line.date`, and Confirm passes `r.date`, so an override is *always* present and never
signals user intent. Honouring it would collapse a month of everyday spending onto one day
and give the ledger a worse minimum than the one TASK-16 built. For a multi-slice unit the
amount is the user's to restate; the dates stay the app's.

---

## Measured, at two clocks, on a database byte-identical to the device's

| | Before | After |
|---|---|---|
| Rows, "This month" @ 2026-08-07 | 126 | **6** |
| Rows, "This month" @ 2026-09-07 | 122 | **6** |
| Risk buffer @ 2026-08-07 | ₹5,756.25 | **₹5,756.25** |
| Risk buffer @ 2026-09-07 | ₹2,72,311.01 | **₹2,72,311.01** |
| "Next month" rows | 7 / 8 | 7 / 8 |

**The ledger did not move.** Closing balance, minimum balance and its date, shortfall,
required-in-bank, committed outflow and expected inflow were captured for all 12 horizon
months at both clocks, before and after — 24 rows, **byte-identical**. Risk lines never
enter the ledger, and none of the three stored risk decisions is seasonal, so there is
nothing to migrate.

Suite 1066 pass, `flutter analyze` clean.

---

## Still open — the slices start on day 1

At a 2026-08-07 clock the rows are dated from **Aug 1**: `_remainingDays` falls back to
`first = 1` when the anchor is not inside the target month
([reconciliation_matcher.dart:745-756](../../lib/services/reconciliation_matcher.dart)), so
days already past are presented as spending still ahead.

Deliberately not fixed here. It is a different behaviour from the duplication, and now that
a category reviews as one line it is no longer visible on screen — which may mean it is not
worth fixing at all. It still affects *where* the residual sits in the month, so the ledger
question is real even though the display one is gone. Needs its own before/after at two
clocks.
