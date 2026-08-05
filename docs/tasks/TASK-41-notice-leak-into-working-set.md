# TASK-41 — A future-debit notice still reaches every read path that was added later

**Phase 6. Severity: Critical.**

Opened 2026-08-05 from a user report: *"two entries for ₹118 on 3 Aug, I only spent it once
— it wasn't showing two days ago."* Both halves of that sentence are correct, and the second
half is what identifies the mechanism.

---

## What the user saw

| id | body | merchant | created |
|---|---|---|---|
| 390 | `E-Mandate!` / `[amount] will be deducted on 03/08/26` | `77d1cc47…` (a UMN) | **2026-08-02 12:41** |
| 2717 | `UPI Mandate: Sent [amount] … To AutoPay  Bharat Connec` | `bharat connec` | **2026-08-03 14:35** |

The bank announces the debit on 2 Aug and reports the real one on 3 Aug. Row 390 was stored
by a scan on **2 Aug 12:41**; TASK-32 taught the parser to stop booking notices as debits in
commit `04f40b4` on **3 Aug 13:55** — a day later. So row 390 is residue the parser can no
longer produce, and row 2717 is the genuine debit, stored correctly after the fix. On 2 Aug
the user saw one ₹118; from 3 Aug 14:35 they saw two. **The report's timeline is exact.**

## Root cause

TASK-32 shipped a read-time correction, `ParsedTxn.isFutureDebitNotice`, precisely so stored
rows "stop double-counting without anything being deleted". It was applied at **four leaf
consumers**:

- `real_insights.dart:1222` (`_isConsumptionSpend`)
- `sms_analysis_snapshot.dart:344` (`_yearOverYear`)
- `recurring_debit_detector.dart:145`
- `seasonal_estimator.dart:80`

But the working set every producer reads from is `active`, built in
`SmsAnalysisSnapshot.reduce`, and it filtered on **one** predicate:

```dart
final active = [
  for (final txn in history)
    if (txn.reviewStatus != ReviewStatus.dismissed) txn,
];
```

Everything derived from `active` that was not individually patched still counts the
announcement as a completed debit — in particular:

- `currentMonthTxns` → `ReconciliationMatcher.buildItems(actuals:)` → reconciliation items →
  forecast events → **the Drivers list on Home**;
- `allTxns` → **the transaction list the user scrolls**.

The measured signature of the split, from the device on 2026-08-05: August's Drivers list
sums to **₹50,734** across 10 rows while the "Spent this month" headline reads **₹50,616** —
exactly ₹118 apart, because `_isConsumptionSpend` applies the check and the reconciliation
path does not. The app disagreed with itself about the same month.

**This is the same defect shape TASK-32's own doc comment describes** — it notes the notice
vocabulary "previously existed twice … which is why the estimator and the recurring detector
never saw the exclusion at all" — and the remedy reproduced it one layer up: a single
predicate, sprinkled at call sites instead of applied where the set is defined. Fix at the
source, not at the symptom.

## The fix

Exclude notices when building `active`, so every consumer inherits it — including read paths
added later, which is the property four leaf checks cannot have.

```dart
final active = [
  for (final txn in history)
    if (txn.reviewStatus != ReviewStatus.dismissed && !txn.isFutureDebitNotice) txn,
];
```

The four leaf checks are left in place. They are now redundant for anything fed from
`active`, but `_isConsumptionSpend` is a general predicate applied to arbitrary rows, and
defence in depth here costs nothing.

Nothing is written or deleted: this is a read-time filter over stored rows, exactly the
mechanism TASK-32 chose. Retire, never delete.

## Blast radius — measured, not assumed

**32 rows, ₹86,734.29, leave the working set** (28 user-`confirmed`, 3 `auto_added`, 1
`needs_review`; 30 debits, 2 credits; 2025-12-02 → 2026-08-03). The `E-Mandate!` prefix
accounts for only 8 of them — the rest are Axis's
`For the upcoming mandate set for … will be debited` and card-bill reminders, which is why
this had to be fixed by the *pattern* and not by the format that prompted the report.

**30 of the 32 have a real-debit partner within ±7 days at the same amount** — genuinely
double-counted. The two that do not are both correct to drop, and are named here rather than
left as a remainder:

