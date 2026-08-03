# TASK-23 — Label-only future dedupe; unreachable buffer headline

**Severity:** Important ×2 · **Phase:** 3 · **Depends on:** nothing

---

> **Premise check (2026-08-03).** Both defects are real and both were verified against the
> source before any code changed. Every line number in this file had drifted. One test the
> file asked for turned out to need a refinement to be meaningful, and the fix introduced a
> regression of its own that a follow-up test caught — both recorded below.

## Defect 1 — future-month dedupe matches on merchant label only

`lib/services/forecast_adapter.dart:717-756` (was quoted as 625-673)

`_isCommitmentSuppressed` matches on `_normLabel(label)` **equality** (trim + lowercase)
plus amount-within-jitter. When a Gmail/manual obligation and an SMS-detected commitment
spell the merchant differently, **both project into every future month**.

### Failing scenario

- Gmail obligation: `merchant: "ACT Fibernet"`, monthly, ₹1,180
- SMS commitment: `merchantNorm: "actfibernet"`, ₹1,180

`"act fibernet" != "actfibernet"` → no suppression → months 1-11 **each** subtract ₹2,360.

The horizon overstates outflow by roughly **₹13,000** and doubles required-in-bank for
every future month.

### Why the target month is safe

Month 0 runs the full `ReconciliationMatcher`, which has a proper identity hierarchy. Only
offsets 1-11 use this weak path.

### The spec rule

> The join cannot rely only on merchant, because SMS merchant extraction is often weak.
> Match on reference ID, then cadence, then an amount window. Route ambiguity to review.

### Fix — as implemented

Every commitment reaching `_commitmentSuppression` has already cleared cadence (it is only
projected into months its cadence hits) and the amount window. What was left was deciding
whether two differently-spelled payees are one payee. `RecurringCommitment` has no
reference id to join on, so the hierarchy that remains is:

1. **Label, spelling discounted.** `_normLabel` now strips *everything* except
   `[a-z0-9]`, not just trim-and-lowercase. `"ACT Fibernet"` and `"actfibernet"` both
   become `actfibernet` → suppressed, silently, as an unambiguous duplicate.
2. **Category + amount + month, when labels still differ.** Ambiguous by definition: the
   commitment is carried once **and** a `duplicateSuppressed` / `review` coverage line is
   emitted into that horizon month naming both spellings and the amount. Projecting both
   would double-count the rupee; dropping it silently would make it vanish. Naming it
   satisfies both spec invariants.
3. **Otherwise both project.**

A new `_HorizonObligation` index carries the category alongside each projected obligation
(`ForecastEvent` has no category field). The two `*EconomicKeys` sets are gone — the index
walk subsumes them, and their exact-amount equality was a strict subset of the jitter test.

`_horizonEvents` now returns `(events, ambiguity)` and the ambiguity map is merged into
`horizonCoverageLines`, the per-month channel TASK-21 added.

**Named limitation.** `ReconciliationItem` has no `categoryKey`, so a *future
reconciliation item* (as opposed to a canonical obligation projection) can only ever be
joined by label — step 2 is unavailable for it. Adding a category to `ReconciliationItem`
was out of scope here.

Note TASK-08 fixes the greedy merchant regex that produces garbage labels like
`"amazon on 26-06-25. available limit rs"` — that fix reduces, but does not eliminate,
this problem. Do not treat TASK-08 as a substitute.

---

## Defect 2 — `_isSeasonalBufferShortfall` is unreachable through the normal path

`lib/services/forecast_adapter.dart:26, 664-667, 798-811` (was quoted as 28, 572-575,
706-719)

Two confidence gates contradict each other:

- `_isHard` requires `confidence >= kReserveHardConfidence` (**0.8**), so any event in
  `month0.events` has confidence ≥ 0.8.
- `_isSeasonalBufferShortfall` returns true only when **every** driving event has
  `confidence < kSeasonalBufferConfidenceThreshold` (**0.5**).

The only way in is a user-confirmed risk decision — `_applyOverride`
(`forecast_adapter.dart:578-597`) preserves the original low confidence.

