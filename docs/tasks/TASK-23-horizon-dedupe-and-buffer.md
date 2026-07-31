# TASK-23 — Label-only future dedupe; unreachable buffer headline

**Severity:** Important ×2 · **Phase:** 3 · **Depends on:** nothing

---

## Defect 1 — future-month dedupe matches on merchant label only

`lib/services/forecast_adapter.dart:625-673`

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

### Fix

Reuse the matcher's identity hierarchy for horizon projection. If that is too large a
change for this task, suppress on **amount + cadence + category** when labels differ, and
surface the ambiguity as review rather than silently projecting both.

Note TASK-08 fixes the greedy merchant regex that produces garbage labels like
`"amazon on 26-06-25. available limit rs"` — that fix reduces, but does not eliminate,
this problem. Do not treat TASK-08 as a substitute.

---

## Defect 2 — `_isSeasonalBufferShortfall` is unreachable through the normal path

`lib/services/forecast_adapter.dart:28, 572-575, 706-719`

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

### Fix

Decide which behaviour is intended, then make the code say it:

- **If the headline should fire for genuinely low-confidence shortfalls**, the events must
  reach `month0.events` without passing `_isHard` — meaning the partition needs a third
  bucket, not just hard/soft.
- **If it is only meant for confirmed risks**, rename it to say so and delete
  `kSeasonalBufferConfidenceThreshold`.

Either way, add the test for whichever path becomes reachable.

---

## Tests to write first

Add to `test/forecast_adapter_test.dart`:

- [ ] `"ACT Fibernet"` obligation + `"actfibernet"` commitment, same amount and cadence →
      **one** ₹1,180 outflow per future month, not two.
- [ ] Genuinely different merchants at the same amount and cadence → **both** project
      (guard against over-suppression).
- [ ] Ambiguous label match → surfaced as review rather than silently suppressed or
      silently doubled.
- [ ] The chosen `_isSeasonalBufferShortfall` behaviour has a test that actually reaches
      it.
- [ ] If the constant is kept, a boundary test at confidence 0.49 and 0.51.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Horizon dedupe uses reference/cadence/amount, not label equality alone
- [ ] Ambiguity routes to review
- [ ] `_isSeasonalBufferShortfall` intent decided, implemented and recorded here
- [ ] `kSeasonalBufferConfidenceThreshold` either used or deleted
- [ ] All five tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Dedupe horizon commitments by identity rather than label`
