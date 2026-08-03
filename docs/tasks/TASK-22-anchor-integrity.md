# TASK-22 — Float-parsed balance; phantom ₹0 anchor at 0.9 confidence

**Severity:** Important ×2 · **Phase:** 3 · **Depends on:** nothing

The balance anchor is the starting point of every forecast. Both defects corrupt it.

---

> **Premise check (2026-08-03).** Both headline defects are real and were fixed.
> Four supporting premises did not survive contact with the source and are corrected
> inline below: the `47000.005` row of the table, the "1-2 August" window, the scope of
> the `possiblyAlreadyPaid` damage, and — the one that would have defeated the fix — the
> claim that `possiblyAlreadyPaid` is the only branch with this root cause. Every line
> number in the original file had drifted.

## Defect 1 — the manual balance anchor is parsed with floating point

`lib/services/forecast_adapter.dart:275-283` (was quoted as 273-281)

```dart
BalanceAnchor? _manualAnchor(AppState state, DateTime now) {
  final rupees = double.tryParse(state.currentBalance.trim());
  if (rupees == null || rupees <= 0) return null;
  return BalanceAnchor(
    amountPaise: (rupees * 100).round(),
    ...
```

`lib/core/money.dart` exists precisely to stop this. Its own doc comment says:

> This parser intentionally avoids summing or multiplying floating-point values.

### Three demonstrable failures

| Input | `double` path | `MoneyParser` |
|---|---|---|
| ~~`"47000.005"`~~ → `"40000.005"` | `4000000.4999999995` → rounds to **4000000** | **4000001** |
| `"1,20,000"` | `double.tryParse` returns **null** → **the anchor silently disappears** | 12000000 |
| `"1e9"` | accepted as a **billion rupees** | rejected |

**Corrected premise — the rounding example was wrong.** Measured with `dart run`:
`47000.005 * 100` is *exactly* `4700000.5` as a double and `.round()` gives **4700001**,
identical to `MoneyParser`. That input does not demonstrate the defect and a test written
on it passes against the unfixed code. The failure is real but sparser than the table
implied — it needs a rupee value whose ×100 lands just *below* the .5 boundary.
`40000.005` → `4000000.4999999995` → **4000000**, losing a paise; so do `40000.325`,
`8.325`, `1.005`. The test now uses `40000.005`.

The second row is the worst: Indian digit grouping is the *normal* way a user types a
balance. When it fails, `_manualAnchor` returns null and the code falls back to a stale
SMS anchor — or to the fabricated ₹0 anchor in Defect 2.

### Fix

Use `MoneyParser.tryParseRupeesToPaise(state.currentBalance)`. It already implements the
Indian-vs-Western grouping rules (`money.dart:57-69`) and an int64 overflow guard
(`money.dart:35-38`).

---

## Defect 2 — the fabricated zero anchor is presented as 0.9-confidence and non-provisional

`lib/services/forecast_adapter.dart:263-268` (was 261-266) and
`lib/services/forecast_ledger_engine.dart:79-87` (was 71-79)

When neither an SMS balance nor a manual balance exists, the adapter synthesises:

```dart
BalanceAnchor(
  amountPaise: 0,
  asOf: targetMonth,
  source: BalanceAnchorSource.projectedCarryForward,
)
```

Because the source is `projectedCarryForward`, the ledger takes the **projection branch**
and stamps opening confidence `_carryForwardConfidence(0) = 0.9` — a value meant for a
close carried forward from a **real** anchor. It also skips the stale-anchor coverage line
by construction (`forecast_ledger_engine.dart:152`, was quoted as :144), and
`isProvisional` is derived purely from freshness (`forecast_adapter.dart:213`).

### Failing scenario

**Corrected premise — the window is wider than "1-2 August", in both directions.**

`snapshot.targetMonth` is `DateTime(now.year, now.month)`, so `asOf` is always the **1st
of the month at 00:00**. `freshnessAsOf` buckets `<=1` day as `current` and `<=5` as
`amber`, and `isProvisional` fired only on `stale` — so with no balance evidence the
headline reads **non-provisional for the first six days of every month**, not two.

The confidence half is worse still: `isProjection` short-circuits the freshness switch
entirely, so the **0.9 is stamped on every day of every month**, including once the anchor
has gone stale and the headline *has* turned provisional. Freshness never touched it.

