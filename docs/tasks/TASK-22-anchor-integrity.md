# TASK-22 — Float-parsed balance; phantom ₹0 anchor at 0.9 confidence

**Severity:** Important ×2 · **Phase:** 3 · **Depends on:** nothing

The balance anchor is the starting point of every forecast. Both defects corrupt it.

---

## Defect 1 — the manual balance anchor is parsed with floating point

`lib/services/forecast_adapter.dart:273-281`

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
| `"47000.005"` | `4700000.4999999995` → rounds to **4700000** | **4700001** |
| `"1,20,000"` | `double.tryParse` returns **null** → **the anchor silently disappears** | 12000000 |
| `"1e9"` | accepted as a **billion rupees** | rejected |

The second is the worst: Indian digit grouping is the *normal* way a user types a balance.
When it fails, `_manualAnchor` returns null and the code falls back to a stale SMS anchor —
or to the fabricated ₹0 anchor in Defect 2.

### Fix

Use `MoneyParser.tryParseRupeesToPaise(state.currentBalance)`. It already implements the
Indian-vs-Western grouping rules (`money.dart:57-69`) and an int64 overflow guard
(`money.dart:35-38`).

---

## Defect 2 — the fabricated zero anchor is presented as 0.9-confidence and non-provisional

`lib/services/forecast_adapter.dart:261-266` and
`lib/services/forecast_ledger_engine.dart:71-79`

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
by construction (`forecast_ledger_engine.dart:144`), and `isProvisional` is derived purely
from freshness.

### Failing scenario

On 1-2 August, with **no balance evidence at all**: `asOf = 2026-08-01` is ≤1 day old →
`AnchorFreshness.current` → `isProvisional == false`, opening confidence **0.9**.

The headline renders **without** the "Provisional — confirm your balance" prefix, on a
balance the app has never observed.

### Fix

Give the fabricated anchor its own source (or a `hasEvidence` flag) that forces
`isProvisional == true` **and** a `confirmBalance` coverage line, regardless of date.

### This task also owns a reconciliation defect with the same root cause

`possiblyAlreadyPaid` treats the fabricated anchor as a **safe** anchor.

The spec rule (§7):

> Do not auto-subtract a past-due obligation again unless the user marks it unpaid **or
> there is no safe balance anchor after the due date.**

`lib/services/forecast_reconciliation_engine.dart:253-268` only checks
`!dueDate.isAfter(anchor.asOf)` and **ignores `anchor.source` and freshness entirely**.
Both `lib/data/sms_analysis_snapshot.dart:192-198` and `forecast_adapter.dart:261-266`
construct a zero-amount `projectedCarryForward` fallback with `asOf = now` when no anchor
exists.

So for a user with **no** balance SMS and **no** manual entry, *every* obligation due
earlier this month is swallowed into "possibly already paid" and never subtracted. Their
forecast silently omits everything they still owe.

Treat `projectedCarryForward` — and arguably `AnchorFreshness.stale` — as "no safe anchor"
and keep the item as a dated overdue event. If you add a `hasEvidence` flag above, wire it
into this check too —
`forecast_reconciliation_engine.dart:253-268` should treat "no evidence" as "no safe
anchor" and keep overdue obligations as dated events rather than swallowing them into
"possibly already paid".

---

## Tests to write first

Add to `test/forecast_adapter_test.dart`:

- [ ] `currentBalance = "1,20,000"` → anchor is ₹1,20,000 (12000000 paise), not null.
- [ ] `currentBalance = "47000.005"` → 4700001 paise.
- [ ] `currentBalance = "1e9"` → rejected, no anchor.
- [ ] `currentBalance = "  50000  "` → parses (whitespace tolerated, regression guard).
- [ ] No SMS balance and no manual balance → the anchor is `isProvisional == true`, opening
      confidence is **not** 0.9, and a `confirmBalance` coverage line exists.
- [ ] A **real** carried-forward anchor from a prior month still gets 0.9 confidence
      (regression guard — don't break the legitimate case).

Add to `test/forecast_reconciliation_engine_test.dart`:

- [ ] With **no** balance evidence, an obligation due earlier this month stays a dated
      overdue event and is **not** classified `possiblyAlreadyPaid`.
- [ ] With a **real** anchor dated after the due date, it *is* `possiblyAlreadyPaid`
      (regression guard).
- [ ] With a **stale** real anchor, the chosen behaviour is asserted explicitly — record
      which way you decided.

Add to `test/money_test.dart` — currently only three tests, none covering
`tryParseRupeesToPaise`'s null paths:

- [ ] `"1,2345"` (malformed grouping) → null.
- [ ] `"12,34,567"` (valid Indian) → 1234567_00 paise.
- [ ] `"1,234,567"` (valid Western) → 1234567_00 paise.
- [ ] An int64-overflow input → rejected, not wrapped.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `_manualAnchor` uses `MoneyParser`; no `double` touches a monetary value
- [ ] Fabricated anchors are always provisional with a `confirmBalance` coverage line
- [ ] The "no safe anchor" signal is wired into the `possiblyAlreadyPaid` check
- [ ] All ten tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Parse manual balances as integer paise and mark evidence-free anchors provisional`
