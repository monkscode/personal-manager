# TASK-40 — A risk decision is a one-way door

**Phase 6. Severity: Critical.**

Opened 2026-08-05. First of the four items carried out of Phase 5. Every premise below was
re-verified against the source and against the live device before this file was written;
where the Phase-5 handover was imprecise it is corrected inline.

---

## The defect

`ForecastAdapter.build` partitions every candidate event using the stored risk decision,
and **both branches that a user decision can take are terminal**. There is no control
anywhere in `lib/` that writes a decision back to `pending`, and no surface that renders a
decided item with an action on it.

`lib/services/forecast_adapter.dart:166-192`:

```dart
for (final event in candidateEvents) {
  final monthKey = _monthKey(event.date);
  final decision = riskDecisionMap['${event.ownerKey}:$monthKey'];

  if (decision?.status == ForecastRiskDecisionStatus.dismissed) {
    continue; // dismissed — disappear entirely
  }

  if (_isHard(event, decision)) {
    hardEvents.add(_applyOverride(event, decision));
  } else {
    riskLines.add(ForecastLine(... status: ForecastLineStatus.review ...));
  }
}
```

**Door 1 — dismissed.** The `continue` fires before anything is collected. The event enters
neither `hardEvents` nor `riskLines`, so it reaches neither `ForecastMonthPlan.hardLines`
nor `.riskLines`, and no coverage line is emitted for it. It is not merely uncontrollable;
it is invisible. The only evidence it ever existed is a row in `forecast_risk_decisions`
that nothing above the database displays.

**Door 2 — confirmed.** `_isHard` (`forecast_adapter.dart:712-715`) returns true whenever
`decision?.status == confirmed`, so the event moves into `hardEvents` and out of
`riskLines`. `ForecastExplorer` then routes it to `ForecastMonthPlan.hardLines`, and
`HomeForecastExplorer` renders `hardLines` through `_rankedDrivers`
(`home_forecast_explorer.dart:245`) as `_DriverRow` — a label and an amount, no callbacks
at all. Confirm / Edit / Dismiss exist only on `_RiskRow`
(`home_forecast_explorer.dart:799-864`), which is built only from `plan.riskLines`
(`home_forecast_explorer.dart:250-278`). Confirming a line removes the only widget that
could ever un-confirm it.

Neither door is reachable from the why-log either: `WhyLogScreen` takes `riskLines` as
display-only.

### Why this is Critical rather than a papercut

The forecast's whole claim is that it is explainable and that the user is in control of the
uncertain half. A dismissed item is a **material known amount removed from the plan with no
record on screen** — the closest thing in this codebase to a direct breach of *no silent
exclusion*, and the one case where the exclusion was the user's own instruction and still
cannot be reviewed. A mis-tap on `Dismiss` is unrecoverable through the UI.

### It is already load-bearing on the device

Measured 2026-08-05 from `databases/transactions.db` (schema v5, 2,061 rows, unchanged from
the Phase-5 baseline):

| owner_key | target_month | status | override |
|---|---|---|---|
| `salary:projected` | 2026-09 | confirmed | ₹1,51,556 |
| `recurringCommitment:obl:sms_recurring:hdfc bank ltd:monthly` | 2026-09 | confirmed | ₹61,415 |
| `recurringCommitment:obl:sms_recurring:ece9ae70c53842d58abf92660f4698af:monthly` | 2026-09 | confirmed | ₹120.07 |

All three were written 2026-08-04 10:52–10:53 IST and **none of them can be cleared from the
app**. The owner-key shapes match construction exactly — `'salary:projected'` at
`forecast_adapter.dart:410` and `'$ownerName:obl:${obl.dedupeKey}'` at
`forecast_adapter.dart:620` with `'recurringCommitment'` for `smsRecurring` at line 668.

---

## The fix

Expose the decided items so a decision can be reversed, and make reversal write
`ForecastRiskDecisionStatus.pending`.

