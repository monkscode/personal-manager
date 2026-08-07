# Fix Plan — SMS Actuals & Forecast Layer

Findings from a four-reviewer audit run on 2026-07-31 against the synced SMS/forecast
layer. **27 task files, ~85 findings.** Nothing from the audit was dropped.

**TASK-28 and TASK-29 were added later**, on 2026-08-02, from running the Phase-1 build
against a real device rather than from the audit. Both were invisible to code review:
each only became measurable once TASK-07 made HDFC's UPI alerts parse at all. Treat
"install it on the phone and look" as a required step at the end of each phase — it found
two Critical defects that four reviewers reading the source did not.

**TASK-31 and TASK-32 were added the same way**, at the end of Phase 2, by installing the
build and measuring the real database. The device keeps earning its place: 34% of all
transaction value is stored with no merchant (TASK-31), and future-tense bank notices are
booked as completed debits alongside the real debit (TASK-32) — a straight breach of "one
owner per rupee" that nobody reading the source had caught.

**TASK-33 was found while *verifying* TASK-31 on the device**, which is the point worth
keeping: the fix was correct and the on-device numbers still did not add up, and chasing
that 11-row gap surfaced a Critical silent exclusion in the reader. Do not stop at "the
tests pass and the number improved" — reconcile the device numbers exactly, and treat a
remainder you cannot explain as a finding rather than as noise. Fixing it took the stored
history from 387 rows starting in Nov 2025 to 2,058 rows starting in Oct 2018, so **every
measurement taken before 2026-08-03 was taken against half the analysis window**. Re-measure
rather than trusting a number quoted in an earlier task file.

**TASK-34 was found at the end of Phase 3**, by installing the build and going looking for
the coverage lines the phase had just added. They were all computed correctly and **not one
of them was reachable**: `_recommendationCard` is the only widget that renders any part of
`ForecastOutlook`, it holds the only route to the why-log, and it sits in the branch taken
when `forecastExplorer` is *null* — which never happens on the live SMS path. The
replacement, `HomeForecastExplorer`, is never instantiated anywhere in `lib/`. Three phases
of work have been feeding a channel with no outlet, and "no silent exclusion" has been
violated at the UI layer the whole time while every model-layer test passed. **Check that a
fix is reachable by a user, not merely correct** — a passing test that renders a screen
directly proves the screen works, not that anything can open it.

**TASK-34 was fixed on 2026-08-04 by wiring up `HomeForecastExplorer`**, and two of its own
premises did not survive: the headline and the provisional marker were already reaching the
user through `alerts.first.text`, which is rendered outside the branch. Writing the
"must fail now" test and watching it *pass* is what caught it — the same discipline that
found the real defect. The choice of surface was decided by one fact rather than taste:
coverage lines are computed per horizon month, but `Insights.coverageLines` carries the
target month's alone, so only a per-month surface can name an omission in month 7. On the
device, September's why-log now shows a ₹3,09,274 omission and a ₹61,415 duplicate
suppression that the recommendation card could never have displayed. Making the surface
reachable immediately exposed four further defects nobody could see before — recorded at
the end of TASK-34.

**A task file's own premises are evidence, not fact.** TASK-31, TASK-32 and TASK-33 each
turned out to contain a premise that did not survive being checked against the source or
the device — including, in TASK-33, all three of the mechanism, the trigger and the measured
severity, while its headline defect was entirely real. Each file records the corrections
inline. Check the quoted code before building on it.

Each task file is self-contained: it states the defect, a concrete failing scenario,
the required fix, the tests to write, and a definition of done. One agent should be
able to complete one file inside a single context window.

---

## How to work a task

1. Read the task file end to end before touching code.
2. **Write the failing test first.** Every task lists the tests to add. Confirm the
   test fails for the stated reason, then make it pass.
3. Run the gate before claiming done:
   ```bash
   flutter analyze          # must report "No issues found!"
   flutter test             # must be 590+ passing, 0 failing
   ```
4. Tick the checkboxes in the task file and commit. One commit per task file,
   imperative subject line, no AI-attribution trailers.

**Line numbers in these files are as of the commit that introduced them.** They will
drift as fixes land. Always grep for the quoted code rather than trusting the line
number.

**Money is integer paise everywhere.** No `double` may touch a monetary value. If a
fix needs arithmetic, use `int` and `~/`.

---

## Ordering

Tasks within a phase are independent and can be worked in any order or in parallel.
**Do not start a phase until the one above it is merged** — later phases assume the
earlier fixes exist.

### Phase 0 — Data loss and privacy (do first)

| Task | Title | Severity |
|---|---|---|
| [TASK-01](TASK-01-date-overflow-clamp.md) | Month-end date overflow drops salary and bills | Critical ×4 |
| [TASK-02](TASK-02-obligation-upsert-data-loss.md) | Every scan destroys the user's obligation decisions | Critical |
| [TASK-03](TASK-03-db-downgrade-brick.md) | A version rollback permanently bricks the database | Critical |
| [TASK-04](TASK-04-redaction-leak.md) | Card tails and balances stored in plaintext | Critical |

### Phase 1 — Parser correctness

