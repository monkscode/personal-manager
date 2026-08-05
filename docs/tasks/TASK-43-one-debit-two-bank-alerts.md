# TASK-43 — One ACH debit, two bank alerts, counted twice

**Phase 6. Severity: Critical.** Found 2026-08-05 by reading the device database
while starting the task the plan *called* TASK-43.

---

## The plan's premise was wrong, and it is corrected here

OVERVIEW.md closed TASK-42 with this as the next task:

> August's Drivers now show `hdfc bank ltd ₹61,415` beside `hdfc ltd ₹61,415` …
> `ReconciliationMatcher._obligationMatchKey` builds its match key from
> `merchantNorm`, so an actual never folds into the obligation it just paid when
> the two spell the payee differently. Unlike the obligation pairs above, this
> one *is* a name problem.

Three parts of that are wrong.

1. **Neither row is the obligation. Both are actual debits.** The database holds
   two distinct August rows at ₹61,415, from two different SMS:

   | id | sms_id | sender | merchant | acct | balance | body |
   |---|---|---|---|---|---|---|
   | 2786 | `provider:12552` | `VM-HDFCBK-S` | `hdfc bank ltd` | — | 2902221 | `UPDATE: [amount] debited from HDFC Bank [account] on 05-AUG-26. Info: ACH D- HDFC BANK LTD-[number]. Avl bal:[amount]` |
   | 2788 | `provider:12554` | `JD-HDFCBK-S` | `hdfc ltd` | 7106 | — | `PAYMENT ALERT! [amount] deducted from HDFC Bank A/C No [account] towards HDFC LTD UMRN: HDFC[number]` |

   One ACH mandate execution — an HDFC Ltd home-loan EMI collected from an HDFC
   Bank account — reported twice: once by the account-debit alert, once by the
   mandate system. Both are past tense, so `isFutureDebitNotice` correctly leaves
   both alone.

   Reconciled exactly: 13 August debit rows, minus the TASK-41 notice (₹118),
   = **12 rows summing ₹1,76,293.97**, against the card's "₹1,76,294 ·
   12 payments tracked" and **12 driver rows**. Every driver row is an actual;
   no obligation row appears in August's plan at all.

2. **`_obligationMatchKey` is not the gate.** It feeds `distinctKeys` in
   `_foldActualsIntoOwners`, which decides whether several *matched* owners are
   one logical obligation. Whether a debit reaches an owner at all is
   `_matches`. The quoted mechanism is not the one that runs.

3. **`_matches` never reaches the merchant comparison for this pair anyway.**
   `_withinWindow` is `actual.year == reference.year && actual.month ==
   reference.month` — a same-*month* test, not a day window. The obligation
   `sms_recurring:hdfc bank ltd:monthly` carries `due_date = 1788546600000` =
   **2026-09-05 IST**, and `_obligationOwners` uses the stored `dueDate` without
   rebasing it onto the target month. For August, `_matches` returns `false` at
   the window check, before the merchant strings are ever compared.

**The prescribed fix would not have moved this number.** Relaxing
obligation↔actual name matching cannot remove an actual↔actual duplicate.

It *is* a merchant-identity defect — in the dedupe policy, not the matcher.

---

## The defect

Two gates each independently prevent the pair from being recognised, and both
sit in code whose stated purpose is exactly this case. `SmsLiveNormalizer`'s
own doc comment:

> **Dedup** identical bank events that were delivered more than once — the
> classic Indian-bank case where the same alert arrives under several DLT sender
> headers (`VM-HDFCBK-S`, `AD-HDFCBK-S`, …).

**Gate 1 — an unknown account is treated as a different account.**
`SmsIngestionPolicy._weakCollision` requires
`a.accountLast4 != null && a.accountLast4 == b.accountLast4`, and
`SmsLiveNormalizer._tuple` buckets on `accountLast4 ?? ''`. Row 2786 has no
account, row 2788 has `7106`, so the two never meet. The *strong* lane in the
same file already argues the opposite, and is right:

> Account, when present on both, must agree; an absent account no longer blocks
> the match (a resent UPI alert often drops the a/c tail).

**Gate 2 — two spellings of one payee are read as two payees.**
`SmsIngestionPolicy._hasDistinguishingSignal` returns `true` — *these are
different payments* — whenever both merchants are non-empty and unequal.
`hdfc bank ltd` vs `hdfc ltd` trips it. This is the design's main discriminator
for genuine repeats ("mutual-fund SIPs (different UPI ref/payee in the body)"),
and a spelling variance defeats it.

