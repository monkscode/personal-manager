# TASK-48 — A card's announcements are not its transactions

**Severity:** Important · **Phase:** 9 · **Depends on:** TASK-44, TASK-45, TASK-47

---

## The promise being broken

> **One owner per rupee.** Every input amount must be attributed to exactly one owner.
> No amount may be counted twice, and none may vanish.

> **A placeholder is not a name.** A derived column may not present a rail label to the
> user as though it were a payee.

A credit card sends three kinds of message: it *announces* what will happen, it
*acknowledges* what the holder did, and it *reports* a purchase. Only the third moved
money this month. The spend lens read all three as purchases, in three separate ways,
and separately declined to read the merchant name the third kind was already carrying.

| Defect | Rows in window | Effect on the spend lens |
|---|---|---|
| The monthly statement read as a purchase | 10 | **−₹35,882.70** (was over-counting) |
| The bill payment read as a refund | 2 | **+₹2,554.00** (was under-counting) |
| The purchase whose name was never read | 26 | none — labelling only |

---

## Defect 1 — the statement is an announcement

ICICI words the monthly statement:

> Statement is sent to … Total of ₹X or minimum of ₹Y **is due by** 05-APR-26.

The notice vocabulary carried `is due on` and `due for payment` but not `is due by`, so
the statement was stored and counted as a completed card purchase.

**It is worse than one wrong row a month.** A statement total is the sum of the purchases
that made it up, and every one of those was already counted on the day it was made — so
the statement counts them a second time, in a lump. The largest was ₹12,732 on
2026-03-25.

`is due by` appears in 51 rows / ₹7,96,416.63 across five shapes, and every shape is an
ICICI statement or standing instruction; no completed transaction uses the words. The two
existing alternatives merged into one, `is due (?:on|by)`, rather than gaining a
near-duplicate.

Fixed in `447f587`. Measured at two clocks: the spend lens dropped 379 rows /
₹19,13,275.14 to 369 / ₹18,77,392.44 — 10 rows and ₹35,882.70. `everydayCash` was
unchanged at ₹16,85,800.68, correctly, because `isEverydayCashSpend` already excludes card
rows and these were never in it.

---

## Defect 2 — the bill payment is an acknowledgement

A merchant refund and the holder paying their own bill both arrive as a **credit on the
card**, so only the wording separates them. `isCardBillPayment` recognised two shapes:

```dart
r'\bpayment\b[\s\S]{0,60}?\breceived\b'
r'|\breceived\b[\s\S]{0,60}?\btowards\s+your\b'
```

HDFC uses neither. It writes:

> HDFC Bank Cardmember, Online Payment of ₹X vide REF **was credited to your card**
> ending NNNN …

*"credited"*, never *"received"*. So the guard missed it, `MoneyLens.isSpend` took it for
a refund, and **paying the bill subtracted from spend** — exactly the failure the doc
comment above the guard already warned about.

8 rows in the corpus carry this wording, ₹40,797 lifetime, **all of them the identical
sentence — one shape, not a family.** Two are in the 13-month window, ₹2,554 together.

Fixed in `081fe4f` with a third alternative, anchored on `payment` for the same reason the
first is: Axis cashback (*"Cashback of X has been credited to your … Credit Card"*) and
the excess-amount reversal are also *"credited to your … card"* and are genuine refunds
that must keep netting against spend. Measured at two clocks: 369 rows / ₹18,68,934.44 →
367 / ₹18,71,488.44, the same **+₹2,554.00** and the same two rows at both — a data
change, not a sliding-window artefact.

---

## Defect 3 — the purchase already carried its name

31 rows reached the user as **"Card Purchase"**. The parser stores that placeholder when
no pattern finds a payee, and nothing downstream read past it: `MerchantDisplay` tried its
body patterns, missed both card shapes, fell through to the stored merchant, and handed
the placeholder back **with `resolved: true`** — asserting a name it did not have.

The names were in the text the whole time. Axis puts the merchant on its own line, after
the line holding the time:

```
Spent / Card no. XXNNNN / INR 100.00 / 07-07-25 21:16:01 /
Disha Enter / Avl Lmt INR 5000
```

ICICI puts it after the *second* `on`, single line:

```
<amt> spent using ICICI Bank Card XXNN on 27-Dec-25 on AMAZON INDIA CY. Avl Limit: …
```

A pattern for the first already existed and could not fire: it required the timestamp on
the line *immediately* after `Card no.`, and this template puts the amount on its own line
in between. Nothing existed for the second at all.

Fixed in `441727c`. **26 rows renamed at 2026-08-07, 15 at 2026-09-07** — fewer only
because the window slides off last July. Every one went from `Card Purchase` to a name;
none renamed from anything else, and none lost a name. No total moves.

### Why the fix is in `MerchantDisplay` and not the parser

This is the load-bearing decision of the task.

The parser's regexes run **at scan time, on the raw SMS**, which the export does not store.
A parser change therefore cannot be predicted offline and reaches an existing row only
after a device rescan. `MerchantDisplay` reads `rawBodyRedacted` **at read time**, so it
renames rows already in the database and the change can be measured before it ships.
Redaction replaced amounts and account numbers, never the merchant, so the name survives
in the text this layer sees.

The bank truncates to ~11 characters, and the corpus carries six spellings of one merchant
— `IND*Amazon.in`, `AMAZON PAY IN U/E/G`, `AMAZON INDIA CY`, `AMAZON`. `_canonical`
already collapses all six to `Amazon`, which is what makes these groupable rather than
merely legible.

---

## Context — the self-transfer arc

Four commits (`95cf328` … `2edd63f`) shipped `SelfTransferDetector`, its decision store,
schema v6, the review screen, and the snapshot wiring that made the question reachable at
all. The owner confirmed all three pairs on the device: **₹96,999 left the planning
baseline** (`everydayCashTxns` 303 rows / ₹17,82,799.68 → 300 / ₹16,85,800.68) and 0
candidates remain pending.

The detector *proposes* and the user *decides*, deliberately. A ₹44,604 card purchase and
an unrelated reimbursement of the same amount twelve minutes later are indistinguishable
to any rule. Two ₹6,000 debits to a payee sharing the owner's name are **real payments**,
per the owner — "a real payment" is not a way of postponing the question, it is what stops
a pair being proposed again.

`95cf328` also treats an RD auto-debit as savings. **It changes nothing today**: all 11 RD
rows are dated 2020-08 → 2021-07, none in the window, and both lenses are byte-identical
with the marker on and off at two clocks. Future correctness only; the commit says so.

---

## Tests

- `spend_classification_test.dart` — the HDFC "credited to your card" wording is a payment;
  a merchant refund and Axis cashback both stay refunds. Removing the `payment` anchor
  makes the second fail on the cashback row.
- `merchant_display_test.dart` — both card shapes resolve; the limit line does not become
  a payee.
- Suite 1061, `flutter analyze` clean.

**One test guards a composition, not a regex.** The Axis pattern takes the line after the
timestamp on faith. On a body with no merchant line it really does capture
`Avl Lmt INR 5000.00` — measured, not assumed — and what keeps that off the screen is the
`\bavl\b` footer rule in `PayeeText.sanitize`. Drop that rule and a payee named
`Avl Lmt Inr .00` appears. The test says so in its comment, because a reader who thinks
the regex is precise will loosen the wrong thing.

---

## Device verification — 2026-08-07

Built from `441727c`, `adb install -r`, cold launch. **No rescan, and none needed**:
`isFutureDebitNotice`, `isCardBillPayment` and `MerchantDisplay` all derive from
`rawBodyRedacted` at read time, so every fix in this task applies to rows already stored.
The device database md5 was identical before and after (`3f4f6765…`), confirming the
install wrote nothing.

Verified on screen: **Amazon — ₹590 on 5 Aug**, matching the predicted row exactly, with
its category resolved to Shopping. That row read "Card Purchase" on the previous build.

**Not verified on screen:** the two money deltas. Both touch rows dated February–June 2026,
so "Spent this month" cannot show them, and the monthly bars round to `₹1.6L`. They rest
on offline measurement against a database byte-identical to the device's — arithmetic, not
a screenshot.

---

## Measured and deliberately NOT done

Every carry-over item on the inherited backlog was measured this session. **Six moved
nothing.** Recorded here so they are not re-ranked as valuable a third time.