| Task | Title | Severity |
|---|---|---|
| [TASK-05](TASK-05-promo-and-failed-txn-autoadd.md) | Marketing SMS auto-added as ₹5,00,000 income | Critical |
| [TASK-06](TASK-06-direction-inference.md) | Loan EMI booked as income; cashback booked as spend | Critical |
| [TASK-07](TASK-07-missing-sms-formats.md) | HDFC and SBI UPI alerts parse to nothing | Critical |
| [TASK-08](TASK-08-merchant-instrument-axis.md) | Greedy merchant capture, card-as-bank, Axis stuck in review | Important ×3 |
| [TASK-09](TASK-09-normalizer-and-collisions.md) | Genuine duplicates silently dropped; collision sets fracture | Important ×2 |
| [TASK-10](TASK-10-dead-patterns-and-paytm.md) | Dead bank-pattern module; Paytm QR misclassified | Important ×2 |
| [TASK-11](TASK-11-parser-minors.md) | Parser minors (8 items) | Minor |
| [TASK-29](TASK-29-hdfc-upi-payee-no-merchant.md) | HDFC `Sent … To <PAYEE>` yields no merchant; 171/173 rows ownerless | Critical |
| [TASK-30](TASK-30-reparse-stored-rows.md) | A parser fix never reaches already-stored rows (210 of 383 stale) | Critical |
| [TASK-31](TASK-31-ownerless-merchant-formats.md) | ACH/NACH/Axis/ATM payees unread — 79 rows, 34% of value, ownerless | Important |
| [TASK-32](TASK-32-mandate-prenotification-double-count.md) | Future-tense notices stored as completed debits (30 rows, ₹86,304) | Critical |
| [TASK-33](TASK-33-scan-reads-only-newest-1000-sms.md) | A scan reads only the newest 1,000 SMS and reports success | Critical |

### Phase 2 — Reconciliation

| Task | Title | Severity |
|---|---|---|
| [TASK-12](TASK-12-neft-double-count.md) | NEFT/IMPS bill payment counted twice | Critical |
| [TASK-13](TASK-13-card-cycle-payments.md) | Second card payment in a cycle vanishes | Critical |
| [TASK-14](TASK-14-matchkey-and-conservation.md) | Amount-blind match key deletes obligations + rupee-conservation test | Critical |
| [TASK-15](TASK-15-transfer-bridge-wiring.md) | TransferBridgeMatcher is never called | Important ×2 |
| [TASK-16](TASK-16-seasonal-mtd-netting.md) | Month-to-date discretionary spend double-counted | Critical |
| [TASK-17](TASK-17-refund-cap-and-fold-order.md) | Refund over-credit; order-dependent fold | Important ×2 |
| [TASK-18](TASK-18-algorithmdetected-and-nextexpected.md) | Algorithm guesses marked user-confirmed; due dates in the past | Important ×2 |
| [TASK-19](TASK-19-salary-detection.md) | Salary day-drift, payer consistency, cadence truncation | Important ×3 |
| [TASK-20](TASK-20-reconciliation-minors.md) | Reconciliation minors (10 items) | Minor |
| [TASK-28](TASK-28-card-payment-booked-as-income.md) | Card bill payment treated as a refund, cancelling card spend (₹1.16L measured) | Important |

### Phase 3 — Forecast and money

| Task | Title | Severity |
|---|---|---|
| [TASK-21](TASK-21-horizon-discretionary-gap.md) | 11 of 12 forecast months have no discretionary spend | Critical |
| [TASK-22](TASK-22-anchor-integrity.md) | Float-parsed balance; phantom ₹0 anchor at 0.9 confidence | Important ×2 |
| [TASK-23](TASK-23-horizon-dedupe-and-buffer.md) | Label-only future dedupe; unreachable buffer headline | Important ×2 |
| [TASK-24](TASK-24-forecast-minors.md) | Forecast and money minors (11 items) | Minor |
| [TASK-34](TASK-34-forecast-surface-unreachable.md) | The whole forecast surface is unreachable on the live SMS path | Critical |

### Phase 4 — Persistence hardening

| Task | Title | Severity |
|---|---|---|
| [TASK-25](TASK-25-schema-drift.md) | Fresh-create and migrated schemas differ | Important ×3 |
| [TASK-26](TASK-26-ingest-and-indexes.md) | REPLACE resets `created_at`; missing indexes; fake scan test | Important ×3 |
| [TASK-27](TASK-27-persistence-minors.md) | Persistence minors (7 items) | Minor |

**Phase 4 closed 2026-08-04.** Its recurring lesson is narrower than Phase 3's and worth
carrying: **a task file's prescribed fix can carry the same defect the task is about.**
TASK-26 told the next agent that TASK-25's index convergence made a version bump
unnecessary — but `onUpgrade` fires only when the stored version changes, so following it
would have shipped an index that reached fresh installs only, which is exactly the drift
TASK-25 exists to prevent, on the device that motivated the work. Its prescribed
`EXPLAIN QUERY PLAN` assertion (`contains('USING INDEX')`) would likewise have passed
before the fix on both queries, because a full scan *through* an index still says
"USING INDEX" — the fake-test defect reproduced inside its own remedy. Run the prescribed
assertion against the unfixed code and watch it fail before trusting it.

The schema version is now **4**. Every future index needs both an `indexStatements` entry
and a version bump; a test now asserts `schemaVersion` is at least the highest registered
migration, which is the direction nothing covered.

### Phase 5 — What the reachable surface exposed

Opened 2026-08-04 from the four findings recorded at the end of TASK-34. None of these was
visible until the forecast surface rendered, which is the standing argument for device
verification at the end of every phase.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-35](TASK-35-risk-buffer-sums-inflows.md) | "Unconfirmed risk" totals an uncertain salary as money going out | Critical | **Done** |
| [TASK-36](TASK-36-opaque-handle-as-merchant.md) | A UPI handle's local part is stored as the merchant name | Important | **Done** |
| [TASK-37](TASK-37-stale-and-duplicate-obligations.md) | One commitment, three stored obligations | Critical | **Done** (stale half) |
| [TASK-38](TASK-38-forecast-surface-cleanups.md) | Forecast-surface cleanups | Minor | **Done** |
| [TASK-39](TASK-39-untidied-fallback-payee.md) | The `at`/`to` merchant fallbacks never tidied what they captured | Important | **Done** |