So the headline *"Estimated buffer shortfall … mostly discretionary, not a fixed bill"*
(`forecast_adapter.dart:768-771`) can **only ever fire for a risk the user explicitly
confirmed** — arguably backwards. And `kSeasonalBufferConfidenceThreshold` does nothing
for the default path.

**No test covers the reachable case.**

### Fix — decision recorded

**The threshold is deleted; the source check alone decides.** The headline now fires
whenever every outflow on the in-month low day is a `seasonal` event.

Neither option in the original file was taken, and the reason matters. Adding a third
partition bucket so sub-0.5 events could reach `month0.events` would let weak candidates
create a shortfall — the exact thing `_isHard` exists to prevent, and which the adapter's
own comment calls out ("weak candidates cannot create false safety **or false
shortfall**"). And "rename it to say it is only for confirmed risks" would keep a headline
that fires almost never.

The confidence clause was never load-bearing. What the headline claims is *"mostly
discretionary, not a fixed bill"* — a statement about the **kind** of driver, not about
how sure we are of it. `e.source == ForecastEventSource.seasonal` already carries that
claim in full. Being an estimate *is* the softness being reported. The threshold added
nothing except unreachability, so `kSeasonalBufferConfidenceThreshold` is gone; there is
no boundary left to test at 0.49/0.51.

---

## Tests written first — RED symptoms recorded

All in `test/forecast_adapter_test.dart` (`_task23`):

- [x] `"ACT Fibernet"` obligation + `"actfibernet"` commitment → **one** ₹1,180 outflow in
      September. **RED:** `Expected: length <1> Actual: has length of <2>`.
- [x] Genuinely different merchants at the same amount and cadence → **both** project.
      **GUARD** — passed both ways.

      *Refinement.* The task file's phrasing does not survive the fix as written: two
      merchants at the same amount, cadence **and category** are exactly the ambiguous
      case, not the "genuinely different" case — Netflix and Spotify both at ₹500/month
      under `subscriptions` are indistinguishable from one bill spelled two ways. The
      guard therefore uses **different categories** (`health` vs `bills`), which is what
      "genuinely different" has to mean once category is part of the join.
- [x] Ambiguous same-category match → carried once **and** named with a
      `duplicateSuppressed` / `review` coverage line carrying the amount.
      **RED:** `Expected: length <1> Actual: has length of <2>`.
- [x] The seasonal buffer headline fires on the default path: a `discretionarySpend` item
      at confidence 0.85 (which clears `_isHard`) driving the in-month low.
      **RED:** `isSeasonalBufferShortfall Expected: true Actual: <false>`.
- [x] A fixed bill driving the same low does **not** set the flag. **GUARD**.
- [x] *(added after the fix — a regression the fix itself introduced)* Two payees whose
      labels normalise to the empty string must not collapse. Stripping punctuation is
      what lets `"ACT Fibernet"` meet `"actfibernet"`, but `"---"` and `"***"` both
      normalise to `""` and were silently treated as one owner — the same ownerless-key
      grouping failure TASK-31 and TASK-33 found in the parser. **RED:** `Expected: length
      <2> Actual: has length of <1>`. Fixed by requiring a non-empty key for the
      confident-duplicate branch.

## Verification

```bash
flutter analyze
flutter test
```

`flutter analyze` — No issues found. `flutter test` — **840 passing, 0 failing**
(834 after TASK-22; +6).

## Definition of done

- [x] Horizon dedupe uses cadence + amount window + category, with merchant text last and
      spelling-insensitive — not label equality alone. (No reference id exists on
      `RecurringCommitment` to join on; noted above.)
- [x] Ambiguity routes to review, via a per-month `duplicateSuppressed` coverage line
- [x] `_isSeasonalBufferShortfall` intent decided, implemented and recorded here
- [x] `kSeasonalBufferConfidenceThreshold` deleted
- [x] All tests written failing-first, then passing; guards labelled as guards
- [x] `flutter analyze` clean, `flutter test` green
- [x] Commit: `Dedupe horizon commitments by identity rather than label`
