# TASK-47 — A card is billed for money that already left the bank

**Severity:** Critical · **Phase:** 9 · **Depends on:** Spec A Parts 1–2, TASK-30, TASK-41

---

## The promise being broken

> **One owner per rupee.** Every input amount must be attributed to exactly one owner.
> No amount may be counted twice, and none may vanish.

Both halves broke at once, on the same 29 rows.

Spec A Part 2 made a card's tail readable so the bill it will send could be named. That
split the shared `unknown` card bucket into one bucket per tail — and **two of the buckets
it opened are not credit cards.** Each got a line in "Needs your attention" claiming a bill
that will never arrive:

| Bucket | Claimed | What it actually is |
|---|---|---|
| Card 7102 | ₹3,56,000 | 23 HDFC ATM cash-outs, `Withdrawn … From HDFC Bank Card … Bal …`, drawn 2025-10-29 → 2026-07-17 |
| Card 7113 | ₹4,235 | 6 debit-card purchases, `Paid … Bal …`, already settled |
| Card 7117 | ₹590 | the one genuine credit card — correct |

**₹3,60,235 of the ₹3,60,825 that section named was wrong.** Card 7113's six rows were
already inside `isSpend` at ₹4,235, so its line was a *second* claim on the same rupees —
counted twice. Card 7102's ₹3,56,000 was in **no total at all** — vanished.

Before Part 2 both sat unnamed in the shared bucket and were windowed out by the 1 Aug
payment credit, contributing ₹0. Naming them gave each a bucket with no payment credit of
its own, so `windowStart == null` and the figure became a lifetime total.

---

## The defect

`CardCycleEstimator.estimate` already guarded against exactly this:

```dart
t.type != TxnType.atm &&
```

**It could not fire.** Every card row on the device was typed `pos`, the ATM cash-outs
included, because the body names the debit card. Measured over all 2,071 rows,
`type == atm && instrument == card` matched **zero**. The guard sat in the right place and
consulted a field that never disagreed with itself.

That is one defect with two halves, and this task fixes both:

1. the estimator bills a card for money the bank already paid out, and
2. the parser types a cash withdrawal as a card purchase, which is *why* the guard was dead.

---

## The fix, part 1 — key on the reported balance

`MoneyLens.reportsBankBalance` — a credit-card alert reports the available *limit*, a bank
debit-card alert reports the available *balance*. Both arrive as `instrument: card` whenever
the body says "Bank Card", so the wording is the only thing separating a purchase a
statement will bill for from one the bank has already settled.

**Keyed on the balance and deliberately not on the withdrawal wording.** A credit-card cash
advance *is* a withdrawal the statement bills for, so excluding on "withdrawn" would drop a
real bill; a cash advance reports the limit and never a balance, so this signal cannot make
that mistake. On this device the two rules agree — all 23 ATM rows report a balance as well
— so nothing is traded away here, but they are not equally safe on a body neither of us has
seen.

The vocabularies separate cleanly over all 2,071 stored rows: the balance marker fires on
**exactly 29** — all 23 of 7102 and all 6 of 7113 — on **none** of the other 586 card rows,
and no row anywhere carries both a balance and an available limit.

### Two candidates were measured and rejected

**Removing the dead `type != atm` guard** — rejected: it becomes live the moment the parser
half of this task lands, which it now has (see the device verification below).

**Keeping only buckets that carry credit-card evidence** (`avl lmt` and friends) — rejected
on measurement, and this is the one worth recording. **It is not clock-stable:**

```
buckets with ZERO credit-card evidence
  @ 2026-08-07 (13-month lookback from 2025-07-01):  [7102, unknown, 7113]
  @ 2026-09-07 (13-month lookback from 2025-08-01):  [7114, 7105, 7102, unknown, 7113]
```

Same data, calendar only. Cards 7114 and 7105 each carried **exactly one** evidence row, and
one month of lookback slide drops it — 1 → 0 for both. Card 7111 survives but its margin
collapses 11 → 2. Those two are genuine credit cards holding ₹93,706 and ₹3,419 of debits in
the window.

**A card's identity must not depend on the calendar**, so the prediction is pinned at two
clocks and that is part of the gate, not a nicety.

Honest limit on that rejection: at today's data the evidence filter would suppress nothing
*visible* — 7114 and 7105 currently estimate ₹-428 and ₹0, neither of which produces a line.
The failure is latent. But 7114's last payment was 2026-03-02, so the first purchase after it
turns that bucket into a real figure that would then be silently swallowed — which is the
"no silent exclusion" invariant, waiting to break.

