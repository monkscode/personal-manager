# TASK-46 — The redaction floor covers derived columns

**Severity:** Important · **Phase:** 8 · **Depends on:** TASK-04, TASK-45

---

## The promise being broken

TASK-04 states it and it is still true: SQLCipher is deferred, so **redaction is the only
barrier** protecting data at rest, and `allowBackup="false"` is the second and last.

TASK-04 then applied that barrier to exactly one column. `redactBody` produces
`raw_body_redacted`; nothing else was ever classified. Five sibling columns are derived
from the *raw* body and stored in the clear beside it — `merchant`, `account_last4`,
`ref_number`, `balance_paise`, `upi_vpa_norm`.

TASK-45 measured the consequence: **236 rows whose stored `merchant` carried a non-public
identifier**, one of them reading `…credit card xx7117` in `merchant` while
`raw_body_redacted` on the same row read `Credit Card [account]`.

---

## What the device said, and how much of the premise survived

Predicted offline against a real export (2,065 rows) before anything was written, per the
TASK-43/44/45 precedent. **Two of this task's three premises did not survive.**

**1. The 236 rows are already gone.** Not migrated — *reparsed*. There are 17 scan batches
on the device, and TASK-30's reparse rewrote the stored merchants through TASK-45's fixed
parser.

| TASK-45 measured | Measured now |
|---|---|
| 180 stored merchants containing the dispute footer | **0** |
| 236 rows carrying a non-public identifier | **3** |

TASK-45's still-open item 1 resolved itself. Nothing in the plan predicted that; only a
query showed it. **A planned backfill can be overtaken by a mechanism that already
exists — check what the data looks like now before building the thing that fixes it.**

**2. The planned v6 migration was dropped.** A schema bump and a new `MigrationStep` kind
to rewrite four rows is not worth it, and the boundary rule below cleans them on the next
scan anyway.

**3. What was real was the mechanism, not the count.** Two of the three survivors store the
bare mobile number `9999999999`, and both carry `upi_vpa_norm = 9999999999@axl`. That is a
**live defect**, reproducible today, not a historical artifact.

---

## The defect

`lib/services/sms_transaction_parser.dart` — `_merchant`, the VPA branch:

```dart
final named = _namedPayee(lower);
if (named != null) return named;
if (upiVpa != null) return upiVpa.split('@').first;   // <- never tidied
```

TASK-45 routed **five** parser captures through `PayeeText.sanitize`. This is the sixth,
and it was missed. A phone-number VPA is the common Indian shape, so `9999999999@axl`
became the payee name `9999999999` — and `_tidyPayee` rejects a bare digit run precisely
because it is not a name.

**This is TASK-41's lesson repeating inside TASK-45's own remedy:** *a predicate applied at
call sites is not a rule; only one applied where the set is defined is.* Five out of six is
what a convention gets you.

It stayed invisible because the display layer hides it: `MerchantDisplay._isOpaque` matches
`^\d{6,}$`, so a 10-digit merchant is treated as opaque at render time and `enrich`
substitutes something readable. **Stored dirty, displayed clean** — the same shape TASK-45
found, where a body-derived name masked a wrong stored column.

---

## The fix

**1. The rule is enforced at the storage boundary.** `TransactionRepository._toRow` is the
one place a merchant becomes a stored value — both `_insertRow` callers pass through it,
and `_flagExisting`/`updateReviewStatus` write review columns only. The parser is the only
producer (`TxnSource.manual` has no producer anywhere in `lib/`), so no user-typed string
reaches this column and sanitising there is safe.

The five capture sites stay: they shape the capture and decide whether a merchant exists at
all. What changed is that the *guarantee* no longer depends on having found every path.

**2. The VPA branch is tidied like every other capture** — the actual bug.