**Phase 5's lesson is about measurement, not code: a number is only evidence once you know
which collection it came from.** TASK-37's first reproduction counted
`outlook.months[].events` and reported `0` where it expected `199900`. That list holds
**hard events only** — a `needs_review` obligation at 0.7 confidence is partitioned into
`riskLines` and never appears there. The defect is only visible across *both* partitions,
because the user sees both. The error surfaced because a **guard** was written alongside
the headline assertion: one obligation in, one line out. Without it the headline would have
read 3-vs-3 and "passed" for entirely the wrong reason. Write the guard that proves the
fixture, not only the assertion that proves the fix.

TASK-34's own record of finding 2 was wrong on both counts and is corrected in TASK-36:
the opaque strings are **not** internally generated and **are** in TASK-33's
merchant-capture family. They are the local part of a real UPI VPA the bank put in the SMS,
and the parser reached for them only because a 40-character cap stopped `towards <PAYEE>`
from matching a 45-character payee name.

**The schema version is now 5.** `retired_at` on obligations, verified migrating on the
device against 2,061 real rows with all 187 confirmed decisions intact. `refuseDowngrade`
means a build older than this branch will now refuse to open that database — intended
(TASK-03), not a regression.

**What is still open, and neither item is a defect to go fix:**

1. **TASK-37 fixed the stale half only.** `sms_mandate:google` and
   `sms_mandate:google asia pacific pte.ltd` are both live and both re-derivable, so both
   survive retirement: the ₹1,999 triple becomes a *double*. Merging them needs
   merchant-identity resolution — the same unsolved problem as `hdfc ltd` / `hdfc bank ltd`
   and `Bharat Connec`. That is the natural Phase 6.
2. **The sweep has now run on the device** (2026-08-04, user-triggered pull-to-refresh).
   All three triggers fired; 2,061 rows and all 187 confirmed decisions survived; live
   obligations went 9 → 7. It did **not** collapse either duplicate: a new pair replaced
   the old one (`sms_mandate:phonepe` beside the corrected
   `sms_recurring:bharat connect postpaid bill payment:monthly`, same amount *and* same due
   day). Measured, not assumed — see TASK-37.
3. **A reparse cannot un-book a stored notice.** 7 rows worth ₹1,001.77 still hold a UMN as
   their merchant. The current parser returns *no transaction* for those bodies, but a
   reparse only ever rewrites a stored row — it cannot retire one. TASK-32's defect
   therefore persists in data written before that fix, and rescanning will never clear it.
   New, measured, unfixed.

   **Superseded by TASK-41, and re-measured 2026-08-05.** All 7 bodies are
   `[amount] will be deducted on …`, so `isFutureDebitNotice` matches them and `active`
   drops them: they are still on disk but no longer counted. What survives is narrower
   than recorded here — the rows hold a real UMN in `merchant` while the body redacts it
   as `[vpa]`, which is a redaction question (TASK-04's family), not a counting one.

**Phase 5 was device-verified on 2026-08-04** and the database reconciled byte-identical
before and after — install and navigation only, no scan, no destructive control tapped.
TASK-35 confirmed on real data (August's "Unconfirmed risk" ₹2,73,425 → ₹1,21,640, salary
gone from the total), and TASK-37's double count confirmed rendered: `phonepe ₹120` and
`ece9ae70… ₹120` both dated 29 Aug, plus three separate ₹1,999 Google lines.

**And the install found a defect again — the fourth phase running.** A "Drivers" row read
`autopay  bharat connec`, which traced to `_merchant`'s `at`/`to` fallbacks doing a bare
`.trim()` where `_namedPayee` runs every capture through `_tidyPayee`. That is
[TASK-39](TASK-39-untidied-fallback-payee.md), and it mattered beyond the scruffy label: it
was minting a *fourth* stored spelling of one commitment, and `merchantNorm` is what the
obligation dedupe key is built from — TASK-37's double count fed from upstream.

### Phase 6 — Reversibility and identity

Opened 2026-08-05 from the four items carried out of Phase 5.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-40](TASK-40-risk-decision-one-way-door.md) | A confirmed or dismissed risk decision cannot be undone | Critical | **Done** |
| [TASK-41](TASK-41-notice-leak-into-working-set.md) | A future-debit notice reaches every read path added after TASK-32 | Critical | **Done** |
| [TASK-42](TASK-42-mandate-owned-by-announced-debit.md) | A mandate notice and the commitment it announces are two owners for one rupee | Important | **Done** |
| [TASK-43](TASK-43-one-debit-two-bank-alerts.md) | One ACH debit, two bank alerts, counted twice (₹61,415) | Critical | **Done** |

**TASK-41 came from the user, not from the plan** — *"two entries for ₹118 on 3 Aug, I only
spent it once; it wasn't showing two days ago."* Both halves were exact, and the second half
is what identified the mechanism: the notice row was stored 2 Aug 12:41, TASK-32 fixed the
parser 3 Aug 13:55, and the real debit landed 3 Aug 14:35. **A user's timeline is evidence —
"it changed on this day" narrows the cause faster than reading the source does.**

Its lesson is the sharpest one in the plan so far, because the defect was *inside the
previous fix*: TASK-32 built the right read-time check, `isFutureDebitNotice`, and applied it
at **four leaf consumers** instead of at `active`, the one place `SmsAnalysisSnapshot.reduce`
defines the working set. Every path added later — `currentMonthTxns` → reconciliation →
forecast events → the Drivers list, and `allTxns` → the transaction list — re-admitted the
phantom. TASK-32's own doc comment complains that the notice vocabulary "previously existed
twice … which is why the estimator and the recurring detector never saw the exclusion at
all", and the remedy then reproduced that shape one layer up. **A predicate applied at call
sites is not a rule; only one applied where the set is defined is.**