Either way the headline renders on a balance the app has never observed.

### Fix

Give the fabricated anchor its own source (or a `hasEvidence` flag) that forces
`isProvisional == true` **and** a `confirmBalance` coverage line, regardless of date.

### This task also owns a reconciliation defect with the same root cause

`possiblyAlreadyPaid` treats the fabricated anchor as a **safe** anchor.

The spec rule (§7):

> Do not auto-subtract a past-due obligation again unless the user marks it unpaid **or
> there is no safe balance anchor after the due date.**

`lib/services/forecast_reconciliation_engine.dart:317-332` (was quoted as 253-268) only
checks `!dueDate.isAfter(anchor.asOf)` and **ignores `anchor.source` and freshness
entirely**. Both `lib/data/sms_analysis_snapshot.dart:215-221` (was 192-198) and
`forecast_adapter.dart:263-268` construct a zero-amount `projectedCarryForward` fallback
when no anchor exists.

**Corrected premise — the scope, and the missing second branch.**

*Scope.* "*Every* obligation due earlier this month" is overstated. The adapter's
fabricated anchor is dated `targetMonth` — the 1st at 00:00 — so `!dueDate.isAfter(asOf)`
only catches obligations due **on or before the 1st**: in practice the first-of-month
rent/EMI/mandate cluster, plus anything carried in from a prior month. An obligation due
on the 5th was never affected. (The two fabrication sites are also not interchangeable:
the snapshot's `asOf = now` copy is consumed only by `ReconciliationMatcher._remainingDays`
for spreading discretionary spend, never by this check. Checked — its day-window behaviour
is driven by actuals, not by the balance, so it needs no change.)

*The branch the file missed.* Gating only `possiblyAlreadyPaid` **does not fix the
defect** — it moves it. The item falls straight through to the next branch,
`forecast_reconciliation_engine.dart:334` `if (!eventDate.isAfter(anchor.asOf))`, and is
bucketed `alreadyInAnchor` instead: same root cause, same silent omission, one line lower.
`ForecastLedgerEngine._isAlreadyInAnchor` has an identical check on the same anchor. All
three had to be gated together. The coherent rule, and the one implemented:

> An anchor with no evidence behind it covers **nothing**. No amount may be presumed paid
> against it and no amount may be presumed already inside it.

Treat `hasEvidence == false` as "no safe anchor" and keep the item as a dated event.

---

---

## What was implemented

`BalanceAnchor` gains `hasEvidence` (defaults `true`). It is `false` at the two
fabrication sites, propagates through `buildRollingMonths` to every carried-forward month,
and is read in four places:

| Site | Before | After |
|---|---|---|
| `forecast_adapter._manualAnchor` | `double.tryParse` × 100 | `MoneyParser.tryParseRupeesToPaise` |
| `forecast_adapter` `isProvisional` | `freshness == stale` | `!hasEvidence \|\| freshness == stale` |
| `forecast_ledger_engine.buildMonth` | opening confidence 0.9 | `0.0`, plus a `noBalanceEvidence` / `confirmBalance` coverage line |
| `forecast_ledger_engine._isAppliedEvent` / `_isAlreadyInAnchor` | date vs `asOf` | evidence-free ⇒ applied, never "already in anchor" |
| `forecast_reconciliation_engine._applyWinner` | `possiblyAlreadyPaid` **and** `alreadyInAnchor` gated on date alone | both additionally gated on `hasEvidence` |

New `CoverageReason.noBalanceEvidence` (distinct from `staleAnchor`: absent evidence, not
out-of-date evidence), labelled in `why_log_screen.dart`.

**Two decisions recorded.**

1. **A stale *real* anchor still absorbs an overdue obligation.** Only *absent* evidence
   disqualifies an anchor here. A stale SMS balance is still a balance the bank reported
   after the due date, so re-subtracting would risk double-counting something already
   paid — the opposite failure. Staleness keeps its own `staleAnchor` coverage line.
   Asserted explicitly in `test/forecast_reconciliation_engine_test.dart`.
