# TASK-01 — Month-end date overflow drops salary and bills

**Severity:** Critical (×4 sites) · **Phase:** 0 · **Depends on:** nothing

Found independently by two reviewers. Do this task first — it is four small edits with
a fix pattern that already exists in the codebase, and it corrupts the headline number
for any user paid on the 29th, 30th or 31st.

---

## The defect

Dart's `DateTime` constructor **silently rolls over** an out-of-range day:

```dart
DateTime(2026, 2, 30)   // => 2026-03-02, no error
DateTime(2026, 4, 31)   // => 2026-05-01, no error
```

Four sites build a date from a day-of-month with no clamp.

### Site 1 — salary (worst)

`lib/services/reconciliation_matcher.dart:407-415`

```dart
final day = salary.expectedDay ?? 1;
return ReconciliationItem(
  id: 'salary',
  ...
  dueDate: DateTime(targetMonth.year, targetMonth.month, day),
```

### Site 2 — obligation due day

`lib/services/reconciliation_matcher.dart:102-110`

```dart
final dueDate =
    obligation.dueDate ??
    (obligation.dueDay != null
        ? DateTime(targetMonth.year, targetMonth.month, obligation.dueDay!)
        : null);
```

### Site 3 — card statement due date

`lib/services/card_cycle_estimator.dart:53-58`

```dart
if (cycle != null && statementMonth != null) {
  dueDate = DateTime(statementMonth.year, statementMonth.month, cycle.dueDay);
}
```

### Site 4 — recurring cadence advance

`lib/services/recurring_debit_detector.dart:268-276` — `_addCadence` advances a monthly
cadence by constructing the next month with the same day-of-month.

---

## Why it matters

Once the date lands outside the target month, `ForecastReconciliationEngine._applyWinner`
(`lib/services/forecast_reconciliation_engine.dart:224-236`) sees
`!_sameMonth(eventDate, targetMonth)` and files the item as `futureEarmark` — which is
**excluded from the dated ledger**.

**Scenario A — salary disappears.** User is paid on the 30th. Building February's
forecast: `DateTime(2026, 2, 30)` → 2 March → not February → the user's *entire
salary* is dropped from the ledger and reappears as a "future earmark". The app shows a
guaranteed false shortfall every February, for every user paid on the 29th/30th/31st.

**Scenario B — rent disappears.** Rent due on the 31st, `dueDay = 31`. In April, June,
September and November the obligation silently leaves the ledger. Five months a year of
understated required cash.

**Scenario C — card bill lands in the wrong month.** `dueDay: 31`, statement month
February → 3 March. February's ledger loses a real card bill.

**Scenario D — cadence skips a month.** `_addCadence(DateTime(2026,1,31), monthly)` →
`DateTime(2026,2,31)` → 3 March, skipping February entirely. `nextExpected` for a
month-end monthly bill is wrong by ~4 days and lands in the wrong month.

This breaks the **no silent exclusion** invariant: a material known amount is dropped
and a confident surplus is still shown.

---

## The fix

**The pattern already exists in this codebase — reuse it.** `ReservePlanner._getSalaryDateForMonth`
(`lib/services/reserve_planner.dart:228-233`) clamps correctly:

```dart
final lastDay = DateTime(year, month + 1, 0).day;   // day 0 of next month = last day of this month
final safeDay = day > lastDay ? lastDay : day;
return DateTime(year, month, safeDay);
```

`lib/services/forecast_adapter.dart:32` also defines `kProjectedEventDayCap = 28` and
clamps with it at lines 300, 381 and 461 for months 2-12 of the horizon. The month-0
path simply never got the same treatment.

**Add one shared helper** rather than repeating the clamp four times. Put it somewhere
both `lib/services/` and `lib/data/` can reach — `lib/core/` is the natural home:

```dart
/// Builds a date in [year]/[month], clamping [day] to the last day of that month.
///
/// `DateTime(2026, 2, 30)` silently rolls over to 2026-03-02, which pushes the event
/// out of its target month and causes it to be excluded from the dated ledger.
DateTime clampedDate(int year, int month, int day) {
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day < 1 ? 1 : (day > lastDay ? lastDay : day));
}
```

Then replace all four sites with `clampedDate(...)`.

For site 4 (`_addCadence`), clamping is necessary but check the surrounding logic: the
intent is "advance one month", so `DateTime(2026,1,31)` + monthly should give
28 February 2026, not 3 March.

**Do not** change `reserve_planner.dart:228-233` — it is already correct. Optionally
refactor it to call the new helper, but that is cosmetic.

---

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

- [x] Salary with `expectedDay: 30`, target month February 2026 → the salary item's
      `dueDate` is 28 Feb 2026, and the item appears in the February ledger as an
      inflow (not as a `futureEarmark`).
- [x] Salary with `expectedDay: 31`, target month April 2026 → 30 Apr 2026.
- [x] Obligation with `dueDay: 31`, target month February 2026 → 28 Feb 2026, and the
      obligation is a dated event in February.
- [x] Leap year: `expectedDay: 30`, February **2028** → 29 Feb 2028 (not 28).

Add to `test/card_cycle_estimator_test.dart` (currently only tests `dueDay: 20` in August):

- [x] `dueDay: 31`, statement month February 2026 → due date 28 Feb 2026.
- [x] `dueDay: 30`, statement month February 2026 → 28 Feb 2026.

Add to `test/recurring_debit_detector_test.dart`:

- [x] `_addCadence` from 31 Jan 2026, monthly → 28 Feb 2026 (not 3 March).
- [x] From 31 Jan 2028, monthly → 29 Feb 2028.

Add a shared test file `test/clamped_date_test.dart`:

- [x] Every month of a non-leap year with `day: 31` returns that month's real last day.
- [x] Leap and non-leap February with `day: 29`.
- [x] `day: 0` and negative days clamp to 1 rather than rolling backwards.

---

## Verification

```bash
flutter analyze     # "No issues found!"
flutter test        # all green
```

## Definition of done

- [x] `clampedDate` helper added with a doc comment explaining the rollover hazard
- [x] All four sites use it
- [x] All tests above written, failing first, then passing
- [x] `flutter analyze` clean, `flutter test` fully green
- [x] Committed with an imperative subject, e.g. `Clamp month-end dates so salary and bills stay in their month`
