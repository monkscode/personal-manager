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

## Correction to Part 1 — the rupee sum cannot fail

Measured before writing the helper: `CoverageBucket` has **exactly** the four values the
formula lists, `_assertCompleteAssignments` already forces one assignment per input, and
each assignment copies `item.amountPaise` verbatim. So
`Σ datedEvent + Σ quantifiedExcluded + Σ anchorIncluded + Σ reviewPending == Σ inputs`
holds **by construction** and can never catch a dropped rupee. It is kept as a structural
guard — the four buckets are summed by name, so a fifth bucket added later breaks the test
and has to be classified — but it is not the part that bites.

**The teeth are entirely in the second half:** every assignment that is neither
`datedEvent` nor `anchorIncluded` must carry a coverage line naming it. That half went RED
on **four** existing fixtures the moment it was written (the two card-statement fixtures,
the LIC precedence fixture and the Vodafone user-confirmed fixture) — each was suppressing
a real amount with no line at all.

`anchorIncluded` is treated as *counted*, not excluded, and so is exempt: those rupees are
already inside the opening balance, and demanding a coverage line for them would be noise,
not traceability.

## Correction to Part 2 — banding, not bucketing

A fixed bucket width (`amount ~/ tolerance`) splits two amounts that are within jitter of
each other whenever they straddle a bucket edge. Instead the amounts actually present under
each `merchant:recurrence` key are clustered greedily against the **cluster floor** (not the
previous element, which would let a ladder of near amounts chain into one enormous band),
and the key carries that floor. Obligations and commitments are banded together, so a
detected commitment still folds into the Gmail bill it describes.

A **null** amount does not get its own band: an unknown amount is not a *different* amount,
and banding around it would stop a quantified sibling folding into it — subtracting the same
bill twice. A key with any amountless member stays unbanded, exactly as before.

## Tests to write first

- [x] **The conservation helper** (Part 1), applied to every existing fixture in
      `test/forecast_reconciliation_engine_test.dart`. — **RED ×4**, reason above. Lives in
      `test/support/reconciliation_invariants.dart`; both engine and matcher tests route
      every reconcile through a wrapper that asserts it, so no future fixture can opt out.
- [x] Two obligations, same merchant, same cadence, **different amounts** (₹5,000 and
      ₹45,000) → both survive into the ledger; neither is silently excluded. — **RED**
      (one `merch:hdfc:monthly` key for both)
- [x] If one genuinely must be excluded, a coverage line exists naming it and the amount.
- [x] A single ₹5,000 actual marks **only** the ₹5,000 obligation paid; the ₹45,000 EMI
      stays unpaid. — **RED** (nothing was marked paid)
- [x] Two obligations, same merchant, same cadence, **same amount** → treated as a genuine
      duplicate and deduplicated, with a coverage line.
- [x] Three-member group → the winner is unambiguous and **both** losers carry a coverage
      line. Rewritten: see the note below.
- [x] Added beyond the plan: an amountless sibling leaves the key unbanded, pinning the
      null-amount decision above.

### Why the three-member test was rewritten

The plan asked for "2nd and 3rd tie → routed to review". Reading the engine, a tie below
the winner cannot change any outcome: `_chooseWinner` takes `ordered.first`, and *every*
non-winner goes through the same `_assignReconciledDuplicate` path regardless of how they
rank among themselves. Sending a whole group to review because two already-suppressed
members tie would exclude a rupee the winner accounts for perfectly well. The test
therefore asserts what actually matters — the winner is unambiguous and neither loser
vanishes. The genuine arbitrariness in `_hasUnresolvableTie` (its `matchKey == null`
precondition, which makes it dead for every match-key group) is left to **TASK-20 M7**.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Rupee-conservation helper exists, is reusable, and is applied across the engine tests
- [x] Match key includes an amount band using the existing jitter helper
- [x] `_assignReconciledDuplicate` always emits a coverage line
      (new `CoverageReason.duplicateSuppressed`, plus its why-log label)
- [x] One actual marks at most one owner paid — the amount discriminates *before*
      ambiguity is declared, so a reference-only match can no longer clear an obligation
      whose rupees it could not have settled
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **695 passing** (was 690)
- [x] Suggested commit: `Add rupee conservation invariant and make obligation match keys amount-aware`