The measured signature was the app disagreeing with itself: August's Drivers summed to
₹50,734 across 10 rows while "Spent this month" read ₹50,616 — exactly ₹118 apart, because
`_isConsumptionSpend` applied the check and reconciliation did not. After the fix the device
reads 11 payments tracked against 11 driver rows.

Scope, measured rather than assumed: **32 rows / ₹86,734 leave the working set**, only 8 of
which carry the `E-Mandate!` prefix that prompted the report — the rest are Axis
`upcoming mandate set for …` and card-bill reminders, which is why it had to be fixed by the
pattern and not by the format. 30 of the 32 have a real-debit partner within ±7 days; the
two that do not are named in the task file rather than left as a remainder. **28
user-confirmed rows disappear from the transaction list** — intended, since the user was
looking at a list when they counted the duplicate.

Deliberately untouched: the same-day same-amount clusters that are not notices (five ₹10,000
`indian clearing corp` on 5 Jun, four ₹20,000 `science city-ii` on 17 Jul). TASK-24 M5
established those can be genuine, and **no two rows in the database share an `sms_id`**, so
there is no evidence of a true duplicate. Shared `body_hash` is expected — that is what
collision sets are for (TASK-09).

**Correction to the device notes below: a cold start DOES run a scan.** TASK-41's
verification wrote two rows with no pull-to-refresh; the only difference from the previous
session was `am force-stop` before `am start`. Capture counts before and after any launch.

> **This correction is itself wrong — disproven 2026-08-06 in TASK-46.** `am force-stop` +
> `am start` was run and the database was untouched after two minutes of polling. The
> **only** scan trigger in the app is pull-to-refresh: `home_screen.dart:43` and `:347`
> both call `_refreshFromSms`, the sole caller of `ScanController.scan()`, the sole scan
> entry point. TASK-41 saw two rows appear and attributed them to the launch. **A database
> unchanged after a cold start is not evidence that a change writes nothing** — pull to
> refresh, then compare.

**TASK-40's premises all survived contact with the source and the device** — the first task
file in six phases where that is true, and worth recording precisely because the standing
lesson is the opposite. Both doors were exactly as described: `dismissed` hits a `continue`
before any collection, and `confirmed` lands in `hardLines`, which render through
`_rankedDrivers` as a label and an amount with no callbacks at all.

The mechanism is a new `ForecastDecidedLine` collection carried on `ForecastOutlook` and
`ForecastMonthPlan`. Reversal writes `ForecastRiskDecisionStatus.pending` rather than
deleting the row — verified against all three consumers to be exactly equivalent to never
having decided (`_isHard` tests only for `confirmed`; `_applyOverride` returns the event
untouched for any other status; the dismissal `continue` stops firing). Retire, never
delete — the same rule TASK-37 established for obligations.

**Two things worth carrying forward.**

1. **Match on `ownerKey`, never on a flag stamped onto the line.**
   `_hardLinesForMonth` substitutes a matching *reconciliation* line for the event-derived
   one whenever amount and date agree — and a plain `Confirm` passes the line's own amount
   and date as the override, so that substitution is the common case, not the edge. A flag
   would have been silently dropped on exactly the rows that needed it, and every unit test
   would still have passed.
2. **A widget test that asserts an absence must scroll the section into view first.** The
   `no Undo without a decision` guard initially "failed" for the wrong reason — the row was
   never built, because the `ListView` is lazy and the Drivers section sits below the fold.
   An unscrolled `findsNothing` passes whatever the code does.

Device-verified 2026-08-05, byte-identical database before and after. September shows
exactly two `Undo` controls, both rendering the stored override; the third decision — whose
obligation TASK-37 retired — correctly produces no row. The dismissed-restore path is
test-verified only: this database holds no dismissal to render.

**TASK-42 corrected the plan's own idea of what was left.** Phase 5 and the Phase-6 handoff
both recorded the remaining duplicates as *merchant identity resolution* — "the join must
come from the name", starting with the PhonePe pair, blocked by every obligation carrying
`category_key = 'other'`. All three parts of that were wrong, and acting on it would have
destroyed a real commitment:

- The category blocker names `_commitmentSuppression`, which joins a *commitment* to a
  projected obligation. Both members of each device pair are rows in the `obligations`
  table, and **nothing joins obligation to obligation** — the horizon dedupes on
  `dedupeKey + month`, the matcher emits one owner per row. The degeneracy is real and
  unreachable from these rows.
- **`phonepe` and `bharat connect postpaid bill payment` share no token.** They are one Axis
  autopay: the notice says "towards PhonePe", the debit says "AutoPay Bharat Connect
  PostPaid Bill Payment". No string method joins them.
- **`google` and `google asia pacific pte.ltd` are two different subscriptions** — Axis on
  the 28th, HDFC on the 11th, each with its own real debit series — and are *more* alike as
  strings than the real duplicate. Name similarity gets the true duplicate wrong and merges
  the two genuine commitments.

So the join is what a notice **announces**: same due day, amount within the recurring jitter.
`MandateOwnership` holds that rule and both the notice-write loop and the retirement sweep
ask it.

**Its lesson is that a green suite is not a verified fix.** Part 1 passed every test and
changed nothing on the phone — the stored mandate held day 30 from a December notice while
the commitment sat on day 29, because `sms_mandate:` is keyed on the payee alone and
`_merge` takes the incoming date unconditionally, so the row held whichever notice was read
last. Fixing that (newest notice wins) then exposed a third defect the same way: retiring a
payee because one of its notices is owned took a *different* debit with it — Axis announces
both a ₹120.07 postpaid bill and a ₹310 gas bill as "towards PhonePe". A payee is redundant
only when **every** notice for it is owned. Two of the three parts exist because the build
was installed and the database read, not because anything was reasoned out.

