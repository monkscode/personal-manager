# SMS Actuals Layer - Platform, Testing, Risks, and Implementation Phases

> Split from docs\2026-07-08-sms-actuals-layer-design.md on 2026-07-09.
> Approximate context budget target: keep each implementation file under 300k characters.
> Read docs\2026-07-08-sms-actuals-layer-design.md first for the split index and implementation order.

**Original line range:** 945-1206
**Contains:** Platform/privacy/permissions, dependencies, test strategy, risks, implementation phases

---

## Current implementation boundary

This file describes the eventual platform-enabled SMS Actuals Layer. The current
implementation slice is now the explicit **platform safety + persistence slice**:
Android backup hardening and SQLite persistence are allowed, but SMS reading is
still disabled. Do not add READ_SMS, `flutter_sms_inbox`, `permission_handler`,
or an SMS reader UI in this slice. The only new dependencies allowed here are
`sqflite` and `path` for production persistence, plus `sqflite_common_ffi` for
in-memory repository tests. Reader permissions and user-facing scan/review flows
belong to a later explicit reader/permissions phase after persistence tests pass.

Current acceptance for this slice is therefore:

- Android backup is disabled and data extraction rules exclude the SMS database
  and shared preferences before any SMS-derived persistence ships.
- SQLite schema, migrations, transaction repository, obligation repository, and
  legacy saved-bill import tests pass with an in-memory database.
- Pure Dart parser/privacy/money/forecast/reconciliation tests continue passing.
- Static platform-boundary tests prove the app still does not request `READ_SMS`
  and does not add SMS reader dependencies yet.
- The same static tests remain a pre-ship guardrail: once a later branch adds
  `READ_SMS`, the manifest must already have `android:allowBackup="false"` and
  data-extraction exclusions for SMS-derived storage and shared preferences.

## 8. Platform, privacy, permissions

- **Android platform-enablement phase:** add
  `<uses-permission android:name="android.permission.READ_SMS"/>` to the main manifest only in the
  explicit reader/permissions phase; runtime request via `permission_handler` behind a rationale
  screen. The same phase must set `android:allowBackup="false"` and backup/`data_extraction_rules`
  that **exclude the transactions DB and shared preferences** (§4) so SMS data and existing AI
  credentials are never auto-synced to Drive. Handle
  **permanently-denied** permission by deep-linking to app settings (`openAppSettings()`)
  instead of silently failing.
- **iOS / others:** feature gated by `Platform.isAndroid`; entry points hidden; parser and
  repository still compile and are unit-tested (pure Dart).
- **Privacy:** on-device only; only bank-like messages are read into memory; redacted SMS bodies
  are stored locally in SQLite and never uploaded. "Local only" does not mean backup-safe by
  default, so backup disabling/exclusion is required before raw SMS-derived storage ships. (The
  optional Gmail AI extractor is the one path that leaves the device, and it handles *email*
  bodies — never SMS; see §2.) SETUP.md / README updated to describe the SMS permission,
  redaction, and backup behavior.
- **At-rest honesty:** v1 does not include SQLCipher, so structured columns such as merchant,
  amount, balance, and account last4 are plaintext inside the app sandbox. The v1 protection is
  Android app sandbox + `allowBackup=false`/data-extraction exclusion + redacted raw bodies, not
  database encryption. `body_hash` must be salted/keyed so common templated SMS bodies cannot be
  cheaply brute-forced from the hash alone.

## 9. Dependencies planned for the platform-enablement phase

- `sqflite` + `path` — local SQLite.
- `flutter_sms_inbox` — Android SMS inbox read.
- `permission_handler` — runtime `READ_SMS`.

These dependencies are **not** added in the current pure Dart/spec/testing slice. No SQLCipher
dependency in v1 unless a separate key-management design is approved. No AI/network additions; the
existing optional Gemini/Vertex path continues as the separate Gmail-email path.

## 10. Testing strategy (TDD)

- **Parser unit tests** (mirror `test/email_parser_test.dart`): per-bank real-world SMS
  fixtures (SBI/HDFC/ICICI/Axis/Kotak/…), UPI/ATM/POS variants, generic fallback, promo/OTP
  rejection, category mapping, dedup-key stability. Pure Dart — runs in CI without a device.
