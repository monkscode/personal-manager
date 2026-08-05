# TASK-44 — Two bank announcements are still booked as real money

**Phase 7. Severity: Critical.** Found 2026-08-05 by reading the device database
after Phase 6 closed, not from the plan's stated next task.

---

## The plan's stated next task is not this, and why

TASK-42 closed by naming its own successor:

> `sms_mandate:<payee>` still cannot represent two concurrent mandates for one
> payee. Keying a mandate by payee *and* day-of-month is the obvious next move,
> and it needs its own task.

That defect is real but **latent on this device today**. The only payee carrying
two mandates is `phonepe` (the ₹120.07 Bharat Connect postpaid bill and the ₹310
Bharat Connect gas bill), and TASK-42's own fix already separates them: the
postpaid bill is owned by `sms_recurring:bharat connect postpaid bill payment:
monthly`, so the surviving `sms_mandate:phonepe` row carries the gas bill alone.
Nothing is lost right now. It stays open as a **latent** item.

Two things that are *not* latent were sitting beside it, and both are the defect
TASK-32 and TASK-41 exist to prevent — an announcement counted as money that
moved. Neither is caught, because the shared vocabulary that defines "this is an
announcement" does not contain the words these two banks use.

---

## The defect

`kFutureDebitNoticePattern` (`lib/data/sms_models.dart:218`) is the single source
of truth, read at write time by the parser and at read time by
`ParsedTxnFutureNotice.isFutureDebitNotice`. It lists six phrasings:

```dart
r'\bwill be (?:debited|credited|deducted)\b'
r'|\bis due on\b'
r'|\bdue for payment\b'
r'|\bscheduled for\b'
r'|\bupcoming mandate\b'
r'|\bmandate set for\b'
```

Two families on the device match none of them.

### A — ICICI Standing Instruction: "to be debited"

> `Payment of [amount] towards Merchant Amazon **to be debited** from ICICI Bank
> Credit Card 7117, as per Standing Instruction`

**8 rows, ₹4,081.10**, every one stored as a completed debit. Four of them are
followed by the real card debit two to three days later, so the rupee is counted
twice; four have no partner at all, so they are pure phantoms:

| notice id | date | amount | real debit | its date | gap |
|---|---|---|---|---|---|
| 19 | 2026-06-24 | ₹399.00 | 673 | 2026-06-26 | 2d |
| 67 | 2026-04-24 | ₹370.50 | 676 | 2026-04-26 | 2d |
| 125 | 2026-02-08 | ₹1,499.00 | 685 | 2026-02-11 | 3d |
| 180 | 2025-12-25 | ₹370.50 | 694 | 2025-12-27 | 2d |
| 1098 | 2025-09-24 | ₹359.10 | — | — | — |
| 1143 | 2025-08-25 | ₹389.50 | — | — | — |
| 1176 | 2025-07-25 | ₹351.50 | — | — | — |
| 1250 | 2025-05-25 | ₹342.00 | — | — | — |

Double-counted ₹2,639.00; phantom ₹1,442.10. Four of the eight are
**user-confirmed**, so they are exactly the rows TASK-41's "retire, never delete"
rule exists for — they must stop counting without being deleted.

### B — HDFC NACH mandate registration, booked as **income**

> `Auto Pay (HDFC Bank NACH Mandate): [amount] UMRN:HDFC[number] To:HDFC LTD
> Freq MNTH **received today for processing**.`

**2 rows, ₹2,22,830**, and both are stored as **credits**:

| id | date | amount | direction | payee in body |
|---|---|---|---|---|
| 1166 | 2025-08-02 | ₹1,22,830 | credit | `HDFC LTD` Freq MNTH |
| 1164 | 2025-08-03 | ₹1,00,000 | credit | `Indian Clearing Corporati` Freq ADHO |

Nothing moved. This is a *mandate registration* — the bank confirming it has
accepted a standing authority, and the amount is the mandate **ceiling**, not a
payment. `received` drives `_direction` to credit, so ₹2,22,830 of phantom income
enters the history that the salary and income baselines are learned from.

