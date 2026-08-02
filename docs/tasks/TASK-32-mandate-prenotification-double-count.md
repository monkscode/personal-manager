# TASK-32 — Upcoming-mandate notices are stored as completed debits

**Severity:** Critical (spec invariant breach) · **Phase:** 1 (parser/ingestion policy)

Not from the audit. Found on 2026-08-02 measuring the real device database after
installing the Phase-2 build.

---

## The defect

Banks send a pre-notification before a NACH mandate is collected:

```
For the upcoming mandate set for 29-07-26, [amount] will be debited from your A/c towards PhonePe…
For the upcoming mandate set for 28-07-26, your account will be debited with [amount] towards Google…
```

This is an **announcement of a future debit**, not a debit. The parser stores it as one:

```
direction=debit  type=other  merchant=NULL
```

Then the real debit arrives days later and is stored too. The same rupee is now counted
twice.

### Measured on live data

**17 rows** on the device are upcoming-mandate notices stored as debits — 14 of them
already `confirmed` by the user, 3 `auto_added` — totalling **₹17,154**.

Every one sampled pairs with a genuine debit of the *same amount* within ±7 days:

| announced | amount | matching real debits within ±7d |
|---|---|---|
| 2026-07-29 | ₹120 | 1 |
| 2026-07-28 | ₹1,999 | 1 |
| 2026-07-28 | ₹1,999 | 1 |
| 2026-07-03 | ₹310 | 1 |
| 2026-06-29 | ₹120 | 1 |
| 2026-06-28 | ₹1,999 | 1 |
| 2026-05-29 | ₹120 | 1 |
| 2026-05-28 | ₹1,999 | 1 |

This breaches the invariant the whole layer is built on:

> **One owner per rupee.** Every input amount must be attributed to exactly one owner.
> No amount may be counted twice, and none may vanish.

The amounts are small in absolute terms, but they inflate every historical month, and the
history is what the seasonal estimator learns the "recent monthly average" from — the
₹1,16,271 "Everyday spending" figure the forecast leads with.

Note the ₹1,999 recurrence: it is also the amount of the single detected obligation, so
the double count is landing on the one commitment the app did manage to detect.

---

## Fix

An upcoming-mandate notice is a **future-dated obligation signal**, not an actual. Two
parts:

1. **Do not store it as a `ParsedTxn` debit.** The tense is explicit and greppable —
   `will be debited`, `upcoming mandate set for`, `your account will be debited with`.
   `sms_ingestion_policy` already rejects promotional and failed-transaction messages
   (TASK-05); this is the same shape of check.
2. **Do not silently drop it either** — that would trade a double count for a silent
   exclusion. The notice names a payee, an amount and a date, which is precisely an
   `ObligationRecord` with `nextExpectedSource = explicitDueDate`. Route it there, so the
   forecast gains the upcoming mandate as a *dated obligation* and the real debit later
   reconciles against it through the existing matcher.

Part 2 is the more valuable half: these notices are the cleanest recurring-commitment
signal in the whole inbox, and today they are worse than useless.

**The 14 already-confirmed rows must be handled.** They are stored, and the user has
confirmed them. TASK-30's `refreshParse` only rewrites a row whose *parse* changed — it has
no path to delete a row that should never have existed. Decide and record: either add a
retire/supersede action to the ingestion policy, or leave the stored 17 and fix forward,
saying so plainly here.

## Tests to write first

`test/sms_transaction_parser_test.dart` / `test/sms_ingestion_policy_test.dart`:

- [ ] An upcoming-mandate notice does not produce a debit `ParsedTxn`. — expect RED
- [ ] It produces an obligation candidate carrying payee, amount and the mandate date.
- [ ] The real debit that follows reconciles against that obligation rather than adding a
      second event (drive it through the matcher, per TASK-12's double-count pattern).
- [ ] A *past-tense* mandate debit (`deducted … towards … UMRN:`) is still an actual —
      guard against the tense check swallowing the real thing. Ties into TASK-31 format 2.

## Verification

```bash
flutter analyze
flutter test
```

On device, re-measure: rows matching `For the upcoming mandate%` should no longer be
`direction=debit` actuals, and the affected months' totals should fall by the duplicated
amount.

## Definition of done

- [ ] Upcoming-mandate notices no longer stored as debits
- [ ] They surface as dated obligations instead of being dropped
- [ ] Decision recorded for the 17 rows already stored (14 user-confirmed)
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Treat upcoming-mandate notices as obligations, not debits`
