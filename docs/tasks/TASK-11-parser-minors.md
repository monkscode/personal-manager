# TASK-11 — Parser minors (8 items)

**Severity:** Minor · **Phase:** 1 · **Depends on:** TASK-05 through TASK-10 merged first

Eight small items in the parsing slice. Each is independent; do them in any order. None
changes behaviour materially on its own, but several are cheap hardening that prevents
the next class of bug.

---

## M1 — `_upiHandles` is missing most Indian bank handles

`lib/services/sms_transaction_parser.dart:23-32`

Omits `okaxis`, `apl`, `yapl`, `axisbank`, `icici`, `hdfcbank`, `sbi`.

**Effect:** an Axis UPI payee (`name@okaxis`) yields no `upiVpaNorm`, so merchant name,
`payeeType` and `TxnType.upi` are **all lost** for that transaction.

The two lists already disagree with each other — `test/merchant_display_test.dart:173`
uses `@okaxis`, which the parser's list doesn't contain.

- [x] Add the missing handles. Consider extracting one shared constant so the parser and
      `merchant_display` cannot drift again.

**Done.** All seven added (`okaxis`, `apl`, `yapl`, `axisbank`, `icici`, `hdfcbank`,
`sbi`). Seven tests, all genuinely red — each returned `upiVpaNorm == null`.

**No shared constant extracted, deliberately.** `merchant_display` carries no handle list
to drift *from*: it reads `upiVpaNorm.split('@').first` and never inspects the handle. The
drift the finding observed was between the parser and a *test* fixture, which the new
tests now pin directly. Extracting a constant with one consumer would add indirection
without removing a source of truth.

---

## M2 — `_ref` misses the spaced reference form

`lib/services/sms_transaction_parser.dart:49-52`

