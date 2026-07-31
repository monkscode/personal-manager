# TASK-13 — Second card payment in a cycle vanishes

**Severity:** Critical · **Phase:** 2 · **Depends on:** nothing

Observed bank outflow disappears from the forecast with **no coverage line** — a direct
breach of the "no silent exclusion" invariant this layer advertises as enforced.

---

## The defect

`lib/services/reconciliation_matcher.dart:358-376, 382-395` plus
`lib/services/forecast_reconciliation_engine.dart:503-516, 352-386`

`_cardCycleKeyFor` assigns a cycle key by **statement month only**, so every card payment
in a month gets the same key.

`_groupKey` (`forecast_reconciliation_engine.dart:488-492`) then puts them all in one
group. `_chooseWinner` returns the **first** `cardPayment` with an `actualDate`, and every
other member goes through `_assignReconciledDuplicate` — which emits an assignment but
**no coverage line and no event** (lines 358-386; the coverage branches only fire for
secondary-scope or bridge-target items).

### Failing scenario

HDFC bill due 20 Aug. User pays **₹20,000 on 10 Aug** and **₹30,000 on 18 Aug**.

Both become `cardpay:` items with `cardCycleKey: 'hdfc-4321:2026-08'`. The ledger records
₹20,000. **₹30,000 of observed bank outflow vanishes** with no coverage line — the app
shows ₹30,000 more free cash than actually exists.

---

## Second, independent bug in the same function

`reconciliation_matcher.dart:389`

```dart
if (best == null || estimate.statementEventAmountPaise > 0) best = estimate;
```

This always overwrites with the **last** non-zero card, ignoring the payment amount
entirely. With two cards due in the same month, **both payments are attributed to
whichever card happens to be last in the list**, and one is dropped.

---

## The fix — three parts

1. **Make `_cardCycleKeyFor` amount-aware**, and refuse to guess when two cards are
   plausible. Per spec, an ambiguous attribution goes to **review**, not to a silent
   pick. Replace the `best` overwrite with a scored match on amount proximity, and return
   "ambiguous" when two candidates score comparably.

2. **`_chooseWinner` must never discard a second observed actual.** Two payments in a
   cycle are two real cash events. Forecast obligations can be deduplicated; *observed
   actuals* cannot. Treat them as additive against the same obligation, and let the
   obligation's `amountPaidPaise` / `outstandingPaise` carry the partial-payment story.

3. **`_assignReconciledDuplicate` must always emit a coverage line** naming what it
   suppressed and why. See TASK-14, which shares this fix — coordinate so it is done once.

---

## Interaction with other tasks

TASK-14 covers the same `_assignReconciledDuplicate` silent-drop path from the match-key
angle, and builds the rupee-conservation test that catches this class. **Do TASK-14's
conservation helper first if you can** — it will fail on this bug immediately and give you
a precise target.

---

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

- [ ] Two card payments in one cycle (₹20,000 on the 10th, ₹30,000 on the 18th) → the
      ledger reflects **₹50,000** total, not ₹20,000.
- [ ] Neither payment is silently excluded: every assignment that is not a `datedEvent`
      has a corresponding coverage line.
- [ ] Two cards due in the same month with distinct amounts → each payment attributes to
      the correct card.
- [ ] Two cards due in the same month with **indistinguishable** amounts → the attribution
      is routed to review, not guessed.
- [ ] A single card payment in a cycle still behaves exactly as before (regression guard).
- [ ] A partial payment (₹20,000 against a ₹50,000 statement) sets `outstandingPaise`
      to ₹30,000.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `_cardCycleKeyFor` is amount-aware and returns ambiguous rather than guessing
- [ ] The `best` overwrite bug at line 389 is fixed
- [ ] Two observed payments in one cycle both reach the ledger
- [ ] `_assignReconciledDuplicate` always emits a coverage line
- [ ] All six tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Keep every observed card payment in the ledger`