**Still open:** the 7 rows worth ₹1,001.77 holding a UMN as their merchant, which a reparse
cannot retire; and `sms_mandate:<payee>` still cannot represent two concurrent mandates for
one payee (keying by payee *and* day-of-month is the obvious next move, complicated by the
day drifting 29/30). Item 4 is **narrowed, not closed**: two of the three stuck decisions are
now user-clearable, the third is inert.

**TASK-43 corrected the plan's stated next task for the second phase running, and the
correction came from reading the database rather than the source.** The handoff described
August's two ₹61,415 rows as an obligation and the actual that paid it, failing to fold on a
merchant-string comparison. All three parts were wrong:

- **Both rows are actual debits** — two SMS for one HDFC ACH mandate execution, the
  account-debit alert (`UPDATE: … ACH D- HDFC BANK LTD-…`, payee `hdfc bank ltd`) and the
  mandate confirmation (`PAYMENT ALERT! … towards HDFC LTD UMRN: …`, payee `hdfc ltd`).
  Both past tense, so TASK-41's notice filter correctly leaves both alone. It reconciles
  exactly: 13 August debit rows − the ₹118 notice = 12 rows summing ₹1,76,293.97, against
  "₹1,76,294 · 12 payments tracked" and 12 driver rows. **Every driver row was an actual.**
- **`_obligationMatchKey` is not the gate.** It feeds `distinctKeys`, which decides whether
  several already-matched owners are one obligation. Reaching an owner at all is `_matches`.
- **`_matches` never reaches the merchant comparison here.** `_withinWindow` is a same-*month*
  test, not a day window, and that obligation's stored `due_date` is **2026-09-05** —
  confirmed on the device, which files it under "Coming up later · Due September". It was
  never part of August's number.

**The lesson is that the shape of a defect is a measurement, not a reading.** Two prior
sessions recorded this as obligation-vs-actual identity resolution; one query against
`transactions` settled it in a minute. Count the rows the surface claims to be showing —
"12 payments tracked" beside 12 driver rows is what proved no obligation was present.

The fix is a re-delivery rule beside the existing collision gates, not a widening of them:
same amount, direction and day; account, reference and balance agreeing *when both are
present*; neither body self-identifying; **same issuing bank**; and the payees two spellings
of one name. The name join is the last clause, with six independent agreements in front of
it — TASK-42's rule that a name join needs evidence beside it. Clause 7 is what keeps
TASK-42's own counterexample safe: `google` and `google asia pacific pte.ltd` are
token-subset related and genuinely different, but they are billed by different banks, and two
alerts about one event come from one bank.

**Predicting the sweep offline before installing is what made the change safe to ship.** The
real rule was run over all 2,064 exported rows first: **exactly 6 suppressions, every one the
HDFC EMI**, zero collateral. The two clusters this plan records as genuine are held apart by
discriminators that already existed and were verified rather than assumed — the five ₹10,000
`indian clearing corp` by *differing balances* (two debits cannot leave the same balance), the
four ₹20,000 `science city-ii` by *clock times in the body*. The 66 pre-existing collision
sets are untouched.

**Retire, never delete — now at the row level too.** The loser is marked with an in-memory
`ParsedTxn.supersededBySmsId`, computed at read time and never persisted (no schema bump), and
excluded at `active` in `SmsAnalysisSnapshot.reduce` — the one place the working set is
defined, per TASK-41. A `CoverageReason.duplicateSuppressed` line names it in the why-log,
which is what keeps a suppressed duplicate from looking like money that vanished. Device:
`Free` moved from **₹-22,830 to +₹38,585**, 12 payments to 11, and the database was
**byte-identical before and after** — the fix writes nothing.

**Still open after TASK-43:** three months (2025-11, 2026-01, 2026-06) still double-count the
EMI, because the mandate alert arrived a day after the debit alert and the rule requires the
same calendar day. Historical only; it does not affect the current headline. Widening to
±1 day was deliberately **not** done — same-day is doing most of the safety work, and a
wider window is unmeasured.

**Measured, then fixed — kept for the correction it carries.** The ₹61,415 HDFC EMI landed
mid-session and August's Drivers showed `hdfc bank ltd ₹61,415` beside `hdfc ltd ₹61,415`,
putting "Required in bank" ₹61,415 too high. **The mechanism recorded here was wrong in all
three of its parts and is corrected in
[TASK-43](TASK-43-one-debit-two-bank-alerts.md)**, which then fixed it. Both rows are
*actual debits*; neither is the obligation; `_obligationMatchKey` is not the gate; and
`_matches` never reaches the merchant comparison for this pair at all.

### Phase 7 — What an announcement is

Opened 2026-08-05 by reading the device database after Phase 6 closed, rather than from the
task the plan named next.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-44](TASK-44-announcement-booked-as-money.md) | Two bank announcements are still booked as real money (10 rows, ₹2,26,911.10) | Critical | **Done** |
| [TASK-45](TASK-45-payee-capture-boundary.md) | A payee capture has terminators but no idea what a payee is (348 rows) | Important | **Done** |

**The plan's stated next task was wrong for the third phase running, and once again the
correction came from a query rather than from reading the source.** TASK-42 handed off
"`sms_mandate:<payee>` cannot represent two concurrent mandates for one payee" as the obvious
next move. It is real, but **latent on this device**: the only payee with two mandates is
`phonepe`, and TASK-42's own fix already separates them, so nothing is being lost today. It
stays open as a latent item rather than a defect to go fix.

What was *not* latent sat beside it. `kFutureDebitNoticePattern` is the single source of
truth for "this is an announcement, not money that moved", and two of the author's banks
announce in words it did not contain:

- **ICICI standing instruction** — `… towards Merchant Amazon **to be debited** from ICICI
  Bank Credit Card …`. 8 rows, ₹4,081.10, every one stored as a completed debit. Four are
  followed by the real card debit two to three days later (double-counted ₹2,639.00); four
  have no partner at all (phantom ₹1,442.10). Four of the eight are user-confirmed.
- **HDFC NACH mandate registration** — `Auto Pay (HDFC Bank NACH Mandate): … Freq MNTH
  **received today for processing**.` 2 rows, ₹2,22,830, booked as **credits**, because
  `received` reads as an inflow. Nothing moved; the amount is the mandate *ceiling*, and
  ₹1,22,830 is exactly 2 × the ₹61,415 EMI TASK-43 spent its length on. This was phantom
  income feeding the baselines that salary and inflow estimates are learned from.

**Its lesson is that TASK-41's rule can be in the right place and still never fire.** The
predicate already sits at `active`, where the working set is defined, so every read path
inherits it — that half has been right since TASK-41. The rule simply did not know the words.
**A rule in the right place is only as good as the vocabulary it consults**, and a vocabulary
is the one part of a rule that no amount of reading the control flow will audit: you have to
go and look at what the banks actually wrote. Ten further future-tense phrasings were swept
and matched nothing, which is the evidence that the two added are the whole of it *on this
inbox* — not that the vocabulary is now complete.

Two entries in one regex, and nothing else. Because `isFutureDebitNotice` re-derives from the
stored redacted body at read time, the 10 rows already on disk stopped counting the moment
the pattern learned the words — no migration, no schema bump, no row deleted, and the four
user-confirmed rows keep their confirmation.

Predicted offline before installing, per TASK-43's precedent: over all 2,065 exported rows the
widened pattern excluded **exactly 10 rows / ₹2,26,911.10**, and the 32 rows / ₹86,734.29
TASK-41 already excludes reconciled unchanged.

**Still open, and none of it is a defect to go fix today:**

1. **The mandate key**, carried forward from TASK-42 and now measured as latent (above).
2. **214 counted rows, ₹43,72,805.95, carry no merchant at all**, and 132 more carry the
   `card purchase` placeholder although their bodies name the payee outright
   (`… on AMAZON PAY IN G`). Same family as TASK-31/36/39. It is an identity and labelling
   problem, not a counting one — every one of those rupees still has exactly one owner.
3. **Five of the seven live obligations carry a due date in the past**, one from
   2024-12-02. All are `onetime` mandate rows, which `_obligationHitsMonth` never projects
   forward, and they surface as reviewable `pastDueObligation` coverage lines — the designed
   behaviour, not a silent exclusion. Nothing refreshes or retires them once their notice
   ages out of the inbox.
4. **A redaction placeholder is reaching the user as a payee name.** The install for
   TASK-44 rendered the 5 Aug ICICI card purchase as **`[number]`** in the transaction
   list, where the stored `merchant` is `card purchase`. Recorded as an observed symptom
   with **no diagnosed mechanism** — the suspect is TASK-30's reparse re-running the parser
   over `raw_body_redacted`, whose tokens stand where the digits were, but that was not
   confirmed and must be checked before anything is built on it. This is the fifth phase
   running in which installing the build found something reading the source did not.

   **Checked, and the suspect was wrong — see [TASK-45](TASK-45-payee-capture-boundary.md).**
   The reparse is not involved and no stored row is wrong for this symptom: the name is
   computed at render time, and `MerchantDisplay` consults a body-derived merchant *before*
   the stored column, so `card purchase` never had to be wrong. Gating the item on a check
   is what stopped a plausible mechanism being built on.

**TASK-45's lesson is that a capture can stop in exactly the right place and still not be a
payee.** Every terminator in the parser was firing correctly. What was missing was any
notion of what a payee *is*, so the captures returned the dispute footer, the user's own
credit card, and a rail reference — and `_tidyPayee`, the one place a captured string
*becomes* a payee, asked only whether it was entirely digits.

Checking the fallback is what turned a labelling defect into a privacy one. Refusing a
body-derived name falls through to the stored `merchant`, and that column holds what the
redactor removed from the body: on one row `raw_body_redacted` reads `Credit Card [account]`
while `merchant` reads `…credit card xx7117`. **236 rows carry a non-public identifier that
way.** TASK-04 applied the floor to bodies; nobody classified a derived column as a body.

It also corrected its own first measurement, which is worth carrying: the first pass counted
**393** rows, but **157 of those held nothing but a public bank helpline** (`18605005555`).
**Strip the known-public values before counting a leak** — otherwise the severity is inflated
by two thirds.

And the offline prediction earned its place twice, catching two defects no amount of reading
would have: a blunt `\d{4,}` mangled the real UPI handle `samplepayee1910`, and collapsing
separators inside the new shared rule broke `MerchantDisplay`'s existing `RAZ*` prefix strip.
**A shared rule must not do a job its callers are still doing.**

### Phase 8 — What the floor covers

Opened 2026-08-05 from TASK-45's still-open items 1 and 2.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-46](TASK-46-derived-column-redaction-floor.md) | The redaction floor was applied to one column and classified nothing else | Important | **Done** |

**The plan's stated next task was wrong for the fourth phase running, and this time the
correction was that the work had already happened.** TASK-45 handed off 236 rows whose
stored `merchant` carried a non-public identifier. Measured against the device before
building anything: **3**. A scan had run since — 17 batches — and TASK-30's reparse rewrote
the stored merchants through the fixed parser. The 180 dispute-footer merchants TASK-45
counted are all gone. **Check what the data looks like now before building the thing that
fixes it**; a planned backfill can be overtaken by a mechanism that already exists. The
schema-v6 migration this task was designed around was dropped on that evidence, and the
schema stays at **5**.

