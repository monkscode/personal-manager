# TASK-35 — "Unconfirmed risk" totals an uncertain salary as money going out

**Severity:** Critical · **Phase:** 5 (post-Phase-4, found via the newly-reachable surface) ·
**Depends on:** TASK-34

Recorded as finding 1 at the end of TASK-34 and promoted to its own file on 2026-08-04.
Only visible because TASK-34 made the forecast surface render: the number was always
computed, and until then nothing displayed it.

---

## The defect

`ForecastLine` carries no direction. `lib/data/forecast_models.dart:189-217` (as of
`cc943fe`) declares `label`, `amountPaise`, `source`, `date`, `ownerKey`, `status`,
`confidence`, `note`, `isUserConfirmed`, `obligationDedupeKey` — and nothing that says
which way the money moves. `ForecastEvent`, one class above it, *does* carry
`direction` (`:155`).

The partition drops it. `lib/services/forecast_adapter.dart:176-192` routes any event that
fails `_isHard` into `riskLines`, copying nine fields off the event and discarding
`event.direction` because the target type has nowhere to put it:

```dart
if (_isHard(event, decision)) {
  hardEvents.add(_applyOverride(event, decision));
} else {
  riskLines.add(
    ForecastLine(
      label: event.label,
      amountPaise: event.amountPaise,
      // ... direction is not among the copied fields
    ),
  );
}
```

The fold then sums them blind. `lib/services/forecast_explorer.dart:143-146`:

```dart
// Risk buffer: sum of risk line amounts in this month
final riskBuffer = monthRiskLines.fold<int>(
  0,
  (sum, line) => sum + line.amountPaise,
);
```

The two folds *immediately below it* (`:149-156`, `committedOutflowPaise` and
`expectedInflowPaise`) both filter on `e.direction` — but they read `monthResult.events`,
which are `ForecastEvent`s and still have one. The risk fold reads `ForecastLine`s and
cannot.

**So an uncertain credit is presented to the user as money that might have to go out.**

## Why a salary lands there at all

`_salaryProjectionConfidence` (`forecast_adapter.dart:808-813`) maps
`SalaryConfidence.detectedVariable` to **0.7**. `_isHard` (`:685-688`) requires
`confidence >= kReserveHardConfidence` (0.8). So a variable-but-real salary is projected
into every horizon month (`:402-413`, `direction: LedgerDirection.inflow`) and then
partitioned into the risk lines. This is not an edge case — it is the ordinary treatment
of anyone whose pay varies.

## Measured on the device, 2026-08-04

Samsung SM-G781B, 2,061 stored rows. August's "Unconfirmed risk" list contains
`Salary ₹1,51,556` and totals **₹2,73,425**; September totals **₹5,22,364**. The salary
credit is the largest single contributor to both.

---

## The fix

1. **`ForecastLine` gains `required LedgerDirection? direction`.**
   Required so no construction site can inherit a default and silently repeat this;
   nullable because exactly one line is not a flow — `'Opening balance'`
   (`forecast_ledger_engine.dart:130`) is a balance, and forcing `outflow` onto it would
   be a lie that the next direction-sensitive consumer inherits. All eight `lib` sites and
   fourteen test sites were audited individually; only that one passes `null`.

2. **The risk fold filters to outflows.**

   ```dart
   final riskBuffer = monthRiskLines
       .where((line) => line.direction == LedgerDirection.outflow)
       .fold<int>(0, (sum, line) => sum + line.amountPaise);
   ```

3. **The inflow stays in `riskLines`.** It is removed from the *total*, not from the
   surface — an unconfirmed credit is still something the user needs to see. Excluding it
   from the list would trade this defect for a "no silent exclusion" breach.

### Rejected: netting inflows against outflows

`riskBuffer` answers "how much might I have to pay that is not yet confirmed?". Netting a
₹1,51,556 uncertain credit against ₹1,21,869 of uncertain debits yields a negative buffer,
which is not an answer to that question. Two uncertainties do not cancel; they compound.

---

## Tests

Five added. **Three are regression coverage, two are guards** — established by reverting
the fold and re-running, not by assertion.

`test/forecast_adapter_test.dart` — group `TASK-35`, end-to-end through the real adapter
with a `detectedVariable` ₹1,51,556 salary:

| Test | Kind | RED symptom |
|---|---|---|
| `the projected salary really is partitioned as a risk line (guard)` | **Guard** | Passed before the fix. Covers the fixture, not the defect. |
| `riskBufferPaise excludes it because it is an inflow` | Regression | `Expected: <0>  Actual: <15155600>` |

`test/forecast_explorer_test.dart` — group `TASK-35 — the risk buffer totals outflows only`,
unit-level on the fold:

| Test | Kind | RED symptom |
|---|---|---|
| `an uncertain credit is left out of the total` | Regression | `Expected: <240000>  Actual: <15395600>` |
| `but it is still listed, so nothing is silently excluded (guard)` | **Guard** | Passed before the fix — the defect was in the fold, never in the list. |
| `a buffer of only credits is zero, not their sum` | Regression | `Expected: <0>  Actual: <15205600>` |

The end-to-end test earns its place over the unit test alone: the unit test needs a
`ForecastLine` with `direction: inflow`, which is only expressible *after* the fix. The
adapter test needed no production change to express, so it produced a real behavioural RED
on the unmodified tree — the `15155600` above is the device's own salary figure.

---

## Definition of done

- [x] `ForecastLine.direction` added as `required LedgerDirection?`
- [x] All 8 `lib` construction sites pass a direction; only `'Opening balance'` passes `null`
- [x] `riskBufferPaise` filters to `LedgerDirection.outflow`
- [x] Inflow risk lines remain present in `riskLines`
- [x] 5 tests added, RED confirmed by reverting the fold; 2 honestly labelled guards
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 893 passing, 0 failing (was 888)
- [ ] Device verification — deferred to the end of the batch with TASK-36/37/38

---

## Not fixed here

- **`riskBufferPaise` is still not rendered with a sign or a direction breakdown.** The
  total is now correct, and the individual inflow rows in the list still render as bare
  amounts with no `+`/`−`. A user reading the list sees `Salary (expected) ₹1,51,556`
  under the heading "Unconfirmed risk" — correct in the total, still misleading in the
  row. Presentation, and a product decision about what that section is called.
- **`confidence` still folds risk lines of both directions** (`forecast_explorer.dart:166-167`,
  `...monthRiskLines.map((r) => r.confidence)`). Taking the minimum confidence across an
  uncertain credit and an uncertain debit is defensible — both are evidence quality — so
  this is left alone deliberately rather than overlooked.
