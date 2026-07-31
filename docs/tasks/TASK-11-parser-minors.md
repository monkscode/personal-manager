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

- [ ] Add the missing handles. Consider extracting one shared constant so the parser and
      `merchant_display` cannot drift again.

---

## M2 — `_ref` misses the spaced reference form

`lib/services/sms_transaction_parser.dart:49-52`

- `UPI Ref no 123456789012` (SBI's form) → `null`
- `Refno 123456789012` → captures `no123456789012` (the `no` is swallowed into the value)

- [ ] Allow `no\.?\s*` before the capture group, and exclude it from the captured value.

---

## M3 — no word boundary before `rs`

`lib/services/sms_transaction_parser.dart:37` and `lib/services/sms_privacy.dart:10`

Without `\b`, the text `…within 24 hrs. 5000 points…` matches `rs. 5000` as an amount.

- [ ] Add `\b` before `rs` in both patterns. Cheap hardening; do it in both files so the
      parser and the redactor stay consistent.

---

## M4 — unconditional `+0.1` confidence has an invisible dependency

`lib/services/sms_transaction_parser.dart:349`

`confidence += 0.1` runs unconditionally. It is only *equivalent* to the spec's
"+0.1 for a debit/credit keyword" because line 110 returns null when direction is null.
That coupling is completely invisible at the point of the increment.

- [ ] Add a one-line comment naming the dependency, or make the condition explicit. Do
      not change the arithmetic — the current value is correct.

---

## M5 — `_type` uses unanchored substring matching

`lib/services/sms_transaction_parser.dart:281-291`

`contains('upi'|'atm'|'card'|'transfer')` against the whole lowercased body. Any of these
appearing incidentally (in a merchant name, a URL, marketing copy) misclassifies the
transaction type.

- [ ] Anchor with word boundaries, and prefer the structured signals (VPA present →
      UPI; card tail present → card) over body substring matching.

---

## M6 — redaction order swallows the word "Card"

`lib/services/sms_privacy.dart:31-37`

`HDFC Credit Card ending 4321` → `HDFC Credit [account]`. The account pattern consumes the
noun along with the digits, degrading context for the human reviewing the row.

- [ ] Redact only the identifying digits, keeping the noun. Coordinate with TASK-04,
      which rewrites these patterns — ideally fold this in there and just verify it here.

---

## M7 — two tests restate the implementation

- `test/sms_ingestion_policy_test.dart:247-259` recomputes `_collisionSetId`'s exact
  join-and-hash, so it passes for **any** implementation, including a broken one.
  (TASK-09 also flags this — if TASK-09 is done, verify rather than redo.)
- `test/bank_pattern_library_test.dart:34-50` asserts the literal data is
  lowercase/uppercase. That is shape, not behaviour.

- [ ] Replace both with assertions on observable behaviour. If TASK-10 chose to delete
      `bank_pattern_library`, the second one disappears with it.

---

## M8 — `payee_classifier` ignores `direction`

`lib/services/payee_classifier.dart:43`

`needsConfirmation` and `untrackedCashCaveat` are set for **credits** too, even though
both doc comments say "outflow". Callers must remember to filter, and nothing enforces it.

- [ ] Either take `direction` into account inside the classifier, or make the doc comments
      accurate and add an assertion at the call sites. Prefer the former.

---

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] All eight items addressed (or explicitly closed as no-op with a reason recorded here)
- [ ] Tests added for M1, M2, M3, M5 and M8 — the ones with observable behaviour change
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Harden parser patterns and replace implementation-restating tests`
