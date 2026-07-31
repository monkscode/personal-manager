# TASK-19 — Salary day-drift, payer consistency, cadence truncation

**Severity:** Important ×3 · **Phase:** 2 · **Depends on:** nothing

Salary is the **anchor** of the whole forecast. These three defects make the anchor date
meaningless, let non-salary income masquerade as salary, and drop real commitments.

---

## Defect 1 — salary day-drift measured linearly instead of circularly

`lib/services/salary_income_detector.dart:134-138`

```dart
windowDays = max |day − expectedDay|      // on raw day-of-month
```

Salary that normally posts on the **1st** but occasionally posts on the **31st of the
prior month** (the weekend/holiday drift the spec explicitly calls out) yields:

```
expectedDay: 1, expectedDayWindowDays: 30
```

The spec says the **pessimistic edge of this window drives minimum-balance planning**. A
30-day window makes the salary date meaningless, and the "you need ₹X by <date>" headline
degrades to noise.

### Fix

The correct primitive **already exists one file over**:
`lib/services/recurring_debit_detector.dart:302-311` — `_circularSpread` handles month-end
wrap correctly (day 30 and day 2 are 3 apart, not 28). Reuse it.

Currently **untested**: no test in `test/salary_income_detector_test.dart` uses a day other
than the default `day: 1`.

---

## Defect 2 — salary detection has no payer consistency check

`lib/services/salary_income_detector.dart:106, 218-237`

`_isSalaryCandidate` accepts **any** bank credit ≥ ₹1,000 that isn't p2p, self-transfer or
wallet. `_monthlyMax` then takes the largest such credit per calendar month.

### Failing scenario

A freelancer receiving payments from three different clients — or three FD-maturity
credits, or three friends settling up above the threshold — becomes `detectedStable`
salary with a median base. The forecast then anchors on income that has no reason to recur.

The spec describes salary as *a recurring credit from an identified salary sender or
payer*, not merely "the biggest credit each month".

### Fix

Group candidates by sender/merchant **before** clustering, exactly as
`RecurringDebitDetector._groups` already does for debits. Require the same payer across
months before promoting to `detectedStable`.

---

## Defect 3 — cadence gaps measured on raw timestamps with `inDays` truncation

`lib/services/recurring_debit_detector.dart:228`

```dart
difference(...).inDays      // truncates toward zero
```

A monthly pair at **30 Jan 22:00 → 27 Feb 09:00** measures as **27 days**, falls outside
the `(28, 33)` window, and **unlocks a real commitment**.

`ParsedTxn` already carries `txnLocalDate`. Compare date-only values.

### Fix

Use `txnLocalDate` and compute a whole-day difference from normalised dates. This is the
same class of bug as TASK-01 — time-of-day leaking into date arithmetic.

---

## Tests to write first

Add to `test/salary_income_detector_test.dart` (which currently only ever uses `day: 1`):

- [ ] Salary posting on the 1st, 1st, and 31st-of-prior-month → `expectedDayWindowDays` is
      small (≤ 2), not 30.
- [ ] Salary on the 28th, 29th, 30th → window is 2, and `expectedDay` is sensible.
- [ ] Three credits from **three different payers** → **not** promoted to `detectedStable`.
- [ ] Three credits from the **same** payer → promoted as before (regression guard).
- [ ] A single large credit still cannot become the base (regression guard — this is
      already covered at `:108-116`, keep it green).

Add to `test/recurring_debit_detector_test.dart`:

- [ ] A monthly pair at 30 Jan 22:00 → 27 Feb 09:00 is recognised as monthly.
- [ ] Cadence detection gives the same answer regardless of the time-of-day component.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Salary day-drift uses circular distance, reusing `_circularSpread`
- [ ] Salary requires payer consistency before `detectedStable`
- [ ] Cadence gaps computed on normalised dates, not raw timestamps
- [ ] All seven tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Measure salary drift circularly and require a consistent payer`