What was real was the mechanism rather than the count. Two of the three survivors store the
bare mobile number `9999999999` and both carry `upi_vpa_norm = 9999999999@axl` — **a live
defect, reproducible today**. `_merchant`'s VPA branch returned `upiVpa.split('@').first`
with no tidying: TASK-45 routed *five* parser captures through `PayeeText.sanitize` and this
was the sixth.

**Its lesson is TASK-41's, repeating inside TASK-45's own remedy** — *a predicate applied at
call sites is not a rule; only one applied where the set is defined is.* Five out of six is
what a convention gets you, and every test still passed. The rule now lives in
`TransactionRepository._toRow`, the one place a merchant becomes a stored value, so the
guarantee no longer depends on having found every path. It stayed invisible because
`MerchantDisplay._isOpaque` matches `^\d{6,}$`, so a 10-digit merchant renders as something
readable — **stored dirty, displayed clean**, the same shape TASK-45 found.

`SmsPrivacy` now carries a register: every stored column is floored, identifier-free, or a
**declared exception naming the feature that breaks without it** — `account_last4`
(TASK-13), `ref_number` (TASK-43), `balance_paise` (TASK-22), `upi_vpa_norm` (the
self-transfer allow-list). They hold identifying material on purpose, and saying so is what
stops the next one slipping through unexamined.

Two honest limits, neither a defect to go fix: nulling `merchant` on the VPA rows is a
**labelling** win, not a privacy one — `upi_vpa_norm` still holds the same digits by
design; and the identifier rule covers standalone digit runs and masked tails but not a
rail reference embedded in a path (`neft/mb/axmb000000000000/payee name/state`). Widening it
is how TASK-45's offline pass caught a real regression, so it gets its own task.

Obligations were **measured, not rewritten**: zero of the 7 live rows carry a digit run or
a VPA, so the `dedupe_key` hazard TASK-37 and TASK-42 both paid for never had to be taken.

**Device-verified 2026-08-06.** The scan changed **exactly two rows and nothing else**:
both `9999999999` merchants to NULL, with all 187 confirmed decisions, all 6 dismissals,
the row count, the obligations and `SUM(amount_paise)` byte-for-byte identical, and no
`created_at` restamped. The confirmed row stayed confirmed — a reparse rewrote a derived
column without touching the user's decision, which is TASK-02's whole subject. Searching
the full history for `9999999999` returns "No matching transactions".

**And the install disproved this file's own cold-start correction** — see the callout in
Phase 6. Cold-starting does not scan; only pull-to-refresh does. Five rows from 2020–21
(`mob/ccpmt/…`, two `cash-atm/…`, two `neft/mb/…`) keep their references because a boundary
rule only cleans what something rewrites and their SMS have aged out of the inbox. **That
is the migration-versus-boundary difference showing up exactly where it should**, and if
those five ever need cleaning it is an argument from five rows, not from TASK-45's 236.

### Phase 9 — What a card is actually going to bill you for

Opened 2026-08-07 from Spec A Part 2, which made a card's tail readable and in doing so
split the shared `unknown` card bucket into one bucket per tail.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-47](TASK-47-card-bill-for-money-already-gone.md) | A card is billed for money that already left the bank (29 rows, ₹3,60,235) | Critical | **Done** |

**Two of the buckets Part 2 opened are not credit cards**, and each got a line in "Needs
your attention" claiming a bill that will never arrive: card 7102 at ₹3,56,000 (23 HDFC ATM
cash-outs) and card 7113 at ₹4,235 (6 settled debit-card purchases). That is **₹3,60,235 of
the ₹3,60,825 the section named**; only card 7117's ₹590 was real. Both spec invariants
broke on the same 29 rows — 7113's six were already inside `isSpend`, so its line was a
second claim on the same rupees, and 7102's ₹3,56,000 was in no total at all.

**The estimator already had a guard, and the guard could not fire.** `t.type != TxnType.atm`
matched **zero** rows out of 2,071, because every card row was typed `pos` — HDFC words a
withdrawal as *"Withdrawn … From HDFC Bank Card …"* and never says ATM, so `_type` fell
through to `instrument == card -> pos`. **A guard in the right place consulting a field that
never disagrees with itself is not a guard**, and every test passed for as long as it sat
there. The fix is both halves: `MoneyLens.reportsBankBalance` keys the estimator on the
reported balance (a credit-card alert reports the available *limit*, a bank debit-card alert
reports the available *balance*), and `_atmWord` widens so the parser types the cash-out as
cash. After the device refresh the dead guard matches 23 rows — the two halves now guard the
same rows from opposite sides, and neither is removable.

**The rejected alternative is the lesson.** Keeping only buckets that carry credit-card
evidence looked right at one date and, with the data unchanged one month on, also dropped
genuine cards 7114 and 7105 — each carried exactly one evidence row and the 13-month lookback
slides past it. **A card's identity must not depend on the calendar**, so the prediction is
pinned at *two clocks* and that is part of the gate.

**Device-verified 2026-08-07.** `adb install -r` wrote nothing; only pull-to-refresh did — the
Phase 6 correction holding for the second task running. The scan changed **exactly 23 rows and
nothing else** (`type = atm` 34 → 57), and downstream `CashCoverageLevel` moved `none` →
`caveat` with the trailing-90-day ATM total ₹0 → ₹1,00,000, while card lines held at ₹590 and
commitments at 2. **The simulation was right on every outcome and wrong on the magnitude** —
it predicted a 15.7% cash-drain ratio against an observed 17.9%, having used a larger
denominator than the shipped predicate produces. Say which numbers were observed.