- **Repository tests**: upsert-by-sms_id idempotency, ref-number dedup, rejection of weak
  amount/day/direction-only duplicate dropping, month/category queries, obligation source/dedupe
  persistence, `manualTx`/Gmail saved-data import into obligations, and migration safety
  (in-memory sqflite). No-ref same amount/day/account/direction collision sets route to review and
  never auto-add both rows.
- **Money-boundary tests**: rupee strings/doubles convert to paise exactly once; ledger sums are
  integer-only; UI formatting is the only paise→rupee conversion.
- **Forecast ledger tests**: dated cash-flow minimum-balance math with a fixed `nowOverride`.
  Required fixtures: rent due before salary (temporary shortfall), salary before rent (no
  shortfall), month-end surplus that still has an early-month dip, and low-confidence seasonal
  shortfall labeled as an estimated buffer rather than a hard due date.
- **Completeness/coverage tests**: every observed/known amount is classified as `anchor_included`,
  `dated_event`, `quantified_excluded`, or `review_pending`; no material known amount may disappear
  while the UI still shows a confident surplus.
- **Current-month reconciliation tests**: already-paid rent/SIP is not subtracted again; unpaid
  future item remains; unmatched item due before a post-due balance anchor becomes
  `needs_review`/possibly-paid instead of being auto-subtracted.
- **Post-anchor discretionary tests**: pre-anchor discretionary stays inside the anchor,
  post-anchor actuals are ledger events, and remaining seasonal uses
  `max(0, S - D_mtd)` so post-anchor spending is not double-counted.
- **RecurringDebitDetector tests**: a true monthly SIP is detected and a one-off is not;
  annual/quarterly cadence; amount jitter within vs over tolerance; **false-cadence negatives**
  (irregular gaps, <3 occurrences, or day-of-month outside the ±4-day window must not lock);
  `nextExpected` correctness; P2P individual streams require stronger evidence and dismissed
  streams stay dismissed; possible recurring/irregular debit candidates surface as quantified
  coverage lines without entering dated forecast until confirmed/locked.
- **SeasonalEstimator tests**: same-month-prior-year present vs absent; trailing-average blend;
  confidence degrades with thin history; recurring/configured/Gmail-owned debits are excluded;
  card purchases update category/cycle insight while cash-flow counts the statement once — all
  deterministic via injected `now`; ATM cash is excluded from training and emits cash-coverage
  caveats at threshold boundaries.
- **Reconciliation tests**: one-owner rules and owner precedence for SIP/EMI, Gmail bill, configured
  contribution, card-bill payment via CRED/BillDesk, refund/reversal with explicit reversal
  evidence, merchant-null recurring debit fallback, same-precedence ambiguous matches, and near-miss
  false positives that stay discretionary/reviewable; cross-month refunds are one dated cash inflow
  plus category netting, not double-counted; cumulative refunds cap at the original debit.
- **Balance-anchor tests**: bank-account balance anchors succeed; credit-card available limit,
  available credit, and card-limit SMS never anchor cash balance; manual-vs-SMS recency selection
  works; freshness boundaries (1/2/5/6 days) drive headline behavior.
- **Undated recurrence tests**: annual/quarterly obligation without due month is `needs_review` and
  excluded from dated forecast but appears as a quantified unscheduled-obligation line; locked
  cadence can supply a low-confidence due month when evidence is sufficient.
- **Salary/income tests**: posted-date vs effective-month salary cannot be counted twice across an
  anchor boundary; stable salary excludes bonus/arrears outliers; variable salary uses conservative
  p20/range wording; cold-start high credits do not become salary base; missing salary suppresses
  forward headlines; self-transfers/P2P income are not promoted without confirmation but repeat
  income candidates are surfaced for confirmation.
- **Partial-card tests**: partial payments create an outstanding quantified obligation; cycles with
  no per-purchase card SMS use statement/payment amount as the expense proxy instead of dropping it
  as a pure transfer; partial purchase coverage uses statement residual, not statement total plus
  observed purchases; card-routed refunds reduce statement/outstanding, not bank cash.
- **Non-primary-account tests**: unknown account hints default to subtract-primary-with-flag;
  observed secondary debits become out-of-primary-scope coverage lines; observed primary debits
  override stale secondary hints; primary-to-secondary transfer bridge prevents double-counting;
  ambiguous bridge candidates route to quantified review.
