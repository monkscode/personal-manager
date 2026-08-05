# TASK-42 — A mandate notice and the commitment it announces are two owners for one rupee

**Severity:** Important · **Phase:** 6 · **Depends on:** TASK-32, TASK-37

---

> **Premise check (2026-08-05). The plan's stated next task was wrong, in both of the cases
> it named.** Phase 5 and the Phase-6 handoff recorded the remaining duplicate obligations as
> a *merchant identity resolution* problem — "the join must come from the name", starting
> with the PhonePe pair, blocked because every stored obligation carries
> `category_key = 'other'`. Checked against the source and the device, none of that survives:
>
> 1. **The category blocker is aimed at the wrong mechanism.** TASK-23's same-category
>    ambiguity check is `_commitmentSuppression`, which joins a `RecurringCommitment` to a
>    *projected obligation*. Both members of each device pair are rows in the `obligations`
>    table. Nothing anywhere joins obligation to obligation:
>    `_projectCanonicalObligations` dedupes on `dedupeKey + month` (exact identity) and
>    `ReconciliationMatcher._obligationOwners` emits one owner per row unconditionally. The
>    `category_key` degeneracy is real and simply not reachable from these rows.
> 2. **The PhonePe pair cannot be joined by name at all.** `phonepe` and
>    `bharat connect postpaid bill payment` share no token, no prefix and no useful edit
>    distance.
> 3. **The Google pair must not be joined, and name similarity is exactly what would join
>    it.** `google` and `google asia pacific pte.ltd` are two *different* subscriptions —
>    proven below — and are far more alike as strings than the real duplicate is.
>
> Merchant-name identity resolution would have failed to fix the one real duplicate and would
> have destroyed ₹1,999/month of real commitment. The join has to come from what a notice
> *announces*, not from how the bank spelled the payee.

## The defect

`SmsScanOrchestrator` decided whether a mandate obligation was redundant by string equality
on the merchant:

```dart
final ownedByCommitment = {for (final c in candidates) c.merchantNorm};
...
if (ownedByCommitment.contains(obligation.merchantNorm)) continue;
await obliRepo.retireOwnedMandates(ownedMerchantNorms: ownedByCommitment, ...);
```

The rule the comment states is right — "when history has already locked a commitment for
this payee, that commitment owns the future debit". The implementation reads the payee's
*spelling*, and one bank spells one mandate two ways in two messages.

### The evidence, measured on the device (2026-08-05)

Axis sends two SMS per execution of the ₹120.07 autopay. The notice:

```
For the upcoming mandate set for 29-07-26, [amount] will be debited from your A/c
towards PhonePe for Autopay, [number]. To stop execution, pause mandate - Axis Bank
```

and the debit it announced, the same day:

```
Your A/c has been debited towards AutoPay  Bharat Connect PostPaid Bill Payment
for [amount] on 29-07-26. [vpa] - Axis Bank
```

That pairing repeats monthly from 2025-12-30 to 2026-07-29. The notices mint
`sms_mandate:phonepe`; the debits lock
`sms_recurring:bharat connect postpaid bill payment:monthly`. **One commitment, two
obligations, both live.** `sms_mandate:bharat connect postpaid bill payment` *was* retired by
TASK-37 — only because that notice happened to use the same words the debits do.

The ₹120.07 series runs back to 2019 under `vodafone`, through `phonepe` (2024-03 to
2024-09) and `phonepe autopay postpaid bill payment` (2024-09-29) to
`bharat connect postpaid bill payment` from 2024-10 on. It is one postpaid bill the rail kept
relabelling.

### Why the Google pair is not the same thing

| | `sms_mandate:google` | `sms_mandate:google asia pacific pte.ltd` |
|---|---|---|
| Notice from | Axis | HDFC |
| Due day | 28 | 11 |
| Real debits | `debited towards Google`, Axis, 28-03 … 28-07 | `UPI Mandate: … To Google Play`, HDFC, 11-06, 11-07 |

Two banks, two days, two independent debit series, both ₹1,999. **Two subscriptions**, both
correct, both must survive. The third ₹1,999 row,
`sms_recurring:xfkxfma537eoyvuzwkvss3vbvbr1oxoo:monthly`, was the Axis series under its old
opaque-handle name and TASK-37 already retired it.

