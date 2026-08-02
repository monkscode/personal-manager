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

## Reachability — measured, not assumed

Both defects are **unreachable in the shipped app today.** `CardCycle` is never
constructed anywhere in `lib/` — there is no storage, no UI and no default for it — and
`_cardEstimates` (`sms_analysis_snapshot.dart:294-307`) calls the estimator with only
`statementMonth`. So in production:

- `needsCycleSetup` is always true, so `_cardItems` emits `cardPurchase`, never
  `cardStatement`;
- `dueDate` is always null, so the cycle lookup finds no candidate and every `cardpay:`
  item carries a null `cardCycleKey`;
- the `cardCycle:` group therefore never forms, and two payments already both reach the
  ledger as separate groups.

Same category as the Paytm wallet defect recorded in TASK-10 — real in the code, not
currently reachable through the app. The fix still lands: the defect goes live the moment
anything supplies a `CardCycle`, and the tests drive it through the matcher's public API.

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

- [x] Two card payments in one cycle (₹20,000 on the 10th, ₹30,000 on the 18th) → the
      ledger reflects **₹50,000** total, not ₹20,000. — **RED** (₹20,000; ₹30,000 gone)
- [x] Neither payment is silently excluded: every assignment that is not a `datedEvent`
      has a corresponding coverage line. — via TASK-14's helper, which every reconcile in
      the file routes through
- [x] Two cards due in the same month with distinct amounts → each payment attributes to
      the correct card. — **RED** (both went to `card:9876`, the last in the list)
- [x] Two cards due in the same month with **indistinguishable** amounts → the attribution
      is routed to review, not guessed. — **RED** (silently picked `card:9876`)
- [x] A single card payment in a cycle still behaves exactly as before (regression guard).
- [x] A partial payment (₹20,000 against a ₹50,000 statement) sets `outstandingPaise`
      to ₹30,000. — **already covered** at `test/card_cycle_estimator_test.dart:199-210`
      ("partial payment produces an outstanding quantified obligation"); not duplicated.

## Deliberately not done — the `amountPaidPaise` wiring

TASK-28 deferred "route the bill payment into `amountPaidPaise`" to this task. It is **not**
done here, because it would be dead code: `estimate()` only reads `amountPaidPaise` inside
`if (statementTotalPaise != null)`, and nothing in `lib/` ever supplies a statement total
(same missing-`CardCycle` gap as above). Wiring it now would add an untestable branch with
no observable effect. It belongs with whatever first gives a card a configured cycle and a
statement total; the estimator side of it is already correct and tested.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `_cardCycleKeyFor` is amount-aware and returns ambiguous rather than guessing — now
      `_cardCycleFor`, returning a `_CardCycleAttribution`. One card due in the month owns
      the payment whatever the amount (a partial payment is still that card's); with two or
      more, exactly one within jitter wins and anything else is ambiguous.
- [x] The `best` overwrite bug at line 389 is fixed — the whole scan is replaced
- [x] Two observed payments in one cycle both reach the ledger — `_chooseWinner` became
      `_chooseWinners`; observed actuals are never deduplicated against each other, only
      forecast estimates are
- [x] `_assignReconciledDuplicate` always emits a coverage line — landed in TASK-14
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **704 passing** (was 700)
- [x] Suggested commit: `Keep every observed card payment in the ledger`
