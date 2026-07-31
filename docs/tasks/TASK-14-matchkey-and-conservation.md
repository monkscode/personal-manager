# TASK-14 — Amount-blind match key deletes obligations, plus the rupee-conservation test

**Severity:** Critical · **Phase:** 2 · **Depends on:** nothing

**Do the conservation test in this task first.** It fails on three of the four
reconciliation Criticals immediately, and it is the single highest-value test in the plan.

---

## Part 1 — the rupee-conservation test

`lib/services/forecast_reconciliation_engine.dart:460-477` already asserts a completeness
invariant on **every call**, which is genuinely good. But it checks **IDs, not rupees**:

> every input produced exactly one assignment

TASK-13's dropped card payment, this task's dropped duplicate obligation, and TASK-01's
day-31 salary **all satisfy that check** while money vanishes.

### The test to write

```
Σ datedEvent + Σ quantifiedExcluded + Σ anchorIncluded + Σ reviewPending
  == Σ input amounts
```

**and** every non-`datedEvent` assignment has a corresponding coverage line.

Put it in `test/forecast_reconciliation_engine_test.dart` as a reusable helper so every
other reconciliation test can call it. The existing helper at lines 13-21 is the natural
place to extend.

Then apply it to the fixtures already in that file. Expect failures — that is the point.

---

## Part 2 — the amount-blind match key

`lib/services/reconciliation_matcher.dart:181-192, 204-208`

The match key is:

```
merch:<merchantNorm>:<recurrence>
```

**No amount.** Any two obligations at the same merchant with the same cadence share a
group. The engine picks one (sorted by id) and the other becomes
`quantifiedExcluded` / `reconciled` with **no coverage line at all**.

`_hasUnresolvableTie` (`forecast_reconciliation_engine.dart:496-501`) cannot save it — it
explicitly treats a non-null `matchKey` as a sufficient tie-breaker.

### Failing scenario

- Gmail obligation "HDFC" ₹5,000 monthly (a card bill)
- Manual obligation "HDFC" ₹45,000 monthly (a home-loan EMI)

`_obligationOwner` (lines 172-178) maps **both** `gmail` and `manual` to
`ForecastOwner.gmailBill`, so both are precedence 10 with
`matchKey: 'merch:hdfc:monthly'`. One group, one winner by string sort of
`obl:<dedupeKey>` → **the ₹45,000 EMI can lose and disappear entirely.**

The forecast then shows a ₹45,000 surplus that does not exist.

### The same path has a second failure

`reconciliation_matcher.dart:262-268` — when `distinctKeys.length == 1`, one actual debit
marks **both** owners paid. So a single ₹5,000 card payment marks the ₹45,000 EMI paid too.

### The fix

1. **Include an amount band in the match key.** The jitter helper already exists in this
   file — reuse it so the band tolerance stays consistent with the rest of the matcher.
2. **`_assignReconciledDuplicate` must unconditionally emit a coverage line** naming what
   it suppressed and why. (Shared with TASK-13 — do it once, coordinate.)
3. **A single actual may mark at most one owner paid.** Fix the `distinctKeys.length == 1`
   shortcut so it requires the amounts to be compatible, not merely the key.

This directly restores the spec's second invariant:

> **No silent exclusion.** The forecast may not silently drop a material known amount and
> still show a confident surplus.

---

## Tests to write first

- [ ] **The conservation helper** (Part 1), applied to every existing fixture in
      `test/forecast_reconciliation_engine_test.dart`.
- [ ] Two obligations, same merchant, same cadence, **different amounts** (₹5,000 and
      ₹45,000) → both survive into the ledger; neither is silently excluded.
- [ ] If one genuinely must be excluded, a coverage line exists naming it and the amount.
- [ ] A single ₹5,000 actual marks **only** the ₹5,000 obligation paid; the ₹45,000 EMI
      stays unpaid.
- [ ] Two obligations, same merchant, same cadence, **same amount** → treated as a genuine
      duplicate and deduplicated, with a coverage line.
- [ ] Three-member group where the 2nd and 3rd tie → routed to review rather than resolved
      arbitrarily (see also TASK-20, which covers `_hasUnresolvableTie` only inspecting
      `ordered[0]` and `ordered[1]`).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Rupee-conservation helper exists, is reusable, and is applied across the engine tests
- [ ] Match key includes an amount band using the existing jitter helper
- [ ] `_assignReconciledDuplicate` always emits a coverage line
- [ ] One actual marks at most one owner paid
- [ ] All six tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Add rupee conservation invariant and make obligation match keys amount-aware`