Two things closed quietly: 17 `science city-ii` rows (an ATM location stored as a payee) are
now typed `atm`, so `RecurringDebitDetector` skips them and the phantom-commitment risk is
gone; and Home is unchanged, as it must be, because those rows were already out of spend via
`kCashWithdrawalMarkers`.

**The honest successor is that ₹3,56,000 of cash still has no owner.** The parser fix makes
the coverage metric *see* it but does not itemise it — reconciliation reads the current month
only and the last withdrawal was 2026-07-17, so ATM items stayed 0 → 0.
**Measured in TASK-48 and closed: this is correct behaviour, not a successor defect.**

---

### Phase 9 — a card's announcements are not its transactions

Opened 2026-08-07, after TASK-47, from the observation that the spend lens reads everything
a card sends as something a card *did*.

| Task | Title | Severity | State |
|---|---|---|---|
| [TASK-48](TASK-48-announcements-are-not-transactions.md) | A card's announcements are not its transactions (38 rows; −₹35,882.70 and +₹2,554.00) | Important | **Done** |

A credit card announces what *will* happen, acknowledges what the holder *did*, and reports
a purchase. Only the third moved money this month, and the lens read all three as purchases.
**The monthly statement** (`is due by`, a phrasing TASK-44's vocabulary lacked) was counted
as a completed purchase — and because a statement total is the sum of purchases already
counted individually, it double-counted them in a lump: 10 rows, **−₹35,882.70**.
**The bill payment** was counted as a *refund*, because HDFC writes "was **credited** to your
card" and the guard demanded "received" — so settling the bill made spend look smaller:
8 rows corpus-wide of one identical sentence, 2 in window, **+₹2,554.00**. **The purchase**
carried a merchant name in its own text that nothing read, leaving 26 rows showing
"Card Purchase" while `MerchantDisplay` reported `resolved: true`.

**The layering decision is the transferable part.** The merchant fix went into
`MerchantDisplay`, not the parser, because the parser runs at scan time on the **raw** SMS —
which the export does not store. A parser change cannot be predicted offline and reaches an
existing row only after a device rescan; a read-time change renames rows already in the
database and can be measured before it ships. Redaction replaced amounts and account
numbers, never merchants, so the name survives in the text the read-time layer sees.
26 rows renamed at one clock, 15 at another, **none renamed from anything but the
placeholder and none lost a name.**

**Six inherited backlog items were measured and moved nothing** — bank-side refunds and the
`Info:` subset (every row out of window), the unowned ATM cash (working as designed; the rows
*are* typed `atm`, coverage runs on a 90-day window where the figure is ₹1,00,000, and
reconciliation is current-month by design), the 21 tailless card rows (**none is a
purchase**), the three ATM vocabularies (34 divergent rows, 0 counted as spend, nothing since
2021), and the `MoneyLens` ↔ `CardCycleEstimator` cycle. **Both real finds came from probing
sideways**, neither from the ranked list. A task doc's own premises are evidence, not fact.

**Device-verified 2026-08-07 without a rescan** — every fix in the task derives from
`rawBodyRedacted` at read time, and the device md5 was identical before and after the
install. The renamed Amazon row was confirmed on screen to the rupee; the two money deltas
were not, and cannot be, because their rows are months old and the visible bars round to
₹1.6L.

**Still open: one row.** A machine token renders as the payee `Sy0525015` (₹400, in window) —
TASK-46's defect class surviving in a single row. Deferred deliberately: the fix edits the
predicate that names *every* transaction, and `samplepayee1910` and `1mg` are legitimate
neighbours. The inherited "17 rows" counts things the code deliberately decided are not
identifiers.

---

## Context every agent needs

**Product.** A salary-anchored, explainable monthly cash-flow forecaster. For any
upcoming month it answers one question: *"how much do I need in the bank, and why?"* —
learned from the user's own SMS history rather than a static budget.

**Platform.** Android-only SMS reading via `READ_SMS`. This is intentional and makes
the build Play-Store-ineligible; the app is sideload-only by design. iOS falls back to
Gmail-only. Do not "fix" this.

**Privacy floor.** SMS bodies never leave the device. Before storage a body must be
redacted (`raw_body_redacted`) and hashed with a per-install salt (`body_hash`).
At-rest encryption (SQLCipher) is deferred, so redaction is the *only* barrier —
`allowBackup="false"` plus the backup-rules exclusion is the second.

**Two spec invariants** the reviewers repeatedly measured against:

> **No silent exclusion.** The forecast may not silently drop a material known amount
> and still show a confident surplus. Anything excluded must produce a coverage line
> naming what was excluded and why.

> **One owner per rupee.** Every input amount must be attributed to exactly one owner.
> No amount may be counted twice, and none may vanish.

**Specs on disk.** `docs/2026-07-08-sms-actuals-layer-design/` (5 parts) is committed
and is the primary reference. The `2026-07-21` and `2026-07-22` plans and specs are
**not** in the repo — the rules they contain have been inlined into the task files
that need them.

---

## Audit provenance

Four independent reviewers, each scoped to one module:

| Reviewer | Scope | Verdict |
|---|---|---|
| Money & forecast math | `money.dart`, ledger, adapter, explorer, estimators, reserve planner | Not ready |
| SMS parsing & privacy | parser, patterns, classifier, privacy, normalizer, policy | Not ready |
| Persistence & migrations | database, schema, 4 repositories and stores | Not ready |
| Reconciliation & detection | reconciliation engine, matchers, detectors | Not ready |

Two findings were reported **independently by two reviewers** — the seasonal
month-to-date double count (TASK-16) and the month-end date overflow (TASK-01). Those
carry the highest confidence.

Eight findings were re-verified by reading the source directly before this plan was
written: the date overflow at three sites, the `double.tryParse` anchor, the redaction
gaps, the `repayment` direction inversion, the `upsert` replace, and the missing
`onDowngrade`.