**Consequence.** ₹61,415 is counted twice. On the device today: `Required in
bank ₹1,22,830`, `Lowest balance ₹-22,830 on 5 Aug`, `Free ₹-22,830`. The true
figures are ₹61,415 and **+₹38,585**. The app tells the user they are ₹22,830
short when they are ₹38,585 clear.

---

## Measured blast radius (2,064 real device rows)

Offline sweep over every row, comparing today's rules against the proposal:

- **Pairs colliding today: 66.** All have equal-or-blank merchants. **Untouched
  by this task** — they stay flagged and both members stay counted.
- **New pairs under the proposal: 6.** All six are the same HDFC EMI, in the six
  months where both alerts landed on the same calendar day (2025-09-05,
  2025-10-05, 2025-12-05, 2026-02-05, 2026-04-05, 2026-08-05). **Zero collateral
  across the rest of the database.**

The two clusters OVERVIEW names as genuine are protected, and by two different
existing discriminators — verified, not assumed:

- five ₹10,000 `indian clearing corp` on 5 Jun — **differing balances**
  (15661718 / 16661718 / 17661718). Two debits cannot leave the same balance.
- four ₹20,000 `science city-ii` on 17 Jul — **clock times in the body**
  (`20:23:35`, `20:22:38`, …), so `_selfIdentifying` fires.

Both survive unchanged because the fix keeps every existing discriminator and
only stops the *merchant* lane from lying.

---

## The fix

A **re-delivery** is recognised when every one of these holds:

1. same `amountPaise`, same `direction`, same `txnLocalDate`;
2. `accountLast4` agree **when both are present** (absent blocks nothing);
3. `refNumber` agree when both are present;
4. `balancePaise` agree when both are present;
5. neither body is self-identifying (clock time / 8+ digit run) — unchanged;
6. **both merchants non-empty and unequal, one's token set containing the
   other's** — two spellings of one payee;
7. **same issuing institution**, derived from the DLT sender header.

Clause 6 is the name join; clauses 1–5 and 7 are the independent evidence beside
it that TASK-42's lesson requires. Clause 7 is what keeps TASK-42's
counterexample safe: `google` (Axis) and `google asia pacific pte.ltd` (HDFC)
are token-subset-related and would satisfy clause 6, but they are two different
banks, so they can never be merged by this rule even if they ever fell on one
day at one amount.

