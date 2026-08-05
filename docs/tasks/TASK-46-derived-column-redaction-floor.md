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
- [ ] Device verification — the two `9999999999` rows clear on the next scan.

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
