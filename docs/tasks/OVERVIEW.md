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
| [TASK-38](TASK-38-forecast-surface-cleanups.md) | Forecast-surface cleanups | Minor | **Done bar F4** |
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