- `UPI Ref no 123456789012` (SBI's form) → `null`
- `Refno 123456789012` → captures `no123456789012` (the `no` is swallowed into the value)

- [x] Allow `no\.?\s*` before the capture group, and exclude it from the captured value.

**Already fixed — this finding was stale.** TASK-07 had already added `\s*(?:no\.?)?` to
`_ref` and documented why. Both forms return `123456789012` today. Added a regression
guard rather than redoing it; it was **green from the start**.

---

## M3 — no word boundary before `rs`

`lib/services/sms_transaction_parser.dart:37` and `lib/services/sms_privacy.dart:10`

Without `\b`, the text `…within 24 hrs. 5000 points…` matches `rs. 5000` as an amount.

- [x] Add `\b` before `rs` in both patterns. Cheap hardening; do it in both files so the
      parser and the redactor stay consistent.

**Done in both — but the two halves had very different severity, and the finding does not
say so.**

- **`sms_privacy` was genuinely broken and user-visible.** `Valid for 24 hrs. 5000 bonus
  points await.` redacted to `Valid for 24 h[amount] bonus points await.` — the redactor
  ate the tail of `hrs.` and left mangled text in the body a human reads in the review
  queue. Genuinely red.
- **The parser was already protected.** The `hrs. 5000` candidate does enter the amount
  pool, but TASK-07/08's verb-adjacency filter drops it: no transaction verb sits within
  the adjacency window of that number, while `Rs.450.00 debited` has one. The test for it
  was **green before the fix**. The boundary is still worth adding as hardening — it stops
  the bad candidate at the source instead of relying on a downstream filter — but it fixed
  no live parser defect.

---

## M4 — unconditional `+0.1` confidence has an invisible dependency

`lib/services/sms_transaction_parser.dart:349`

`confidence += 0.1` runs unconditionally. It is only *equivalent* to the spec's
"+0.1 for a debit/credit keyword" because line 110 returns null when direction is null.
That coupling is completely invisible at the point of the increment.

- [x] Add a one-line comment naming the dependency, or make the condition explicit. Do
      not change the arithmetic — the current value is correct.

**Done — comment, arithmetic untouched.** The comment names the coupling and states the
failure mode it guards: making `direction` optional without restoring the condition would
silently inflate every verb-less row's confidence past the auto-add threshold.

---

## M5 — `_type` uses unanchored substring matching

`lib/services/sms_transaction_parser.dart:281-291`

`contains('upi'|'atm'|'card'|'transfer')` against the whole lowercased body. Any of these
appearing incidentally (in a merchant name, a URL, marketing copy) misclassifies the
transaction type.

- [x] Anchor with word boundaries, and prefer the structured signals (VPA present →
      UPI; card tail present → card) over body substring matching.

**Done, both halves.** `_type` now takes `instrument`, checks the structured signals first
(resolved VPA → UPI, detected card instrument → POS), and consults the body only on word
boundaries. Two genuinely red tests: `ATMOSPHERE CAFE` classified as `TxnType.atm`, and a
card purchase at `UPIWALA STORE` classified as `TxnType.upi`. A guard pins that a real VPA
still classifies as UPI.

---

## M6 — redaction order swallows the word "Card"

`lib/services/sms_privacy.dart:31-37`

`HDFC Credit Card ending 4321` → `HDFC Credit [account]`. The account pattern consumes the
noun along with the digits, degrading context for the human reviewing the row.

- [x] Redact only the identifying digits, keeping the noun. Coordinate with TASK-04,
      which rewrites these patterns — ideally fold this in there and just verify it here.

**Already fixed by TASK-04, verified here as the finding suggested.**
`HDFC Credit Card ending 4321` → `HDFC Credit Card ending [account]`. Guard added; it was
**green from the start**.

---

## M7 — two tests restate the implementation

- `test/sms_ingestion_policy_test.dart:247-259` recomputes `_collisionSetId`'s exact
  join-and-hash, so it passes for **any** implementation, including a broken one.
  (TASK-09 also flags this — if TASK-09 is done, verify rather than redo.)
- `test/bank_pattern_library_test.dart:34-50` asserts the literal data is
  lowercase/uppercase. That is shape, not behaviour.

- [x] Replace both with assertions on observable behaviour. If TASK-10 chose to delete
      `bank_pattern_library`, the second one disappears with it.

**Both closed, neither needed work here.**

- The collision-id test no longer recomputes the hash. TASK-09 replaced it with
  behavioural assertions: the set id is stable across differing `sms_id`s for the same
  tuple, and differs when the amount differs. Verified rather than redone, as instructed.
- The `bank_pattern_library` shape test went with the module in TASK-10 (Option B).

---

## M8 — `payee_classifier` ignores `direction`

`lib/services/payee_classifier.dart:43`

`needsConfirmation` and `untrackedCashCaveat` are set for **credits** too, even though
both doc comments say "outflow". Callers must remember to filter, and nothing enforces it.

- [x] Either take `direction` into account inside the classifier, or make the doc comments
      accurate and add an assertion at the call sites. Prefer the former.

**Done the preferred way** — gated inside the classifier, and the doc comments now state
the inflow behaviour too. Two genuinely red tests: an inflow from an unknown person set
`needsConfirmation`, and a credit on a wallet handle set `untrackedCashCaveat`. A guard
pins the debit cases unchanged. The counterparty is still classified identically in both
directions; only the two outflow flags are gated.

> **Caveat on this item's value.** `PayeeClassifier` has **no production caller** — it is
> matched only by its own file and its own test. "Callers must remember to filter" is
> therefore vacuous: there are no callers. The change is correct and makes the class right
> for whenever it is wired, but it alters no shipped behaviour. See the correction block in
> TASK-10 for the evidence, including device data showing zero `wallet` and zero `merchant`
> rows across 383 transactions. **Wiring or deleting `PayeeClassifier` is not covered by
> any task and needs one** — the same Defect-1 decision applied to a second dead module.

---

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] All eight items addressed (or explicitly closed as no-op with a reason recorded here)
- [x] Tests added for M1, M2, M3, M5 and M8 — the ones with observable behaviour change
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Harden parser patterns and replace implementation-restating tests`

### Outcome

**658 → 676 passing, 0 failing.** 18 tests added: **12 genuinely red**, 6 regression
guards that were green before the fix.

| Item | Verdict |
|---|---|
| M1 `_upiHandles` | Real. 7 red — every listed handle yielded `upiVpaNorm == null` |
| M2 `_ref` spaced form | **Stale finding** — already fixed by TASK-07. Guard only |
| M3 `\b` before `rs` | Real **in the redactor only** (`24 h[amount]`). Parser half already masked by verb-adjacency |
| M4 unconditional `+0.1` | Real, comment-only as instructed |
| M5 `_type` substrings | Real. 2 red — `ATMOSPHERE` → ATM, `UPIWALA` → UPI |
| M6 redaction eats "Card" | **Stale finding** — already fixed by TASK-04. Guard only |
| M7 tests restate impl | **Both closed without work** — TASK-09 and TASK-10 got there first |
| M8 classifier ignores direction | Real. 2 red — but on a class with no production caller |

Three of the eight findings (M2, M6, M7) were already resolved by earlier tasks in this
plan and needed verification, not fixes. One (M3) was materially overstated for the parser
and understated for the redactor.