| Item | Claim inherited | Measured |
|---|---|---|
| Bank-side refunds | "smallest well-defined money fix" | 14 rows / ₹18,418.88, **every one dated 2018–2022, none in window**. Three are not refunds — two insurance rate-change adverts and an ATM reversal. |
| `Info:` merchant subset | "the best labelling win" | 41 rows, **none in window**. |
| ATM cash has no owner | ₹3,56,000 unowned | **Working as designed.** Rows *are* typed `atm` (not `pos`, as recorded). Coverage sees them on a **90-day** window, where the figure is ₹1,00,000 — not ₹3,56,000, which is a 13-month aggregate nothing claims to itemise. Reconciliation is current-month: at a clock inside a month with withdrawals it emits 4 and 5 items respectively. Zero in August is correct — no cash was drawn in August. |
| Digit runs in `merchant` | 17 rows, privacy | See *Still open* — 1 row, and not the 17. |
| Tailless card rows | 21 rows / ₹1,47,662 | Confirmed to the paisa, and **none of the 21 is a purchase**: 5 reward credits, 3 bill-payment receipts, 8 standing-instruction notices, 3 cashbacks, 2 credit-balance notices. A tail attributes a purchase to a bucket; there is no purchase here. |
| ATM vocabulary in three places | duplication | 34 rows diverge, **all one pattern**, `0` counted as spend, nothing newer than 2021-05-28. The old Axis form writes `info: cash-atm/…`; `\batm\b` matches but the substring markers do not. `MoneyLens.isSpend` tests `type == atm` *before* the marker backstop, so the outcome never differs. |
| `MoneyLens` ↔ `CardCycleEstimator` cycle | smell | Mutual import confirmed; Dart permits it, analyze is clean, no user impact. Breaking it relocates a predicate and touches every consumer. |

**The pattern worth carrying.** Both real finds this session came from probing *sideways* —
the ₹2,554 defect surfaced while measuring the unnamed purchases, and the merchant fix
landed in a different layer than the plan assumed. Neither was on the ranked list. A task
doc's own premises are evidence, not fact.

---

## Still open

**A machine token renders as a payee name.** `sy0525015` is stored in `merchant` and shown
as **`Sy0525015`** (2026-01-17, ₹400, in window). `MerchantDisplay._isOpaque` fails both
its rules on it: not 12+ characters of hex (`s` and `y` are not hex digits), not all
digits. This is TASK-46's defect class, surviving in one row.

Two 2021 rows also render a partly-stripped NEFT rail string as the payee name — the rail
prefix, the counterparty's name and the bank's, run together — but both are permanently
outside the 13-month window.

**Deferred, with the reason stated.** The fix means teaching `_isOpaque` to recognise a
mostly-digits token with a short alpha prefix — but that predicate decides the displayed
name of *every* transaction, and the neighbours are hostile: `samplepayee1910` is a real
person's handle and `1mg` is a pharmacy. Trading regression risk across every merchant name
for one ₹400 row is a poor trade. If taken, it needs the same gate this task used: a full
before/after name dump across the corpus at two clocks.

The inherited count of 17 comes from a bare `\d{4,}`. By the codebase's own definition of
an identifier — `PayeeText._identifier`, which requires a standalone run — it is **1 row**,
and that one is dated 2020. The other 16 are things the code deliberately decided are not
identifiers; its comment says so: *"digits glued to letters are part of the word."*

---

## Traps this task paid for

**Two spend-lens totals are both correct and differ by ₹8,458.** `447f587` quotes
₹18,77,392.44 and this task's measurements quote ₹18,68,934.44 for the same rows at the
same clock. The first is Σ `amountPaise`; the second is Σ `MoneyLens.signedSpendPaise`,
where a card credit counts negative. The gap is exactly twice the ₹4,229 of credits in the
lens. **Say which sum you mean.**

**A parser change cannot be predicted from the export.** Only `rawBodyRedacted` is stored;
the raw SMS is not. Any offline prediction of a scan-time change is measuring a text the
parser never sees in production.

**Truncating probe output invites a wrong generalisation.** The ATM-vocabulary conclusion
was first drawn from 12 of 34 printed rows and asserted for all 34. It happened to hold.
Print every row, or count the patterns.