---

## The fix, part 2 — type a cash withdrawal as cash

`_atmWord` was `\batm\b` alone. **HDFC never writes "ATM"** — it writes *"Withdrawn Rs.20,000
From HDFC Bank Card XX7102 At SCIENCE CITY-II"*. So `_type` fell through to
`instrument == card -> pos` and 23 cash withdrawals were stored as card purchases.

```dart
r'\batm\b|\bwithdrawn\b|\bwithdrawal\b'
```

`withdrawn` was already in `_txnVerb`, so the parser had always read it as a money-moving
verb; this is the same word deciding the rail as well. Blast radius measured at **exactly 23
rows** — no other row in 2,071 contains "withdraw", and the 34 already-`atm` rows match on
`\batm\b` and do not move.

**`\bwithdrawal\b` matches 0 rows in the corpus and is kept deliberately.** It is reachable
only when a second verb carries the row — `withdrawal` is in neither `_debitVerb` nor
`_creditVerb`, so a body using it alone yields no direction and no transaction at all. It is
kept because removing it would re-open this very defect on a body shape the codebase already
believes in: `kCashWithdrawalMarkers` contains `'cash withdrawal'`, so
`Rs.5,000 debited from A/c XX1234 for cash withdrawal` would be excluded from **both** spend
lenses by that marker while `_type` still called it `pos` — in no lens, no ATM item and no
coverage ratio. That is ₹3,56,000's exact shape, rebuilt.

Note the standard already in force: `'cash withdrawal'` and `'atm wdl'` in
`kCashWithdrawalMarkers` also match 0 rows, and `MerchantDisplay._withdrawn` already carries
the noun. This vocabulary family is a deliberate backstop, not a measured allow-list.

---

## Tests

`test/sms_transaction_parser_test.dart` — four, of which two are guards:

- an HDFC cash-out worded `Withdrawn` is an ATM withdrawal
- the spelled-out `cash withdrawal` is one too
- **guard:** an ordinary card purchase is still a POS purchase
- **guard:** a resolved VPA still outranks the withdrawal wording — `_type` tests UPI before
  ATM and that order has to survive

Each was mutation-checked. The last one matters: mutating the regex left it green, and only
mutating the UPI-before-ATM ordering in `_type` killed it — **it guards the ordering, not
the vocabulary.** Mutate the thing the test actually claims to guard.

`test/task47_prediction_test.dart` runs the production path — `allSince` →
`SmsLiveNormalizer.normalize` → `SmsAnalysisSnapshot.reduce` → reconciliation items — at
**two clocks**, because the defect is only visible once the items are built and a prediction
that stops at the estimator is not predicting what the user sees. It skips when no export is
present; `.private/` is gitignored because this repository is public.

---

## Definition of done

- [x] No card bill is claimed for money already out of the bank.
- [x] The parser types a cash withdrawal as cash even when the bank never says ATM.
- [x] Both pinned at two clocks; card identity does not depend on the calendar.
- [x] `flutter analyze` clean; `flutter test` **1033 passing, 0 skipped** (with the export
      present; 1030 + 3 skips without).
- [x] Offline prediction against a real export: ₹3,60,825 → ₹590, identical at both clocks.
- [x] Device verification — installed, refreshed, and read back.

---

## Device verification — 2026-08-07

Galaxy SM G781B, Android 13. Database md5-checked before and after every step; the export
matched the device side byte-for-byte each time. **`adb install -r` of the debug build wrote
nothing** — md5 identical across the install (`5a80321d…`). Only the pull-to-refresh wrote.

**The scan changed exactly 23 rows and nothing else:**

| | Before | After |
|---|---|---|
| rows | 2071 | 2071 |
| withdrawal rows typed | `pos` / card — 23 | **`atm` / card — 23** |
| all `type = atm` rows | 34 | **57** (= 34 + 23) |
| rows whose `type` changed | — | **23** |
| `type = atm AND instrument = card` | 0 | **23** |

A full `id:type` diff across both snapshots returns exactly those 23 rows.

**Downstream, observed rather than simulated.** The previous session could only simulate
these — stored bodies are redacted, so they cannot be re-parsed to predict — and the device
has now actually re-typed the rows:

| | Before | After (@2026-08-07) | After (@2026-09-07) |
|---|---|---|---|
| `CashCoverageLevel` | `none` | **`caveat`** | **`caveat`** |
| trailing-90d ATM total | ₹0 | **₹1,00,000** | **₹80,000** |
| cash-drain ratio | 0% | **17.9%** | **22.6%** |
| ATM reconciliation items | 0 | 0 | 0 |
| detected commitments | 2 | 2 | 2 |
| card lines total | ₹590 | ₹590 | ₹590 |

**The simulation was right on every outcome and wrong on the ratio** — it predicted 15.7%
and 18.9% against an observed 17.9% and 22.6%, because it used a larger discretionary
denominator than the shipped `_isTrackedDiscretionaryBankDebit` produces. The re-typing does
not touch that denominator at all (₹4,58,304.68 before and after): the 23 rows are
`instrument: card`, so they were never in that bucket. **A simulation that reproduces the
direction can still be wrong about the magnitude — say which numbers were observed.**

**On screen.** The CARDS group in "Why August looks like this" now carries exactly one line:

> Card 7117 bills aren't planned yet — spent since its last payment · **₹590** · Reconciled

Cards 7102 and 7113 are gone from it, and no card line appears anywhere in "Needs your
attention". Home is unchanged (`₹1,13,955 · 16 payments tracked`,
`Need for September ₹3,87,912`) **as it must be** — those 23 rows were already excluded from
spend by `kCashWithdrawalMarkers` before this change, and `CashCoverageLevel` moves messaging
and confidence wording, not a rupee figure.

### The dead guard is no longer dead

`CardCycleEstimator`'s `t.type != TxnType.atm` matched 0 rows before the refresh and matches
**23** after it. The two halves of this task now guard the same rows from opposite sides —
one on the type, one on the body. That redundancy is intended and neither is removable: the
body check is what works on rows a scan has not revisited, and the type check is what works
once it has.

### A latent risk closed on real data

17 rows share the merchant `science city-ii` — an ATM location stored as a payee — across 9
months. `RecurringDebitDetector` skips on `type == atm`, so before the fix nothing stopped
those becoming a phantom commitment. All 17 are now typed `atm`, and detected commitments
stayed **2 → 2** through the change.

---

## Still open after this task

1. **₹3,56,000 of cash still has no owner — the honest successor to this task.** The parser
   fix makes `CashCoverageMetrics` *see* the money (₹0 → ₹1,00,000 trailing) but does not
   **itemise** it. `ReconciliationMatcher` reads the current month only and the last
   withdrawal was 2026-07-17, so ATM items stayed 0 → 0. Whether past-month withdrawals
   deserve an owner is undecided.
2. **One omission renders as two tiles on one screen.** A `cardPurchase` item maps to
   `ForecastEventSource.cardStatement` in `forecast_adapter.dart`, landing in `lines` → the
   CARDS group; the same item is separately routed to `CoverageBucket.quantifiedExcluded` →
   `coverageLines` → "Needs your attention". Not observed for card 7117 on this device — its
   line is `Reconciled` and appeared only under CARDS — so the duplicate needs its own repro
   before it is chased.
3. **Two-digit card tails still read null.** `ICICI Bank Credit Card XX12` stays in the
   `unknown` bucket. Widening needs a collision policy.
4. **21 stored card rows carry no tail and no scan can fix them** — the parser returns no
   transaction for those bodies, and several hold an un-redacted tail in `raw_body_redacted`
   because they predate the current `SmsPrivacy._account`. TASK-04/45 family, unexamined.
5. **Bank-side refunds are still not netted from spend.** The rule table nets only card
   refunds.
6. **`MoneyLens` and `CardCycleEstimator` import each other.** Dart permits it and analyze is
   clean, but it is a smell; the alternative is moving `isCardBillPayment` into
   `money_lens.dart`.
7. **The ATM withdrawal vocabulary now lives in three places** — `_atmWord`,
   `MerchantDisplay._withdrawn` (now semantically identical, different alternation order) and
   `kCashWithdrawalMarkers` (deliberately different: a body-level backstop for rows the parser
   mis-typed). Unifying them changes behaviour in three consumers at once and needs its own
   measurement.
8. **All of Spec B** — statement SMS parsing, real statement totals, `statementResidualPaise`,
   the unitemised spend row, due dates, `statementDay`, true cycle windows, `CardCycle`
   construction in production, partial payments, EMI. **Spec B must open with horizon months,
   recurring overlap and partial-payment suppression.**