**3. `SmsPrivacy` carries the register.** Every stored column is now in one of three
classes: floored, identifier-free, or a declared exception naming the feature that breaks
without it. `account_last4` (TASK-13), `ref_number` (TASK-43), `balance_paise` (TASK-22 and
TASK-43's discriminator) and `upi_vpa_norm` (payee identity, the self-transfer allow-list)
are exceptions, not oversights.

---

## Tests

`test/transaction_repository_test.dart`, all writing **straight through the repository,
bypassing the parser** — a test that went through the parser would pass already and prove
nothing about the guarantee.

- clears a bare mobile number captured from a UPI handle → `null`
- trims a card tail rather than storing it → `null`
- keeps the payee when only a trailing reference is dropped → `ecs/razorpay softw`
- leaves a genuine payee untouched — `zomato`, `priyalpatel1910`, `1mg`, `science city-ii`

The last is the **guard**, not the assertion: it passed before the fix, and without it the
first three would "pass" for the wrong reason if sanitising were too aggressive. Phase 5's
lesson — write the guard that proves the fixture, not only the assertion that proves the
fix.

`test/task46_prediction_test.dart` is the offline prediction harness. It runs the
production path — `allSince` → `SmsLiveNormalizer.normalize` → `SmsAnalysisSnapshot.reduce`
— twice and diffs the commitments, ownerKeys and orphaned risk decisions. It skips when no
export is present. `.private/` is gitignored: this repository is public.

---

## Definition of done

- [x] The rule is enforced where a merchant becomes a stored value.
- [x] The VPA capture path is tidied like the other five.
- [x] Every stored column is classified in `SmsPrivacy`.
- [x] `flutter analyze` clean; `flutter test` 979 passing, 1 skipped (the prediction).
- [x] Offline prediction run against the device: both identity gates pass.
- [x] Device verification — the two `9999999999` rows cleared on the next scan.

---

## Device verification — 2026-08-06

Built, installed over the existing app, database pulled before and after. The install alone
wrote nothing (same size, same mtime). **The scan changed exactly two rows and nothing
else:**

| | Before | After |
|---|---|---|
| rows | 2065 | 2065 |
| `merchant IS NULL` | 269 | **271** |
| confirmed / dismissed / needs_review / auto_added | 187 / 6 / 109 / 1763 | **identical** |
| obligations live / all | 7 / 10 | identical |
| risk decisions | 3 | identical |
| `SUM(amount_paise)` | 2955201368 | **identical** |
| schema version | 5 | 5 |

A full column diff across both snapshots returns exactly two rows:

```
provider:12045  9999999999 -> NULL   confirmed  -> confirmed   ₹1,999 unchanged
provider:10654  9999999999 -> NULL   auto_added -> auto_added   ₹45,000 unchanged
```

Zero rows gained or lost, zero `created_at` values restamped (TASK-26's guard), zero
obligations changed in `merchant`, `dedupe_key` or `retired_at`.

`provider:12045` was **confirmed**, and it still is — the reparse rewrote a derived column
without touching the user's decision, which is TASK-02's whole subject.

**Whole-history probe through the app's own search: `9999999999` → "No matching
transactions".** Home is unchanged (`₹1,14,879 · 11 payments tracked`,
`Need for September ₹4,08,217`), as it must be for a change that touches two labels and no
amounts. Transaction names render as TASK-45 recorded them — `Card Purchase`,
`Hdfc Bank Ltd`, `Lg Electronics App`, `Gwaliasweetspvtltd`. No Flutter, Dart or SQLite
error in logcat across the whole session.

All pulled database copies and screenshots deleted.

### One row the boundary cannot reach, as designed

`provider:1119` still stores `mob/ccpmt/8mcqqe000000/000000`. The offline prediction said
the *sweep* would trim it, and the sweep was the migration that was dropped. A boundary
rule only cleans a row something rewrites, and that row's SMS (2020-12-18) is no longer in
the inbox for a scan to revisit. **This is the difference between the migration and the
boundary, showing up exactly where it should.** Same for the two `cash-atm/*` and two
`neft/mb/*` rows from 2020–21.

If those five ever need cleaning, that is the argument for reviving the v6 migration — and
it is an argument from five rows, not from TASK-45's 236.

### The plan's cold-start correction is wrong

`OVERVIEW.md` records: *"a cold start DOES run a scan. TASK-41's verification wrote two rows
with no pull-to-refresh; the only difference was `am force-stop` before `am start`."*

It does not. `am force-stop` + `am start` was run here and the database was untouched after
two minutes of polling. **The only scan trigger in the app is pull-to-refresh** —
`home_screen.dart:43` and `:347` both call `_refreshFromSms`, which is the sole caller of
`ScanController.scan()`, which is the sole scan entry point. TASK-41 saw two rows appear and
attributed them to the launch.

Practical consequence for anyone verifying on device: **cold-starting is not enough, and a
database unchanged after a launch is not evidence that a change writes nothing.** Pull to
refresh, then compare.

---

## Still open after this task

1. **The identifier rule is narrower than "carries an identifier."** 19 rows hold a 4+
   digit run in `merchant`; the rule flags 3. The other 16 have digits glued to letters,
   spared **deliberately** — that is what keeps `priyalpatel1910` and `1mg` intact. But
   `neft/mb/axmb000000000000/payee name/state` holds an Axis NEFT reference *and* a
   beneficiary name, and `cash-atm/ffbt0000000` an ATM reference; `SmsPrivacy._reference`
   strips exactly that class from bodies. Widening is how TASK-45's offline pass caught a
   real regression, so it needs its own task and its own prediction.
2. **Nulling `merchant` on the VPA rows is a labelling win, not a privacy one.**
   `upi_vpa_norm` still holds `9999999999@axl` — the same digits, in a column the register
   declares load-bearing. Removing the duplicate is right; claiming it removes the phone
   number from the database is not.
3. **`merchant` on `obligations` was measured, not rewritten.** Zero of the 7 live
   obligations carry a digit run or a VPA, so there was nothing to fix. `dedupe_key`
   embeds the merchant, so a rewrite would change commitment identity — the hazard TASK-37
   and TASK-42 both paid for.
4. **One 2020 row** stores `mob/ccpmt/8mcqqe000000/000000` and carries no VPA. It will
   clear on a reparse if its SMS is still in the inbox, and never otherwise.
5. **`Info:` merchant capture** — TASK-45's recorded next labelling win, untouched here.