The ceiling reading is confirmed by the number itself: ₹1,22,830 is exactly
2 × ₹61,415, the HDFC EMI that TASK-43 spent its length on. The mandate is
authorised for double the instalment; nobody was ever paid ₹1,22,830.

**Combined, 10 rows and ₹2,26,911.10 are counted as money that never moved.**

---

## Why the vocabulary, and not another call-site check

TASK-41's lesson was that a predicate applied at call sites is not a rule.
That half is already right: the check sits at `active` in
`SmsAnalysisSnapshot.reduce`, the one place the working set is defined, so every
read path inherits it. **The rule is in the right place and simply never fires**,
because the pattern it consults does not know these words.

So the fix is two entries in the shared pattern and nothing else. Because
`isFutureDebitNotice` re-derives from the stored redacted body at read time, the
10 rows already on disk stop counting the moment the pattern learns the words —
no migration, no schema bump, no row deleted, and the four user-confirmed rows
keep their confirmation.

`_parseActual` returns `null` on a pattern match (`sms_transaction_parser.dart:
399`), so new messages of either shape stop being stored as actuals too.

**Family B is deliberately *not* routed to an obligation.** `_parseNotice`
requires `_direction == debit` and B infers credit, so it returns `null` and B
becomes neither a transaction nor an obligation — which is correct, since a
registration names no dated debit and its amount is a ceiling. Family A does
reach `_parseNotice` and will mint `sms_mandate:merchant amazon`; that obligation
is `onetime` with a due date already in the past, so it is never projected into a
future month and surfaces as a reviewable `pastDueObligation` coverage line
rather than as new money.

---

## Measured blast radius (2,065 real device rows)

Offline sweep of the proposed pattern over every stored row:

| phrase added | rows newly excluded | value |
|---|---|---|
| `to be debited` | 8 | ₹4,081.10 |
| `received today for processing` | 2 | ₹2,22,830.00 |

**Exactly 10 rows, ₹2,26,911.10, zero collateral.** Every one of the 10 was read
and is an announcement; no completed transaction in the database contains either
phrase. Ten further future-tense phrasings were swept and matched nothing outside
the existing six (`to be deducted`, `would be debited`, `shall be debited`,
`will get debited`, `is scheduled`, `payable by`, `before due date`, `pay by`,
`e-mandate`, `auto pay` beyond the two rows above).

The 32 rows / ₹86,734 that TASK-41 already excludes are unchanged — re-measured
here and they still reconcile exactly.

---

## The fix

Add two alternatives to `kFutureDebitNoticePattern`, each with the family it
names in a comment:

```dart
r'|\bto be debited\b'                      // ICICI Standing Instruction (A)
r'|\breceived today for processing\b'      // NACH mandate registration (B)
```

Nothing else changes. The predicate's contract widens from "future tense" to
"announcement rather than record", which is what its own doc comment already
claims it is for; the doc comment is updated to say so.

---

## Tests

Write each failing first and record the RED.

1. `an ICICI standing-instruction notice is not an actual` — the row-19 body
   parses to no `ParsedTxn`.
2. `a stored standing-instruction row stops counting at read time` —
   `isFutureDebitNotice` is true for the stored redacted body.
3. `a NACH mandate registration is not income` — the row-1166 body parses to no
   `ParsedTxn`, and `isFutureDebitNotice` is true for the stored row.
4. `the working set excludes both announcements` —
   `SmsAnalysisSnapshot.reduce`, one row in each family plus a real debit;
   only the real debit survives `active`.
5. `a user-confirmed announcement is excluded without being deleted` — the row
   stays in `history`, leaves `active`.
6. GUARD `the real card debit that follows is still counted` — the row-673 body
   (`spent using ICICI Bank Card … on AMAZON INDIA CY`) is unaffected.
7. GUARD `a completed NACH debit is still counted` — an `Auto Pay` body in the
   past tense (`debited towards AutoPay …`) still parses as an actual, proving
   the new words did not swallow the 38 real autopay rows.
8. GUARD `the six existing phrasings still match` — regression on the pattern.

---

## Definition of done

- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — **962 passing, 0 failing** (952 before; 10 added).
- [x] Offline sweep re-run over the exported rows: exactly 10 suppressed.
- [x] Device: August's headline unchanged (all 10 rows predate August 2026);
      row counts reconciled before and after and nothing deleted.

---

## Status — done, device-verified 2026-08-05

### REDs, each observed before the fix

The three GUARDs passed against the unfixed code and again after it, which is
what makes them guards rather than regression coverage. The other seven failed:

| Test | RED |
|---|---|
| an ICICI standing-instruction notice produces no transaction | `Expected: null` / `Actual: ParsedTxn` |
| a NACH mandate registration produces no transaction | `Expected: null` / `Actual: ParsedTxn` |
| a registration is not routed to an obligation either | `Expected: null` / `Actual: ParsedTxn` |
| a stored standing-instruction row is an announcement | `Expected: true` / `Actual: <false>` |
| a stored NACH registration is an announcement | `Expected: true` / `Actual: <false>` |
| the working set excludes both announcements | `Expected: length <1>` / `Actual: [ParsedTxn, ParsedTxn, ParsedTxn]` |
| a user-confirmed announcement is excluded without being deleted | `Expected: true` / `Actual: <false>` |

### Predicted offline, then measured on the device

The real `kFutureDebitNoticePattern` was run over all 2,065 exported device rows
before the build was installed, comparing the six-phrase pattern against the
eight-phrase one:

```
TOTAL ROWS: 2065
ALREADY EXCLUDED: 32 rows, 8673429 paise      <- TASK-41, reconciles unchanged
NEWLY EXCLUDED:   10 rows, 22691110 paise     <- exactly the predicted set
```

All 10 were printed and read: 8 ICICI standing instructions (in two body shapes,
`Payment of … towards Merchant Amazon to be debited …` and `Dear Customer, your
payment of … for Amazon to be debited …`, both caught by the one phrase) and the
2 NACH registrations. **Zero collateral.**

### Device — Samsung SM-G781B, 2026-08-05

Installed over the previous build and cold-started. August's surface is
unchanged, which is the prediction: every one of the 10 rows predates August
2026, the newest being 2026-06-24.

| | before | after |
|---|---|---|
| Spent this month | ₹1,14,879 · 11 payments | ₹1,14,879 · 11 payments |
| Your plan now | ₹61,415 | ₹61,415 |
| Need for September | ₹4,08,217 | ₹4,08,217 |
| Apr / Jun / Jul bars | ₹1.5L / ₹1.5L / ₹1.1L | ₹1.5L / ₹1.5L / ₹1.1L |

April and June each contain one excluded row (₹370.50 and ₹399.00), too small to
move a bar quoted to ₹0.1L. The two ₹2,22,830 NACH credits fall in August 2025,
outside the six-month bar window — **their removal from the income baseline is
verified by the offline sweep and the unit tests, not by a screen**, and is
recorded that way rather than claimed as observed.

### Database

**Byte-identical before and after** — `md5sum` equal
(`98791538d1d6bbbed66cdc6fffd59206`), 2,065 rows, `MIN(id)` 19, `MAX(id)` 2789,
1763 auto_added / 187 confirmed / 109 needs_review / 6 dismissed, 10 obligations
(7 live), 3 forecast_risk_decisions. The cold start ran a scan and reported "You
are up to date — no new messages". The fix is entirely read-time and persists
nothing, so no row was touched and the four user-confirmed announcements keep
their confirmation. All pulled copies and screenshots deleted.

---

## New, measured, unfixed — found by this install

August's transaction list renders the 5 Aug ICICI card purchase as **`[number]`**
where the stored `merchant` is `card purchase`. A redaction placeholder is
reaching the user as a payee name.

Recorded as an **observed symptom, not a diagnosed mechanism**: the stored column
says `card purchase`, so something at read time is producing `[number]` instead.
The obvious suspect is TASK-30's reparse of stored rows — the parser re-run over
`raw_body_redacted` sees `[number]`/`[amount]`/`[account]` tokens where the
original body had digits — but that was **not** confirmed here and must be
checked before it is built on, per this plan's standing rule about premises.