**Why `pending` rather than deleting the row.** Verified against the three consumers: a
`pending` decision is already, in every respect, equivalent to no decision at all.
`_isHard` tests only for `confirmed` and falls through to the natural predicates;
`_applyOverride` returns the event untouched for any non-`confirmed` status
(`forecast_adapter.dart:723`); the `dismissed` `continue` does not fire. So `pending`
restores the pre-decision partition exactly, needs no new store method, and leaves the
decision history intact rather than destroying it. This mirrors TASK-37's retire-never-delete
rule.

### 1. Model — a decided line carries its status

New class in `lib/data/forecast_models.dart` (which may import
`forecast_risk_models.dart`; that file has no imports of its own, so there is no cycle):

```dart
class ForecastDecidedLine {
  const ForecastDecidedLine({required this.line, required this.status});
  final ForecastLine line;
  final ForecastRiskDecisionStatus status;
}
```

### 2. Adapter — collect both branches

- `ForecastOutlook` gains `decidedLines` (default `const []`).
- In the partition loop, a `dismissed` decision appends a `ForecastDecidedLine` **before**
  the `continue`, built from the *unmodified* event (an override on a dismissed decision
  must not be applied — it was never applied to the ledger either).
- A `confirmed` decision appends a `ForecastDecidedLine` alongside `hardEvents.add(...)`,
  built from the event **after** `_applyOverride`, so the row the user sees is the amount
  actually in the plan.
- A `pending` decision appends **nothing**. Pending is the absence of a decision, and
  rendering an Undo for it would offer to undo nothing.

`decidedLines` is a control surface, not a ledger input. Nothing sums it. `riskBufferPaise`,
`committedOutflowPaise` and `expectedInflowPaise` all read `riskLines` / `monthResult.events`
and are untouched — confirm this rather than assume it.

### 3. Explorer — filter per month

`ForecastMonthPlan` gains `decidedLines`, filtered by `line.date`'s month using the existing
`_linesForMonth` convention. Required (not defaulted) so no construction site inherits a
default silently — the same reasoning that made `ForecastLine.direction` required in
TASK-35.

### 4. UI — two affordances

**Do not render confirmed items in a second section.** They are already on screen under
"Drivers"; listing the same ₹61,415 twice is exactly the double-print TASK-38 removed.

- **Drivers.** A `_DriverRow` whose `ownerKey` appears among this month's *confirmed*
  decided lines gains an `Undo` action that writes `status: pending`. Match on `ownerKey`,
  **not** on object identity or on a flag stamped onto the line: `_hardLinesForMonth`
  substitutes a matching reconciliation line for the event-derived one when amount and date
  agree (`forecast_explorer.dart:313-327`), and a plain `Confirm` passes the line's own
  amount and date as the override — so the substituted line would carry no flag. `ownerKey`
  survives the substitution.
- **Dismissed.** A new section, rendered only when this month has dismissed decided lines,
  listing label and amount with a `Restore` action that writes `status: pending`.

Both reuse `_handleRiskAction`, so they inherit its in-flight guard and error snackbar.

### Considered and declined

Emitting a `ForecastCoverageLine` for each dismissed item. The new section names the
amount and the reason on the surface the user is already looking at, which is what *no
silent exclusion* asks for; a coverage line would name the same rupee a second time in the
why-log and re-open TASK-38's duplication. Revisit only with a measurement.

---

## Tests — written first, with the RED each one produced

`decidedLines` did not exist, so the first run was compile-blocked rather than a behavioural
failure at both the adapter and the explorer. In each case the field was added as **inert
plumbing** (declared, defaulted / passed `const []`, never written) and the suite re-run to
get a real behavioural RED, as recorded below.

**Adapter** (`test/forecast_adapter_test.dart`)

1. `dismissed decision is still reported as a decided line` —
   **RED: `Bad state: No element` from `singleWhere` on `outlook.decidedLines`.**
   Also asserts the ledger and `riskLines` still exclude it: reporting must not re-book it.
2. **Guard, one-in-one-out** — `insuranceAppearances` counts the candidate across
   `{months[].events, riskLines, decidedLines}` and asserts 1 for a dismissal, 2 for a
   confirmation (in the ledger once, reported once). Phase 5's lesson: a number is only
   evidence once you know which collection it came from.