## Fix

Three parts, and the second and third were both found by installing the build — neither was
visible from the source or from the first round of tests.

### 1. `MandateOwnership` — join on the announced debit

One object in `lib/services/mandate_notice_obligations.dart` answering "does a locked
commitment already own this mandate's debit?", asked by both the notice-write loop and the
retirement sweep. A predicate spelled out at each call site is not a rule (TASK-41).

A commitment owns a mandate when **either**

1. it names the same `merchantNorm` — the original join, kept; or
2. it announces the same debit: **same due day of the month** *and* **amount within the
   existing recurring jitter window**.

Both halves of (2) are load-bearing and the device supplies a counter-example for dropping
either. Day alone would merge `axis bank cc` with `hdfc bank ltd`, both due on the 5th at
wildly different amounts. Amount alone would merge the two Google subscriptions. A notice
naming no day is never joined, or `unnamed mandate` would be retired by whatever commitment
happened to cost the same.

`ObligationRepository.retireOwnedMandates(ownedMerchantNorms:)` becomes
`retireMandates(dedupeKeys:)`: which rows are redundant stopped being a question the SQL
layer could answer once the answer needed the amount and the day.

### 2. The newest notice for a payee wins

`sms_mandate:` is keyed on the payee **alone** — deliberately, because the announced amount
changes monthly. Every notice for a payee therefore lands on one row, and `_merge` takes
`incoming.dueDate` unconditionally, so the row ended up holding whichever notice the reader
happened to yield last. On the device that left `sms_mandate:phonepe` announcing **30 Dec
2025** when the newest notice for it said 29 Jul 2026 — and a stale day is exactly what stops
the mandate joining the commitment that owns it. The scan now collapses notices per payee,
keeping the latest-dated one, before writing.

**This is why device verification is not a formality.** Part 1 alone passed every test and
changed nothing on the phone: the stored row's day was 30, the commitment's was 29, and the
join missed by one day for a reason no fixture contained.

### 3. A payee is redundant only when *every* notice for it is owned

Nearly shipped as a silent exclusion. Axis announces two unrelated autopays as "towards
PhonePe": the ₹120.07 Bharat Connect **PostPaid** bill on the 29th, which the commitment
owns, and a ₹310 Bharat Connect **Gas** bill on the 3rd, which nothing else owns. Both
collapse onto `sms_mandate:phonepe`. Retiring the row because one of its notices was owned
took the gas bill out of the forecast with it — and the first device run did exactly that.

The sweep now retires a payee only when the scan read at least one notice for it and **none**
of them were unowned. Where an unowned notice exists the row stays live and carries that
debit instead. A payee the scan saw no notice for at all still falls back to judging the
stored row on its own fields, which is TASK-37's behaviour for notices that have aged out of
the inbox.

**Named limitation.** A postpaid-bill mandate announces a different amount every month
(₹118 / ₹167 / ₹181 measured in TASK-32), so a future notice can drift outside the jitter
window and survive as a separate obligation. That failure is visible and reviewable; retiring
a commitment the user really owes would be silent. The window stays tight on purpose.

**Also named, and not fixed here:** `sms_mandate:<payee>` cannot represent two concurrent
mandates for one payee. The PhonePe row now carries the gas bill because the phone bill has a
commitment; if both were unowned, one would still be lost. Keying a mandate by payee *and*
day-of-month is the obvious next move, and it needs its own task — the day drifts by one
(29/30 observed), so an exact-day key would fracture one mandate into two rows.

## Tests written first — RED symptoms recorded

All in `test/sms_scan_orchestrator_test.dart` (`TASK-42`):

- [x] A mandate the commitment spells differently is still retired — `sms_mandate:phonepe`
      ₹120.07 day 29 against `sms_recurring:bharat connect postpaid bill payment:monthly`
      ₹120.07 day 29. **RED:** `Expected: true Actual: <false>`.
- [x] The newest notice for a payee sets the due date whatever order the scan reads them in.
      **RED:** `Expected: DateTime:<2026-07-29> Actual: DateTime:<2025-12-30>` — the device
      symptom reproduced exactly.
- [x] A payee whose other mandate is unowned keeps its obligation (₹310 gas bill beside the
      owned ₹120.07 phone bill). **RED:** `Expected: false Actual: <true>`.