| id | date | amount | why it has no partner |
|---|---|---|---|
| 70 | 2026-04-06 | ₹428 **credit** | *"…has a credit balance of [amount]. The amount will be credited to your Savings Account if not used within 7 days."* A **conditional** future credit stored as income. This is verbatim the example `_parseNotice`'s own comment names as not-an-obligation. It never happened. |
| 613 | 2026-02-23 | ₹1,686 debit | A PhonePe autopay pre-notice whose real debit alert is nowhere in the inbox. TASK-33 made the scan read all ~11,600 messages, so the absence is evidence rather than a gap. An announcement is dropped here, **not a confirmed spend** — say so plainly. |

## Why the row had to leave the *list*, not just the totals

An alternative was to keep notices in `allTxns` (so the Activity list still shows them) and
drop them only from `currentMonthTxns`. The user's own report settles it: they were looking
at a list, counting two ₹118 entries. Leaving the phantom in the list would leave the
complaint unfixed. **28 user-confirmed rows will disappear from the transaction list** — that
is a visible change and is intended, not a side effect.

## Tests — written first, with the RED each produced

`test/sms_analysis_snapshot_test.dart`, group `TASK-41`. Fixture is two rows on the same day
for the same amount: the announcement and the real debit. Payee is synthetic; the body
structure is the device's.

1. `the announcement is kept out of the target month actuals` —
   **RED: `Expected: length 1, Actual: length 2`** on `currentMonthTxns`.
2. `and out of the transaction list the user scrolls` — **RED: same, on `allTxns`.**
3. `the surviving rupee is the real debit, counted once` (guard) —
   **RED: `Expected: <11800>, Actual: <23600>`.** This is the user's bug stated as an
   assertion: ₹236 recorded where ₹118 was spent. It guards the fix from over-reaching —
   the phantom must go and the real rupee must stay.

## What this does not cover

The same-day, same-amount clusters that are **not** notices are left alone, deliberately:
five ₹10,000 debits to `indian clearing corp` on 5 Jun, four ₹20,000 to `science city-ii` on
17 Jul, three ₹1,999 `google` on 28 Jul. TASK-24 M5 established that two genuinely distinct
events can share an owner, a date and an amount, and there is no evidence any of these is a
duplicate: **no two rows in the database share an `sms_id`.** (Shared `body_hash` is
expected — identical recurring alerts hash alike, which is what collision sets exist for,
TASK-09.) The `hdfc ltd` / `hdfc bank ltd` ₹61,415 pair on 5 Apr remains open under merchant
identity resolution, unchanged by this task.

## Device verification — 2026-08-05

Built, installed, relaunched. **The `77d1cc47…` ₹118 driver row is gone and
`bharat connec ₹118` remains** — one spend, one row.

The decisive check is the consistency the bug's signature was defined by: Home now reads
**"11 payments tracked"** beside **11 driver rows**. Before the fix it was 9 tracked against
10 drivers. The app no longer disagrees with itself about the month.

Driver rows sum to ₹1,14,878 against a ₹1,14,879 headline. The ₹1 is per-row paise
truncation — `lg electronics app` is ₹2,847.97 and each row renders `amountPaise ~/ 100` —
not a leak.

**Row 390 is still on disk**, `needs_review`, untouched. Nothing was deleted; the filter is
read-time only.

### Reconciliation, and a correction to the standing device notes

The database was **not** byte-identical: 2,061 → **2,063** rows, `MAX(id)` 2785 → 2787. Both
new rows were written at **12:10:48** under one scan batch, and both are genuine new SMS —
`hdfc bank ltd` ₹61,415 dated 5 Aug and `lg electronics app` ₹2,847.97 dated 4 Aug. They are
why August's "Required in bank" moved ₹0 → ₹61,415 and why two new drivers appeared; **that
change is real data, not an effect of this fix.** Everything else reconciles exactly:
auto_added 1759 → 1761 (+2), confirmed 187, dismissed 6, needs_review 109, 3 risk decisions,
10 obligations of which 3 retired — all unchanged.

**OVERVIEW's device note that "a scan is ONLY triggered by pull-to-refresh — there is no
auto-scan" is wrong.** No pull-to-refresh was performed; the gestures used were upward
scrolls. The difference from the previous session was `adb shell am force-stop` before
`am start`, i.e. a **cold start, which does run a scan**. Plan for a cold start to write, and
capture counts before and after rather than assuming an install-and-look is inert.

## Definition of done

- [x] Tests written first, each RED recorded above.
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — **932 passing, 0 failing** (929 before; +3).
- [x] Device: August shows one ₹118, and the payment count agrees with the driver count.
- [x] One commit, imperative subject, no AI-attribution trailer.
