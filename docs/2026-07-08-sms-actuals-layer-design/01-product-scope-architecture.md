# SMS Actuals Layer - Product, Scope, and Architecture

> Split from docs\2026-07-08-sms-actuals-layer-design.md on 2026-07-09.
> Approximate context budget target: keep each implementation file under 300k characters.
> Read docs\2026-07-08-sms-actuals-layer-design.md first for the split index and implementation order.

**Original line range:** 1-268
**Contains:** Metadata, goal, north star, hard requirements, scope, constraints, architecture, component responsibilities

---

# SMS Actuals Layer — Design Spec

**Date:** 2026-07-08
**Status:** Reviewed + amended for implementation planning
**Author:** Dhruvil + Claude
**Reference studied:** [`Devasy/Personal-Wallet`](https://github.com/Devasy/Personal-Wallet) (SMS bank-transaction parser)
**Review update:** 2026-07-09 — incorporated the strict pre-implementation review decisions.
**Stress-hardening update:** 2026-07-09 — added real-world cash, stale-anchor,
multi-account, income, refund, card, annual-obligation, and UPI/P2P guardrails.

---

## 1. Goal & product model

The app is a **salary-anchored, explainable monthly cash-flow forecaster**. For any upcoming
month it answers one question — **"how much do I need in the bank, and why?"** — by learning
from the user's own history rather than a static budget.

**Required-in-bank (for a target month)** =

1. **Recurring auto-debits** — SIPs, EMIs, subscriptions, insurance that leave the salary
   automatically. Some are monthly; some land once a year in a specific month. Detected from
   **SMS history** and reinforced by user-configured contributions (NPS/PPF/MF).
2. **Known upcoming bills** — extracted from Gmail (existing forecast path).
3. **Expected seasonal spend** — *"last year this month you spent ₹X"* plus a trailing-average
   of discretionary spend, learned from **historical SMS**. For cash-flow, this is split by payment
   rail: bank/UPI discretionary spend becomes seasonal cash allocation, while credit-card purchase
   SMS feeds card-cycle estimates and category insight so card spend is paid once through the card
   statement event.

The app then compares this against **available** using a **dated cash-flow ledger** — not just a
month-end total. Each expected income/outflow carries a date, the latest bank-SMS balance anchors
the ledger, and the engine computes the **lowest projected balance inside the month** (see §7).
If salary arrives after rent, the app must surface the early shortfall even if the month ends with
a surplus. If short, it says **"you need ₹5,000 more before <date>"**; if ahead, **"you'll have ₹X
extra."** Either way it shows an **itemized log of *why*** — every rupee traceable to a specific
recurring debit, a specific bill, a dated income, or a category of expected spend.

So SMS is not merely "spent so far this month." It is (a) the **historical training data** for
the seasonal estimate and (b) the **detection source for recurring auto-debits**.
**Explainability** — the ability to drill into any number and see its drivers — is a
first-class requirement, not a nice-to-have.

The existing Gmail forecast and configured-contributions engine is retained and becomes one of
three inputs to the Required-in-bank figure.

### North star (why this exists)

The end product is a **year-round financial planning companion ("personal CFO")**: it looks
across the *whole year*, surfaces every future obligation and savings goal in advance, and tells
the user **what to set aside each month** so nothing (an annual insurance premium, a PPF/NPS
deadline, a lumpy bill) ever catches them off guard — *"here's your plan for the year, and
here's what to do this month."*

**This document (Spec 1) is the data + rolling-forecast foundation** that the planner runs on.
The full planner — sinking funds, tax/goal planning, instrument rules, a yearly action list — is
**Spec 2** (§13), brainstormed separately on top of this. Spec 1 is deliberately built
*planner-ready*: an N-month/full-year engine, dated obligations, a balance model that can later
split **free vs earmarked**, and a reusable recurring-commitment model.

### Review decisions that are now hard requirements

The following decisions are not optional implementation details; they are required so the headline
number is trustworthy:

1. **Dated cash-flow, not month-end net only.** The forecast computes the minimum projected
   in-month balance and surfaces the date/reason of the lowest point.
2. **Current month reconciles paid vs unpaid.** Latest bank balance already includes actuals;
   current-month required means remaining unpaid requirements, not the full-month total again.
3. **Obligations have persistent identity.** Gmail/manual/SMS-derived obligations carry source
   metadata and a stable dedupe key; bare `ExpenseEntry` rows are only a UI adapter.
4. **Insights watches SMS analysis.** SQLite facts feed a reduced analysis snapshot that the
   forecast provider watches alongside `AppState`.
5. **Every rupee has one owner.** A rupee counted as a recurring commitment, Gmail bill, configured
   contribution, refund/reversal, transfer, card-payment, or discretionary spend is tagged and
   cannot also train/count elsewhere.
6. **SMS duplicate dropping requires strong evidence.** `amount + day + direction` alone is never
   enough to discard a transaction.
7. **Balance anchors require positive bank-account evidence.** Credit-card available limit/credit
   messages can never anchor cash balance.
8. **No guessed due month for annual/quarterly items.** Missing due month/date means
   `needs_review`, not "due this month."
9. **Local privacy is explicit.** v1 disables Android backup, excludes DB/shared prefs from data
   extraction, and stores redacted raw SMS. SQLCipher is deferred unless key management is designed.
10. **Amountless high-confidence Gmail bills are retained for review.** Gmail can supply due
    date/merchant even when SMS or user input supplies the amount.
11. **Live mode includes SMS-only data.** A user who scans SMS but never connects Gmail must still
    leave sample mode; live-mode predicates read the SMS/obligation snapshot, not only `AppState`.
12. **All ledger math is integer paise.** Legacy rupee doubles/strings are converted once at ingest
    or forecast-boundary with a stated rounding rule; sums never mix floats and paise internally.
13. **Existing saved bills migrate forward.** Current `manualTx`/Gmail-confirmed `ExpenseEntry`
    payloads are imported into the canonical obligation store so existing users do not lose bills.
14. **Owner precedence is deterministic.** When two sources can claim the same rupee, a fixed
    precedence decides the owner and tests assert the outcome.
15. **No silent exclusion.** Every observed or known rupee lands in exactly one of: already inside
    the balance anchor, a dated forecast event, or a named **quantified** excluded-risk line shown
    to the user. Uncertainty may lower confidence, but it may not disappear from the plan.
16. **Cash/ATM is an explicit blind spot, not learned spend.** ATM debits are cash-flow events and
    become `untracked_cash` coverage warnings when material; the app never pretends to know how
    cash was spent without user-entered cash transactions.
17. **Anchor freshness changes behavior.** Stale anchors degrade the headline and prompt balance
    confirmation; freshness is not only a cosmetic chip.
18. **Account hints are advisory.** Unknown payment account defaults to "subtract from primary but
    flag"; observed primary debits override stale hints, and observed secondary debits become
    quantified out-of-primary-scope lines rather than silent drops.
19. **Posted date controls cash; effective period controls planning.** Salary/date-drift handling
    stores both dates, but a salary already posted before the anchor is never added again as future
    income.
20. **Credit-card cycle awareness prevents surprise bills.** Card purchase SMS updates category
    insight and the current card-cycle estimate, but the bank cash-flow ledger counts the card
    statement/payment **once** on its expected payment date. The app must warn before the payment
    cycle: "your next card bill is expected around ₹X due <date>."
21. **Refunds and partial card payments preserve cash timing.** Refunds reduce expense categories
    but become bank cash inflows only when the refund actually credits a bank account; card-routed
    refunds reduce card outstanding/next statement instead. Partial card outstanding is an active
    quantified obligation, not a vague review item.
22. **P2P/UPI recurrence is asymmetric.** High-evidence recurring P2P outflows are included or
    surfaced as quantified dismissable risks; recurring P2P income requires stronger confirmation,
    and self-transfers are excluded before income/outflow promotion.

## 2. Scope

### In scope (v1)
- On-demand SMS scan (user-triggered), Android only, scanning **as deep as the inbox allows**.
- Bank-SMS parsing into structured debit/credit transactions (INR).
- Review/confirm flow: first scan reviews all; later scans auto-add confidence ≥ 0.8 and
  queue the rest for review.
- **SQLite as durable history** (dedup by SMS id; queryable by month/category) — persists what
  we scan so the forecast keeps improving even after the phone prunes old SMS.
- **Seasonal Estimator** — expected spend for a target month from same-month-prior-year blended
  with a trailing-average, degrading gracefully when history is thin (with a stated confidence).
- **Recurring-Debit Detector** — identifies repeating debits (merchant/amount cadence) as
  committed monthly/annual outflows from salary.
- **Required-in-bank + shortfall recommendation** — salary-anchored: "you need ₹X more this
  month/by <date>," computed from a dated cash-flow ledger with an **explainable itemized "why" log**
  for every figure.
- Transactions tab shows real transactions grouped by day in live mode.
- Insights: per-category expected-vs-actual and the historical comparison.

### Out of scope (future, but architecture leaves room)
- **Background auto-capture** of incoming SMS (planned next; see §3 decoupling).
- Full multi-account balance summing/reconciliation and multi-currency (INR only for now). v1 only
  uses account hints to avoid misleading the primary-account cash-flow forecast.
- CSV import/export, net-worth, investments-from-SMS.
- User-editable regex patterns (built-in library only in v1).

### Hard constraints (accepted)
- **Android-only.** `flutter_sms_inbox` has no iOS equivalent; on iOS the SMS feature is
  hidden and the Gmail forecast continues to work cross-platform.
- **`READ_SMS` ⇒ sideload-only.** Google Play restricts `READ_SMS`; a personal-finance
  reader generally does not qualify. This app is already distributed as a sideloaded APK,
  so this is acceptable. It does mean the app cannot ship on Google Play while this
  permission is present.
- **Historical depth depends on the phone's retained SMS.** Year-over-year needs ~12+ months
  still in the inbox; Android/carriers often prune. Mitigated by the SQLite durable store
  (§4) — the forecast bootstraps from whatever exists and improves as it accumulates its own
  history. UI states confidence honestly when history is thin.
- **Privacy (SMS):** all **SMS** parsing and storage is strictly on-device; SMS data is never
  uploaded. This blanket claim applies to the SMS layer only — the pre-existing, **opt-in** Gmail
  AI path (Gemini/Vertex) *does* upload **email** bodies to Google when the user configures a key.
  That path is unchanged and never touches SMS.

## 3. Architecture & components

```
Trigger  (on-demand now │ background receiver later)   ← decoupled interface
   │
SmsReaderService        typed scan outcome, read inbox (flutter_sms_inbox), ONE strict bank filter, deep history
   │
BankPatternLibrary      per-bank sender IDs + typed regexes (built-in, immutable)
   │
SmsTransactionParser    sender → content → generic fallback; confidence; txn-type;
   │                    merchant/category/account/ref/balance; strict anchor signals
   │
TransactionRepository   SQLite durable history: upsert by sms_id/ref, safe dedup, month/category queries
   │
   ├── ObligationRepository     confirmed Gmail/manual/SMS obligations with source IDs + dedupe keys
   ├── ReconciliationEngine     assigns each rupee one owner; paid/unpaid; refund/card-payment joins
   ├── RecurringDebitDetector   finds repeating debits + eligible credits → dated commitments/income
   ├── SeasonalEstimator        discretionary-only same-month ⊕ trailing avg → expected spend + confidence
   │
TransactionsNotifier    Riverpod: produces a reduced SMS/obligation analysis snapshot
   │
ForecastEngine          dated cash-flow ledger: minimum in-month balance, closing balance,
   │                    shortfall date, and explainable ForecastLine list
   │
UI                      Home recommendation card, drill-down "why" log, Transactions tab,
                        Insights (expected-vs-actual + historical)
```

**Live-mode predicate:** sample mode is shown only when there is no real user data in any source:
no confirmed obligations/manual entries, no connected Gmail state, and no SMS transaction/analysis
snapshot. An SMS-only user must see live Home/Transactions/Insights once the SQLite store has data.

**Trigger decoupling (future background capture):** everything from `SmsTransactionParser`
downward is trigger-agnostic. The on-demand scanner and a future background `BroadcastReceiver`
both call the same `parse → dedup → persist` path. Adding background capture later means
adding a trigger + `RECEIVE_SMS`, not rewriting the pipeline.

### Component responsibilities

- **`SmsReaderService`** — reads the SMS inbox, applies **one** strict bank filter
  (sender-ID match **or** (bank-name in body **and** amount pattern present)); rejects
  OTP/promo. Android-only and returns a typed `SmsScanOutcome`/status rather than a bare list:
  `success`, `unsupportedPlatform`, `permissionDenied`, `permissionPermanentlyDenied`, or `failed`.
  Only a `success` outcome may contain an empty message list. Unsupported platforms hide the SMS
  entry point, permission failures show actionable UI, and callers must never treat failure as
  "zero bank SMS found."
- **`BankPatternLibrary`** — immutable list of `BankSmsPattern` (sender IDs + regexes per
  transaction type) for the major Indian banks. Loaded once; not mutated at runtime.
- **`SmsTransactionParser`** — pure Dart, no platform/network deps. Turns a raw SMS into a
  `ParsedTxn?` via the **normalize → tokenize → extract** pipeline adopted from
  `transaction-sms-parser` (§6): normalization, token-adjacency amount/balance extraction, and
  the **2-of-N validity guardrail** (≥2 of {amount, account, balance, UPI-ref, known bank sender})
  as the primary false-positive filter. Fully unit-testable with per-bank fixtures.
- **`TransactionRepository`** — SQLite persistence; `upsertBySmsId`, `queryByMonth`,
  `queryByCategory`, `allSince`, `monthlyTotalsByCategory`, `latestBalanceAnchor` (strict
  bank-account-only balance signal), safe duplicate checks, and migrations. Acts as the app's
  **durable history** — retains scanned transactions even after the phone prunes SMS.
- **`ObligationRepository`** — durable identity for confirmed obligations from Gmail, manual entry,
  configured plans, and SMS-recurring detection. Stores source metadata, normalized merchant,
  amount/due status, recurrence, due date/month, and a stable dedupe key. `ExpenseEntry` remains a
  view-model adapter for existing UI, not the canonical persisted obligation model.
- **`ReconciliationEngine`** — pure Dart. Matches actual SMS transactions against expected
  obligations/contributions/bills, tags each rupee with one owner, splits current-month expected
  items into paid/unpaid/overdue, nets explicit reversals/refunds, and prevents seasonal training
  from learning already-counted commitments.
- **`RecurringDebitDetector`** — pure Dart. Despite the historical name, this component owns both
  recurring debit commitments and eligible recurring credit/income candidates. It scans transaction
  history for repeating debits and emits
  `RecurringCommitment { merchant, amount, cadence, category, nextExpected, confidence }`.
  Recurring credits are promoted to expected income only through the stricter salary/income rules in
  §7; weaker credit patterns remain review/coverage candidates because over-counting income creates
  false safety.
  **Cadence algorithm (specified).** Group by normalized merchant; within a group require
  **≥3 occurrences** to lock a cadence; take inter-occurrence gaps and classify as **monthly**
  (gap ≈ 28–33 d), **quarterly** (≈ 88–95 d), **half-yearly** (≈ 178–190 d) or **annual**
  (≈ 360–370 d), with a **day-of-month variance window of ±4 days**; tolerate **amount jitter of
  ±10% (or ±₹50, whichever is larger)** to absorb variable utility/EMI amounts. A group whose
  gaps fit no band, or has <3 hits, stays **unlocked** (emits no commitment). `nextExpected` =
  last occurrence + locked period. Reinforced by user-configured contributions; unit-testable
  with fixed history fixtures **including negative fixtures for false cadences**.
  **Completeness add-on:** unlocked does not mean invisible. Two similar debits, or three debits
  with irregular gaps/amounts, emit a low-confidence `possible_recurring_debit` or
  `irregular_repeating_debit` review candidate with amount range and latest dates. It is not added
  to dated forecast until confirmed/locked, but it appears as a quantified coverage line so a new
  SIP, bi-monthly maintenance, or variable quarterly tax does not create a silent false surplus.
  Annual cadence from SMS requires ~3 years of retained SMS and is therefore not expected to work
  reliably in v1; annual obligations primarily rely on Gmail/manual/user due-month entry unless
  enough history genuinely exists.
- **`SeasonalEstimator`** — pure Dart. For a target month, computes expected **discretionary
  bank/UPI cash allocation** per category by blending same-month history with a trailing average —
  starting
  point **`0.6 × same-month + 0.4 × trailing-N`** with **`N = 3`**. The weights and `N` are a
  **starting hypothesis to backtest, not a settled constant.** Crucially, "same-month" uses a
  **robust statistic — the median across all available prior years**, not a single prior-year
  sample, so one anomalous purchase last July can't poison this July's estimate; with only one
  prior year, confidence is lowered accordingly. Training data is **outlier-handled** (refund/
  reversal netting per §11.10 **plus** winsorizing extreme one-offs) — not merely transfer/ATM
  exclusion. When same-month history is unavailable (thin history) it falls back to **recent-
  average only**, flagged lower confidence. Returns the estimate **plus a confidence** that scales
  with how much history backed it (surfaced in the UI). Deterministic via an injected `now`.
  **Excludes** `transfer`/`atm` transactions, card-cycle-owned card purchases/payments, and anything
  already owned by a recurring commitment, Gmail bill, configured contribution, refund/reversal, or
  card-payment reconciliation (the one-owner reconciliation, §7). Card purchases are still retained
  for category insight and `CardCycle` estimates; they are not projected again as separate bank
  seasonal cash. **Backtest before trusting:** hold
  out the last known month(s) and report **MAPE** (§10); tune weights/`N` against that.
- **`TransactionsNotifier`** — Riverpod notifier. On scan/app-load it (async) pulls history and
  obligations from repositories, runs the detector/estimator/reconciler **once**, and caches a
  **fully-reduced `SmsAnalysisSnapshot`**: commitments, expected income, seasonal category map,
  paid/unpaid status, latest strict balance anchor, pre-computed "same-month last year vs now,"
  and the current-month transaction window. **Key point:** the sync UI must never re-scan deep
  history, yet the estimator's lookback (12+ months) and the year-over-year comparison need data
  *outside* any "recent window." `insightsProvider` must watch both `AppState` and this snapshot;
  the async DB/analysis boundary is crossed once, not per render.