- **Self-transfer tests**: known own account/VPA transfers never promote as recurring P2P outflows;
  ambiguous repeated P2P outflows that could be own-account movement require confirmation; wallet
  top-ups emit untracked-cash coverage caveats.
- **Gmail parser tests**: high-confidence amountless bill reminder is kept for review; low-confidence
  amountless noise is rejected.
- **Provider graph/live-mode tests**: `insightsProvider` recomputes when the reduced SMS analysis
  snapshot changes, not only when `AppState` changes; SMS-only data exits sample mode.
- **Privacy/platform checks**: current static tests require no `READ_SMS` and no SMS platform
  dependencies before platform enablement. Once `READ_SMS` is intentionally added, the same gate
  requires `allowBackup=false` and data extraction rules that exclude DB/shared prefs.
- **Integration test** (the #1 architectural risk): one end-to-end `scan → parse → dedup →
  persist → reload → recompute` over an in-memory sqflite DB, asserting the forecast reflects the
  persisted actuals — the async boundary is exercised, not only unit-tested.
- **Schema-migration tests**: apply v(n-1) → v(n) against a seeded old DB and assert data
  survives; every migration ships with a test.
- **Fuzz / property tests**: feed malformed/truncated/emoji-laden SMS to the parser; it must
  never throw and never emit a transaction that fails the 2-of-N guardrail.
- **Acceptance gates (define success explicitly).** Parser **precision/recall** targets against a
  versioned, anonymized **golden SMS corpus** (per major bank; governance: redacted, checked-in,
  ≥ a stated N per bank); SeasonalEstimator **MAPE** bound on held-out months. A change that
  regresses these gates fails CI. (Today success is undefined — these numbers make it measurable.)
- No test depends on a physical device or real inbox.

## 11. Risks & open points

1. **Play Store ineligibility** once `READ_SMS` is present — accepted for the later
   platform-enabled build (sideload-only), but not triggered by the current pure Dart slice.
2. **History depth** — year-over-year needs retained SMS; mitigated by the SQLite durable store
   and honest confidence labeling. First runs lean on recurring + bills.
3. **Seasonal-model definition** (§3/§7) — **starting hypothesis (to backtest, not settled):**
   `0.6 × same-month + 0.4 × trailing-N (N=3)`, where **same-month = median across available
   prior years** (robust to a single anomalous month), falling back to recent-average-only (lower
   confidence) when there is no prior-year same-month data. Weights and `N` are tuned against a
   held-out **MAPE** (§10), not asserted; training data is outlier-handled. Confidence scales with
   available history.
4. **Overlap / double-counting** — a recurring auto-debit may also appear as a Gmail bill, a
   configured contribution, a card-payment debit, **or in the estimator's own training set** (it
   learns from the same historical debits). §7's **one-owner reconciliation** assigns each rupee
   one owner before totals are computed. This is the **single most important correctness test** in
   the suite — imperfect exclusion silently double-counts SIPs/EMIs/card bills.
5. **Recurring detection lag** — needs a few months of history to lock a cadence; until then the
   detector yields nothing and the engine relies on bills + configured contributions.
6. **Regex brittleness** — Indian bank SMS formats vary and change; mitigated by the generic
   fallback, the confidence/review gate, stored redacted context, and source hashes for safe
   re-processing when parsers improve.
7. **Async SQLite vs sync Insights** — resolved by having `TransactionsNotifier` cross the async
   boundary once and hand the forecast **fully-reduced** results (commitments, seasonal map,
   reconciliation state, year-over-year comparison, strict anchor) — not a raw window it would have
   to re-scan. The cached transaction window is for this-month rendering only; anything needing
   deep history (estimator lookback, "this month last year") is reduced up-front (see §3). Revisit
   if history grows very large.
8. **Balance anchor edge cases** — not every bank SMS reports `Avl Bal`; some users have
   multiple accounts whose balances don't sum. **Decided (see §7 "Anchor safety"):** parse
   balances from **bank-account SMS only** (never a card's available limit) and resolve the
   anchor **per account**, taking the **primary** (salary-landing) account; fall back to a
   user-entered value. v1 does not sum every account into one net-worth balance, but it does use
   account hints and quantified out-of-primary-scope lines so secondary-account obligations do not
   silently distort the primary-account forecast. The anchor is shown with its
   "as of <date/txn> · <account>" so the user can sanity-check.
9. **Salary detection lag** — until a recurring salary credit is detected, the configured
   salary value is used; the UI states which is in effect.
10. **Refunds / reversals** — a debit that is later refunded (failed/returned txn) would
    over-count spend if the credit reversal is missed. The engine nets a credit only with explicit
    reversal/refund evidence plus amount/date/reference/merchant support; coincidental same-amount
    credits remain income/reviewable. Covered by tests.
11. **Credit-card spend vs bank debit (double-count risk)** — **decided:** a credit-card purchase
    SMS ("spent on your … Credit Card") does **not** reduce bank cash immediately and does **not**
    become a second seasonal cash outflow. It updates category insight and the current
    `CardCycle` estimate. The card statement/payment is the one dated bank cash-flow event, shown
    before the due date so the user can plan. Card bill payments via CRED/BillDesk/reward apps are
    reconciled by due-window/category/card-payment evidence, not merchant-only matching.
12. **Annual/quarterly obligation without a due month (verified latent bug, inherited).** In the
    existing `obliInYm` (`lib/data/real_insights.dart`), an `annual` obligation with no `dueDate`
    anchors to `now.month` (`final anchorMonth = (due?.month ?? now.month) - 1;`), and `quarterly`
    similarly anchors to the current year-month when `due == null`. The new engine must not inherit
    this. **Fix:** annual/quarterly obligations require a known due month/date; absent one, they are
    `needs_review` and excluded from the dated monthly forecast rather than silently defaulting to
    "this month."
13. **Dated cash-flow modeling** — month-end net can hide an early-month shortfall. The forecast
    ledger tracks minimum in-month balance and labels the date/reason of the dip. This is required
    for the product promise "how much do I need in the bank, and why?"
14. **Current-month actuals vs forecast** — latest bank balance already includes paid transactions.
    The current month must reconcile paid/unpaid/overdue items and never subtract already-paid
    obligations again.
15. **Obligation dedupe** — repeated Gmail/SMS scans can duplicate obligations unless confirmed
    obligations store source IDs and dedupe keys. The canonical obligation store fixes this; manual
    review alone is not sufficient.
16. **Backup/privacy boundary** — Android backup and existing shared-pref AI credentials make
    "local only" insufficient by itself. v1 disables backup, excludes DB/shared prefs, and stores
    redacted SMS bodies.
17. **SMS-only live mode** — existing UI logic treats live mode as Gmail/manual-data driven. The
    provider graph must include SMS/obligation snapshot presence so SMS-only users do not remain in
    sample mode.
18. **Money precision boundary** — existing code uses rupee doubles/strings while the new ledger
    uses paise integers. Conversion must happen once at a defined adapter boundary to avoid drift.
19. **Existing saved bills migration** — current users have bills in `manualTx` shared prefs. Those
    entries must import into canonical obligations before the forecast read path changes.
20. **Estimated seasonal timing** — low-confidence seasonal allocation must not masquerade as a hard
    due-date shortfall. The UI labels seasonal-only dips as estimated buffer shortfalls.
21. **ATM / cash coverage gap** — SMS proves only that cash left the bank, not how it was spent.
    ATM rows are cash-flow events, excluded from seasonal training, and surfaced through
    `cashDrainRatio` coverage caveats. Heavy-cash users get lower coverage confidence rather than a
    falsely precise surplus. Current-month cash is shown as withdrawn/spent so far; the app does
    not guess categories or automatically reduce a specific seasonal category without user input.
22. **Stale anchor optimism** — a balance anchor older than six days can miss unobserved spend.
    Freshness is behaviorally enforced: stale anchors downgrade the headline and prompt balance
    confirmation.
23. **Post-anchor discretionary double-count** — actual discretionary spending after the anchor can
    be counted once as a real debit and again inside seasonal remainder. The required formula is
    `remainingSeasonal = max(0, S - D_mtd)`, with only post-anchor actuals replayed as events.
24. **Non-primary account obligations** — v1 does not sum all accounts. Unknown account hints
    subtract from primary with a flag; observed secondary payments are quantified out-of-primary
    scope; observed primary transfers/payments remain the primary-account cash-flow event.
    `transfer_bridge_candidate` rules prevent the transfer and the secondary obligation from both
    subtracting the primary forecast.
25. **Salary and income overstatement** — bonus/arrears/P2P income/self-transfers can inflate future
    inflow. Salary base excludes outliers, variable salary is conservative, self-transfers are
    excluded, and P2P income needs confirmation before promotion.
26. **Refund and card timing** — category netting must not erase dated cash movement. Bank-routed
    refunds are dated cash inflows; card-routed refunds reduce cycle outstanding/statement totals.
    Partial card outstanding is a quantified obligation carried into statement reconciliation, and
    card statement amounts become the expense proxy when purchase SMS are missing.
27. **Known but unscheduled obligations** — excluding unknown due dates from dated totals is correct,
    but the amount must remain visible as a quantified coverage line until the due month is set or a
    locked cadence supplies it.
28. **P2P false negatives** — requiring confirmation before surfacing all P2P outflows can hide rent
    or support payments. High-evidence recurring P2P outflows are included/dismissable or quantified;
    user dismissal is respected to avoid repeated false alarms.
29. **Self-transfer false positives** — own-account transfers can look like recurring P2P outflows.
    v1 maintains local known own accounts/VPAs, holds ambiguous own-account-like streams for
    confirmation, and treats wallet top-ups as untracked-cash coverage rather than commitments.
30. **Duplicate resend collisions** — if a re-sent bank alert has a new SMS id and no reference, the
    app must not auto-add both matching rows. No-ref same amount/day/account/direction collision
    sets route to review.

## 12. Implementation phases (for the plan step)

0. **Pure safety foundation (current slice):** redaction helper, integer-paise money helpers,
   parser/ingestion policy, storage schema contract, forecast/reconciliation engines, and test
   fixtures for the new forecast/accounting rules. Static boundary tests keep platform permissions
   and platform dependencies out of this slice.
0b. **Platform safety gate (later):** before adding any SMS reader UI or shipping `READ_SMS`,
    harden the manifest with `allowBackup=false`, add backup/data-extraction exclusions, and keep
    the privacy/platform tests green.
1. **Persistence:** add `sqflite`, `TransactionRepository`, `ObligationRepository`, schema,
   migrations, saved `manualTx`/Gmail import, source/dedupe metadata, and tests.
2. **Parser:** `BankPatternLibrary` + `SmsTransactionParser` + strict balance-anchor extraction +
   tests (no UI).
3. **Reader + permissions:** `SmsReaderService` (deep scan in batches), Android manifest,
   rationale, runtime request, permanently-denied flow, cancellation/progress handling.
4. **Review + import flow:** SMS review screen, first-scan review-all, later auto-add with audit,
   safe dedup including no-ref collision review sets, and obligation candidate creation.
5. **Analysis/reconciliation:** `RecurringDebitDetector`, salary/other-income detection,
   P2P/self-transfer classification, transfer bridge candidates, cash coverage metrics,
   card-cycle estimation, `SeasonalEstimator`, and `ReconciliationEngine` with deterministic owner
   precedence plus one-owner/completeness tests.
6. **State/provider graph:** `TransactionsNotifier` emits `SmsAnalysisSnapshot`; `insightsProvider`
   watches `AppState` + snapshot and exposes loading/error/stale-anchor states.
7. **Forecast engine:** dated event ledger, minimum in-month balance, paid/unpaid/possibly-paid
   current-month handling, post-anchor discretionary residuals, stale-anchor behavior, quantified
   coverage lines, low-confidence seasonal buffer labeling, rolling month-to-month closing balance,
   `ForecastLine` breakdown, and tests.
8. **UI:** Home recommendation card, anchor/staleness display, salary strip, **why-log** screen,
   Transactions tab, and Insights expected-vs-actual/historical views in live mode.
9. **Existing Gmail hardening:** non-AI amountless high-confidence bills kept for review; amount
   recovery uses token-adjacency parser.
10. **Docs:** README/SETUP updates for SMS permission, redaction/backup behavior, sideload-only
    status, and the new forecast model.

> **Sequencing note.** Phases 0–4 (safety, persistence, parser, reader, review/import) deliver value
> immediately — real transactions in the Transactions tab and a durable history — with **no**
> dependence on accrued data. The `SeasonalEstimator` and `RecurringDebitDetector` (phase 5) are
> **data-starved until ~3–12 months of history exist** (risks 3/5), so their forecast
> contribution is deliberately provisional at first and firms up as the SQLite store grows. Build
> the data layer first and let the estimators earn trust over time, rather than presenting
> confident seasonal numbers on day one.