3. `confirmed decision is reported as a decided line at the override` —
   **RED: `Bad state: No element`.** Asserts the entry carries the **overridden**
   ₹75,000 / 20 Feb, not the original ₹60,000 / 15 Feb.
4. `pending decision produces no decided line` — **this passed against the inert plumbing,
   so it is a guard, not regression coverage.** It is here so a later "collect every
   decision" simplification cannot start offering to undo a non-decision.

**Explorer** (`test/forecast_explorer_test.dart`)

5. `lands in its own month and not in a neighbouring one` —
   **RED: `Expected: ['July dismissal'] Actual: []`.** Also asserts `riskBufferPaise` and
   `committedOutflowPaise` stay 0: a dismissed line is a control surface, not money.

**Widget** (`test/home_forecast_explorer_test.dart`)

6. `a confirmed driver row offers Undo, and it writes pending` —
   **RED: `Found 0 widgets with text "Undo"`.** Asserts the written decision is
   `pending` with the same ownerKey and `targetMonth: '2026-07'`.
7. `a dismissed line is named on screen and can be restored` —
   **RED: `dragUntilVisible` exhausted the ListView and threw `Bad state: No element`** —
   the section did not exist at any scroll offset.
8. `a driver row with no decision offers no Undo` — **guard; passed before the fix too**,
   because no row had an Undo at all. It guards against the fix over-reaching onto rows
   that are hard on their own confidence. It scrolls the Drivers section into view first:
   asserting an absence against an unbuilt lazy `ListView` would pass for the wrong reason.

---

## Definition of done

- [x] Every test above written first, each RED confirmed and its symptom recorded here.
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — **929 passing, 0 failing** (922 before; +7).
- [x] Device: build, install, and confirm an `Undo` is present on a confirmed driver row.
- [x] One commit, imperative subject, no AI-attribution trailer.

## Device verification — 2026-08-05

Built, installed over the existing app, launched, and navigated. **No scan, no destructive
control tapped, and `Undo` deliberately not pressed** — clearing those three rows is the
user's call, and this task exists to hand them the control, not to use it.

Database reconciled **byte-identical** before and after (`cmp` on the two pulls): 2,061 rows,
`MAX(id)` 2785, `MIN(id)` 19, 1759 auto_added / 187 confirmed / 109 needs_review / 6
dismissed, 10 obligations of which 3 retired, 3 forecast_risk_decisions. Install and
navigation write nothing, as expected.

**August (offset 0) — no `Undo` on any driver row.** All ten of its drivers are hard on
their own evidence and all three stored decisions target 2026-09. The guard test's
behaviour, holding on real data.

**September (offset 1) — exactly two `Undo` controls, and they are the right two:**

| Driver row | Rendered | Stored override |
|---|---|---|
| `Salary (expected)` | ₹1,51,556 · **Undo** | `salary:projected` = 15155600 paise |
| `Hdfc Bank Ltd mandate` | ₹61,415 · **Undo** | `…:hdfc bank ltd:monthly` = 6141500 paise |

Both render the **overridden** amount, which is what `_decidedLine` is built after
`_applyOverride` to guarantee. The third decision produced no row, exactly as predicted:
its obligation is retired, so no candidate carries that owner key.

No `Dismissed` section appeared — correct, all three stored decisions are `confirmed`. That
half of the fix is covered by the widget test rather than by the device, because this
database contains no dismissal to show. Worth stating plainly: **the dismissed-restore path
is test-verified, not device-verified**, and will stay that way until someone dismisses
something.

## What this does *not* close

The inert third decision. `sms_recurring:ece9ae70c53842d58abf92660f4698af:monthly` was
retired by TASK-37's sweep (`retired_at` set, verified on the device 2026-08-05), so no
candidate event carries that owner key, so no decided line is produced for it and no `Undo`
will render. That is correct behaviour — the decision matches nothing and therefore changes
nothing — but it means the row stays in the table. Deleting it still needs a whole-file DB
overwrite. Item 4 of the Phase-5 handover is **narrowed, not closed**: two of three become
user-clearable, the third stays inert.