**Counting.** The loser of a recognised pair is **marked, never deleted** — a
new in-memory `supersededBySmsId` on `ParsedTxn`, computed at read time by
`SmsLiveNormalizer`, not persisted and so needing no schema bump. `active` in
`SmsAnalysisSnapshot.reduce` excludes it, in the one place the working set is
defined (TASK-41's rule), so every read path added later inherits it.

**Naming.** Each suppressed row emits a `ForecastCoverageLine` with the existing
`CoverageReason.duplicateSuppressed`, whose doc comment already states this
contract: *"The amount is accounted for — by the winner — but it must still be
named, or a dropped duplicate is indistinguishable from money that vanished."*

**Winner.** Deterministic, reusing `collapseRedeliveries`'s existing sort:
earliest `(txnDate, smsId)`. For August that keeps `hdfc bank ltd`
(`provider:12552`).

**The two gates are deliberately *not* widened.** `_weakCollision` and
`_hasDistinguishingSignal` are left exactly as they are, and the new rule is
added beside them with stricter clauses. Relaxing the gates themselves would
have pulled the 66 existing collision sets into a changed code path for no
measured reason; a separate rule keeps the blast radius at the 6 pairs that were
measured. The gates remain an accurate description of *why nothing sees the pair
today* — that is the diagnosis, not the prescription.

---

## Known limits, recorded rather than left as a remainder

- **Three months still double-count**: 2025-11 (5th/6th), 2026-01 (5th/6th),
  2026-06 (5th/6th) — the mandate alert arrived a day after the debit alert, and
  clause 1 requires the same calendar day. These are historical months; they do
  not affect the current headline. Widening to ±1 day was **not** done: it is
  untested against the rest of the history and would weaken clause 1, which is
  doing most of the safety work.
- The 66 existing collision sets remain counted twice and flagged. That is
  today's behaviour and this task does not change it.

---

## Tests

RED symptoms recorded in **Status** below.

1. `normalizer marks one of two alerts for one ACH debit as superseded` — the
   device pair; exactly one marked, and it is `provider:12552`.
2. `differing balances keep both rows` — GUARD (`indian clearing corp` shape).
3. `a self-identifying body keeps both rows` — GUARD (`science city-ii` shape).
4. `two genuinely different payees are never merged` — GUARD.
5. `two spellings from different banks are never merged` — GUARD; TASK-42's
   Google counterexample, same day and amount, different institution.
6. `an absent account no longer blocks the match` — the gate-1 half alone.
7. `the working set counts one ACH debit once` — `SmsAnalysisSnapshot.reduce`.
8. `a suppressed re-delivery is named in the coverage lines` — reachability.

---

## Definition of done

- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — **952 passing, 0 failing** (939 before; 13 added).
- [x] Device: August reads `Required in bank ₹61,415`, one `hdfc bank ltd` driver
      row, 11 payments tracked, and a `duplicateSuppressed` line in the why-log.
- [x] Row counts reconciled before and after; nothing deleted from the database.

---

## Status — done, device-verified 2026-08-05

### REDs, each observed before the fix

Tests 1–8 were compile-blocked first (`supersededBySmsId`,
`markSupersededRedeliveries`, `supersededRedeliveries`,
`supersededCoverageLines` did not exist). Inert plumbing was added — the field
declared, the methods returning their input / `const []` — and the suite re-run
to capture behavioural REDs:

| Test | RED |
|---|---|
| marks exactly one alert as superseded | `Expected: length <1>` / `Actual: []` |
| the working set counts one ACH debit once | `Expected: length <1>` / `Actual: [ParsedTxn, ParsedTxn]` |
| normalize applies the suppression | `Expected: ['provider:12554']` / `Actual: []` |
| a suppressed re-delivery is named | `Expected: length <1>` / `Actual: []` |
| reaches a duplicateSuppressed coverage line | `Expected: length <1>` / `Actual: []` |

The seven **guards** passed against the inert stub and again after the fix, which
is what makes them guards rather than regression coverage. Two of them are worth
naming: the `indian clearing corp` shape is held apart by *differing balances*
and the `science city-ii` shape by *clock times in the body* — the fix keeps both
discriminators and only stops the merchant lane from lying. The TASK-42
counterexample guard (`google` vs `google asia pacific pte.ltd`, same day, same
amount) is held by the issuing-bank clause alone; without clause 7 it fails.

### Predicted offline, then measured on the device

The real `markSupersededRedeliveries` was run over all 2,064 exported device rows
before the build was installed. It suppressed **exactly 6 rows, ₹3,68,490 —
every one of them the HDFC EMI** — and predicted August at 11 rows /
₹1,14,878.97. The device then read exactly that:

| | before | after |
|---|---|---|
| Spent this month | ₹1,76,294 · 12 payments | **₹1,14,879 · 11 payments** |
| Driver rows | 12, incl. `hdfc bank ltd` **and** `hdfc ltd` | **11**, `hdfc ltd` gone |
| Required in bank / Your plan now | ₹1,22,830 | **₹61,415** |
| Lowest balance | ₹-22,830 on 5 Aug | — |
| Free | **₹-22,830** | **+₹38,585** |
| Need for September | ₹4,69,632 | ₹4,08,217 (−₹61,415) |
| Apr / Jun / Jul bars | ₹2.2L / ₹1.5L / ₹1.1L | ₹1.5L / ₹1.5L / ₹1.1L |

Jun and Jul are unchanged and that is the fix behaving: June's pair fell on the
5th and 6th, so clause 1 correctly declines it, and July had only one alert.
April moved because it is one of the six.

The coverage line renders in the why-log, reached from
"See why August requires ₹61,415":

> **hdfc ltd — second bank alert for one debit  ₹61,415**
> Counted once, under another name

The same screen shows `hdfc bank ltd · Due September · set aside ahead of time`
under **Coming up later**, which is independent confirmation of premise 3 above:
the obligation is a September row and was never part of August's number.

### Database

**Byte-identical before and after** (`cmp` clean). 2,064 rows, `MIN(id)` 19,
`MAX(id)` 2788, 1762 auto_added / 187 confirmed / 109 needs_review / 6 dismissed,
10 obligations, 3 forecast_risk_decisions, schema v5. The fix is entirely
read-time and persists nothing, so no rescan was needed and no row was touched.
All pulled copies and screenshots deleted, on-device screenshot removed.