2. **Opening confidence is `0.0`, not a reduced non-zero value.** `ForecastExplorer` takes
   the **minimum** over line, event and coverage confidences (`forecast_explorer.dart:169`),
   so an evidence-free forecast now reports **0% (provisional)**. That is the intended
   consequence, not a side effect: a forecast built on a balance nobody has ever seen has
   no confidence to report. The coverage line itself carries confidence `1` — the absence
   of evidence is certain.

Coverage lines are rendered per selected month, so the per-month `noBalanceEvidence` line
does not multiply into the why-log (checked against TASK-16's line-volume concern).

## Tests written first — RED symptoms recorded

`test/forecast_adapter_test.dart` (`_task22`):

- [x] `currentBalance = "1,20,000"` → ₹1,20,000. **RED:** `Expected: manualUserEntry
      Actual: projectedCarryForward` — the anchor disappeared entirely.
- [x] `currentBalance = "40000.005"` → 4000001 paise. **RED:** `Expected: <4000001>
      Actual: <4000000>`. (Written first against `47000.005` per the task file; it
      **passed**, which is what exposed the wrong premise above.)
- [x] `currentBalance = "1e9"` → rejected. **RED:** `Expected: not manualUserEntry
      Actual: manualUserEntry`.
- [x] `currentBalance = "  50000  "` → parses. **GUARD** — passed before and after; not
      regression coverage.
- [x] No SMS and no manual balance → provisional, opening confidence not 0.9,
      `confirmBalance` coverage line. **RED:** `isProvisional Expected: true Actual: <false>`.
- [x] A real fresh SMS anchor stays non-provisional with no `confirmBalance` line.
      **GUARD** — passed both ways.
- [x] *(added)* A first-of-month obligation is not swallowed. **RED:** `Expected: empty
      Actual: [ForecastCoverageLine]` — a `possiblyAlreadyPaid` line for money still owed.

`test/forecast_ledger_engine_test.dart` (`_task22`):

- [x] Fabricated opening is not stamped 0.9. **RED:** `Expected: not <0.9> Actual: <0.9>`.
- [x] *(added)* An event dated on the anchor is applied, not bucketed `alreadyInAnchor`.
      **RED:** `Expected: empty Actual: [ForecastLine]` — the rent left the ledger without
      ever being subtracted. This is the branch the task file missed.
- [x] The absence of evidence carries into every projected month. **RED:** `Expected: not
      <0.9> Actual: <0.9>` at offset 0.
- [x] A real carried-forward anchor still opens at 0.9. **GUARD** — passed both ways.

`test/forecast_reconciliation_engine_test.dart` (`_task22`):

- [x] Evidence-free anchor keeps an overdue obligation dated. **RED:** `Expected: false
      Actual: <true>`.
- [x] A real anchor dated after the due date still absorbs it. **GUARD**.
- [x] A stale real anchor still absorbs it — decision 1 above. **GUARD**.

`test/money_test.dart`:

- [x] `"1,2345"` / `"1,23,4567"` / `"12,3,456"` → null.
- [x] `"12,34,567"` and `"1,20,000"` → Indian grouping accepted.
- [x] `"1,234,567"` → Western grouping accepted.
- [x] int64 boundary: `92233720368547758.07` accepted, `...08` and wider inputs rejected.
- [x] `"1e9"` → null.

      All five are **GUARDS** — `MoneyParser` already implemented these rules, so every one
      passed against the unfixed code. They exist so the rules cannot regress now that
      `_manualAnchor` depends on them. **They are not regression coverage for a defect.**

## Verification

```bash
flutter analyze
flutter test
```

`flutter analyze` — No issues found. `flutter test` — **834 passing, 0 failing**
(815 before; +19 = 7 adapter, 4 ledger, 3 reconciliation, 5 money).

## Definition of done

- [x] `_manualAnchor` uses `MoneyParser`; no `double` touches a monetary value
- [x] Fabricated anchors are always provisional with a `confirmBalance` coverage line
- [x] The "no safe anchor" signal is wired into the `possiblyAlreadyPaid` check — **and
      into the `alreadyInAnchor` branch beside it, and into the ledger engine**, without
      which the fix is inert
- [x] All tests written failing-first, then passing; guards labelled as guards
- [x] `flutter analyze` clean, `flutter test` green
- [x] Commit: `Parse manual balances as integer paise and mark evidence-free anchors provisional`
