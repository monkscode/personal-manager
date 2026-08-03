# TASK-32 — Future-tense notices are stored as completed debits

**Severity:** Critical (spec invariant breach) · **Phase:** 1 (parser/ingestion policy)

Not from the audit. Found on 2026-08-02 measuring the real device database after
installing the Phase-2 build. **Re-measured and corrected on 2026-08-03** before the
fix landed — see "Corrections to this file" below. The original title named only
upcoming-mandate notices; the defect is the whole future tense.

---

## The defect

Banks send a pre-notification before a debit is collected:

```
For the upcoming mandate set for 29-07-26, [amount] will be debited from your A/c towards PhonePe…
For the upcoming mandate set for 28-07-26, your account will be debited with [amount] towards Google…
[amount] is due for payment on 05-12-25 towards Axis Bank CC no. [account]. [amount] will be debited…
E-Mandate! [amount] will be deducted on 03/08/26 For AutoPay Bharat Connect PostPaid Bill Payment mandate
```

This is an **announcement of a future debit**, not a debit. Then the real debit arrives
days later and is stored too. The same rupee is now counted twice.

### Measured on live data (386 rows, 2026-08-03)

**30 rows** are future-tense notices stored as `direction=debit`, totalling **₹86,304**
— 26 already `confirmed` by the user, 3 `auto_added`, 1 `needs_review`:

| shape | rows | value |
|---|---|---|
| `For the upcoming mandate set for …` (Axis NACH) | 17 | ₹17,154 |
| `… is due for payment on … towards Axis Bank CC no. …` | 5 | ₹66,149 |
| `E-Mandate! … will be deducted on … For <payee> mandate` (HDFC) | 7 | ₹1,002 |
| `E-Mandate! … For Google Asia Pacific Pte.Ltd mandate` | 1 | ₹1,999 |

Two further rows (₹430) are *credit* notices — "your card credit balance will be
credited to your Savings Account" — and are excluded from the fix: an announced inflow
is not an obligation.

The ₹1,999 Google mandate shows the double count at its worst. Every row below is the
same single monthly debit:

| date | rows stored | booked | actually moved |
|---|---|---|---|
| 2026-07-28 | 2 notices + 1 real | ₹5,997 | ₹1,999 |
| 2026-06-28 | 1 notice + 1 real | ₹3,998 | ₹1,999 |
| 2026-05-28 | 2 notices + 1 real | ₹5,997 | ₹1,999 |

This breaches the invariant the whole layer is built on:

> **One owner per rupee.** Every input amount must be attributed to exactly one owner.
> No amount may be counted twice, and none may vanish.

---

## Corrections to this file (2026-08-03)

Three claims in the original were wrong or incomplete. They are corrected above and
recorded here rather than quietly edited away.

**1. "The parser stores it as one" — incomplete, and it hid the real mechanism.**
The parser was never naive about pre-notices. `sms_transaction_parser` already computed
`isFutureNotice` from `_futureNoticeMarker`, re-dated the row to the *announced* day, and
forced it to `parserUncertain` review. The design intent was that the real debit would
then fold into the notice through one of two dedup paths. **Both are dead for these
formats:**

- `_strongReferenceDuplicate` needs a shared `ref_number`. All 17 Axis mandate notices
  store `ref_number = NULL`; the bank sends no reference.
- `_weakCollision` needs `a.accountLast4 != null && a.accountLast4 == b.accountLast4`.
  All 17 store `account_last4 = NULL` — Axis writes "from your A/c" with no tail — so the
  guard short-circuits before the amount and date are ever compared.

So the notice and the real debit both persisted *even when they shared a date and an
amount exactly* (rows 403/404 and 400, all 2026-07-28, all ₹1,999). The fix therefore
cannot be "improve the dedup"; the notice must not be an actual in the first place.

**2. "It inflates … the ₹1,16,271 'Everyday spending' figure the forecast leads with" —
false.** That figure comes from `_typicalMonthlySpendPaise`, which filters through
`_isConsumptionSpend`, which already excluded bodies matching `_kFutureDebitNoticeMarkers`.
Those 30 rows never reached it.