- [x] A stored mandate holding a stale day is retired on what the scan reads now.
      Production code came first for this one, so **RED was established by reverting the
      mechanism** (the `redundantPayeeKeys` clause) and re-running:
      `Expected: true Actual: <false>`.
- [x] Same amount, different due day → both survive (the two ₹1,999 Google mandates).
      **GUARD** — passed before and after.
- [x] Different amount, same due day → both survive (`axis bank cc` vs `hdfc bank ltd`, both
      day 5). **GUARD** — passed both ways.
- [x] A mandate with no due day is never matched by amount alone (`unnamed mandate`).
      **GUARD** — passed both ways.

The three guards constrain the *shape* of the fix rather than proving it — they are the
reason the join is amount-and-day rather than either alone — but they would not have caught
the defect.

## Verification

```bash
flutter analyze
flutter test
```

`flutter analyze` — No issues found. `flutter test` — **939 passing, 0 failing**
(932 after TASK-41; +7).

### Device — Samsung SM-G781B, 2026-08-05

Schema v5 throughout. Three build/install/scan cycles; parts 2 and 3 exist because of them.

| | before | after |
|---|---|---|
| transactions | 2,063 | 2,064 |
| `MIN(id)` / `MAX(id)` | 19 / 2787 | 19 / 2788 |
| review split | 1761 / 187 / 109 / 6 | 1762 / 187 / 109 / 6 |
| obligations live / retired | 7 / 3 | 7 / 3 |
| forecast_risk_decisions | 3 | 3 |
| known_accounts, `idx_*` | 0, 13 | 0, 13 |

**The one new row is a real SMS that arrived mid-session**, not a write of this change:
`provider:12554`, HDFC, `PAYMENT ALERT! … towards HDFC LTD`, ₹61,415, 2026-08-05 — the
month's home-loan EMI landing while the work was in progress. Every other count is
unchanged, and `MAX(id)` moved by exactly that one row.

The obligation count is unchanged, but its **content** is the result:

- `sms_mandate:phonepe` is live and now reads **₹310, day 3** — the gas bill, which nothing
  else owned and which no previous build had ever represented.
- The ₹120.07 phone bill is owned once, by
  `sms_recurring:bharat connect postpaid bill payment:monthly`.
- Both Google mandates untouched: ₹1,999 day 28 and ₹1,999 day 11. The guards hold on real
  data.

On Home, August's Drivers show `bharat connec ₹118` as a **single** row. Before this change
the same commitment produced a line from the mandate and a line from the commitment.

## Definition of done

- [x] A mandate obligation is joined to a commitment by the debit it announces, not by
      merchant spelling
- [x] The rule lives in one object, applied both where notices are written and where stored
      rows are swept
- [x] The row a payee's notices collapse onto carries the newest of them
- [x] A payee is retired only when every notice for it is owned — no silent exclusion
- [x] Guards prove day-alone and amount-alone are both unsafe, against real device rows
- [x] The two Google subscriptions survive
- [x] `flutter analyze` clean, `flutter test` green (939)
- [x] Device-verified, every count reconciled
- [x] Commit: `Own a mandate notice by the debit it announces`

---

## Found while verifying — not fixed here

**A paid EMI is counted twice because the actual and its obligation spell the payee
differently.** The ₹61,415 HDFC EMI landed during this session and August's Drivers now read:

```
hdfc bank ltd    ₹61,415
hdfc ltd         ₹61,415
```

"Required in bank" is ₹1,22,830 — exactly ₹61,415 too high. The obligation is
`sms_recurring:hdfc bank ltd:monthly`; the actual debit's merchant is `hdfc ltd`.
`ReconciliationMatcher._obligationMatchKey` builds its key from `merchantNorm`, so the actual
never folds into the owner it just paid and both are subtracted.

This is the `hdfc ltd` / `hdfc bank ltd` pair the plan has carried since Phase 5 — but the
join that matters is **actual → obligation** inside the reconciliation matcher, not
obligation → obligation, and unlike the pairs above this one *is* a name problem: the two
strings differ by one token, both name the same lender, and there is no announced-debit
evidence to substitute. Worth its own task.

Not caused by this change: the fold path is untouched here, and the double line appeared the
moment the EMI SMS arrived.