The leak was in the paths that had *no* such filter, because the vocabulary existed twice
and only one copy was consulted:

- `SeasonalEstimator.estimate` — fed `active` unfiltered from `SmsAnalysisSnapshot.reduce`.
  This is the real damage: the seasonal estimate feeds `ReconciliationMatcher` and the
  forecast lines.
- `RecurringDebitDetector._groups` — a notice and its real debit counted as two
  occurrences of one commitment.
- `SmsAnalysisSnapshot._yearOverYear`.

**3. Scope: 17 rows / ₹17,154 → 30 rows / ₹86,304.** The original counted only
`upcoming mandate`. The card-bill reminders alone are ₹66,149 — nearly four times the
task's own stated scope — and are the identical defect. Keying the fix on the parser's
existing `_futureNoticeMarker` covers all of them and is *less* code than a narrower
check.

---

## Fix (as landed)

1. **A future-tense notice is no longer a `ParsedTxn`.** `parseOne` returns null for it.
2. **It is not dropped either.** A new `SmsTransactionParser.parse` returns an
   `SmsParseResult` carrying either the actual or a `FutureDebitNotice` (payee, amount,
   the announced date, account). `parseOne` is now `parse(...).txn`, so every existing
   caller keeps working.
3. **`MandateNoticeObligations` converts the notice** to an `ObligationRecord` with
   `nextExpectedSource = explicitDueDate`, `recurrence = onetime` (one notice proves a
   date, not a cadence — next month's notice refreshes the same row),
   `userCadenceStatus = algorithmDetected` and `reviewStatus = needsReview` per TASK-18.
   `SmsScanOrchestrator` upserts them alongside the recurring candidates.
4. **One owner per rupee across the two obligation sources.** When the recurring detector
   has already locked a commitment for the same `merchantNorm`, the notice raises no
   second obligation — the commitment, backed by real occurrences, keeps the rupee. Found
   by test, not by inspection: without this the Google mandate produced two obligations.
5. **The vocabulary is now defined once**, as `kFutureDebitNoticePattern` in `sms_models`,
   with `ParsedTxn.isFutureDebitNotice` reading it at *read* time. It previously existed
   as a regex in the parser and a shorter, divergent substring list in `real_insights`,
   which is exactly why three read paths never saw the exclusion.

### Decision on the 30 rows already stored (required by this task)

**Fix forward, plus a read-time guard. Nothing is deleted.**

`refreshParse` rewrites a row whose parse changed; it has no path to delete a row that
should never have existed, and adding one would destroy 26 rows the user explicitly
confirmed. Instead `isFutureDebitNotice` is applied at read time in
`SeasonalEstimator`, `RecurringDebitDetector`, `_yearOverYear` and `_isConsumptionSpend`
— the same re-derive-from-the-redacted-body technique `_isConsumptionSpend` was already
documented as using so it "corrects already-stored rows without needing a rescan". The 30
rows stay on disk, keep the user's decisions, and stop counting immediately, with no
migration and no scan required.

Known consequence, accepted: the stored 30 still appear in the raw Activity list as
debits. They are excluded everywhere a number is computed from them.

## Tests written first

`test/sms_transaction_parser_test.dart`:

- [x] An upcoming-mandate notice does not produce a debit `ParsedTxn`.
      **RED:** `Expected: null / Actual: <Instance of 'ParsedTxn'>`.
- [x] It produces a notice carrying payee, amount and the mandate date.
      **RED:** `Null check operator used on a null value` — `parse().notice` was null.
- [x] The autopay pre-notice test (previously "takes the stated date and never
      auto-adds") rewritten: it now asserts no `txn` and a notice dated 2025-07-05,
      payee `netflix`, ₹499, account `1234`. The old assertion encoded the superseded
      keep-and-dedup design.
- [x] A *past-tense* mandate debit (`deducted … towards … UMRN:`) is still an actual.
      **GUARD, not regression coverage** — it passes with or without the tense check,
      because a past-tense body carries no future marker. It is here to fail if the
      vocabulary is ever widened onto TASK-31 format 2.

`test/sms_scan_orchestrator_test.dart`:

- [x] A mandate notice becomes a dated obligation and no transaction row.
      **RED:** `Expected: an object with length of <1> / Actual: []` — the notice was
      dropped entirely once it stopped being a debit.
- [x] A locked commitment for the same payee owns the rupee alone.
      **RED:** `Actual: [ObligationRecord, ObligationRecord]` — two obligations for one
      debit.

`test/seasonal_estimator_test.dart`:

- [x] An announced debit never enters the estimate. **RED:** `Expected: <0> / Actual:
      <66633>`.
- [x] The real debit beside it still counts once. **RED:** the pair estimated higher than
      the real debit alone.

`test/golden_corpus_test.dart` + `test/golden/hdfc.json`:

- [x] The NETFLIX pre-notice sample was relabelled `isTxn: false, notice: true`. Left at
      `isTxn: true` it silently became a false negative and quietly ate recall. A new
      corpus test asserts every `notice` sample yields no `txn` and a notice of the
      labelled amount, and that at least one such sample exists so the check is not
      vacuous.

## Verification

```bash
flutter analyze
flutter test
```

`No issues found!` · **772 passing, 0 failing** (764 before this task).

## Definition of done

- [x] Future-tense notices no longer stored as debits
- [x] They surface as dated obligations instead of being dropped
- [x] Decision recorded for the rows already stored (26 user-confirmed of 30)
- [x] `flutter analyze` clean, `flutter test` green
- [x] On device: re-measured after TASK-31 landed — see below
- [x] Suggested commit: `Treat future-dated bank notices as obligations, not debits`

## On-device result (2026-08-03, SM-G781B, after one pull-to-refresh)

**Zero future-notice rows were written by the scan.** Every row rewritten by the refresh
(`id > 697`, the pre-scan maximum) was checked against the notice vocabulary: `count=0`.
The 22 notice rows that remain are the pre-existing ones, untouched by design — they kept
their original low `id`s, so the refresh never rewrote them either.

**The obligations table went 2 → 8.** Five are new and carry
`next_expected_source=explicit_due_date`, which is the half of this task that was supposed
to be valuable:

| obligation | amount | source |
|---|---|---|
| `phonepe` | ₹120.07 | explicit_due_date |
| `google` | ₹1,999 | explicit_due_date |
| `google asia pacific pte.ltd` | ₹1,999 | explicit_due_date |
| `axis bank cc` | ₹15,191 | explicit_due_date |
| `bharat connect postpaid bill payment` | ₹181.36 | explicit_due_date |

Before this task the same table held two rows, both named after an opaque VPA local part.

**User decisions intact:** 187 confirmed and 6 dismissed, unchanged across the scan.

**"Need for September" did not move** (₹1,18,270 before and after). That is the expected
outcome and it corroborates correction 2 above: the headline is built from
`_typicalMonthlySpendPaise`, which already excluded notices, so there was nothing there to
recover. The five new obligations are `needsReview`, so they correctly do not enter the
forecast until the user confirms them.

## Findings opened by this task, not fixed here

Recorded so they are not re-discovered as new:

- **Two banks announce the same mandate.** Rows 403 (`AX-AXISBK-S`) and 404
  (`AD-AXISBK-S`) are the same 2026-07-28 Google notice from two sender IDs, and rows 23
  and 71 are the same `UMRN: HDFC7020208251013841` alert from `JM-` and `AD-`. Distinct
  `sms_id`s, so nothing dedupes them. Now harmless for notices (both fold into one
  obligation by `dedupeKey`) but **not** for the duplicated real `UMRN` debits.
- **A stale notice obligation is never retired.** Once a commitment locks for the same
  payee, the `sms_mandate:<payee>` row written by an earlier scan stays in `obligations`.
  Obligations are never deleted anywhere in the codebase, so this is pre-existing, but
  this task is the first to create a row that can be superseded.
