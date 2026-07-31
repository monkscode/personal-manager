# SMS Actuals Layer - Forecast and Reconciliation Engine

> Split from docs\2026-07-08-sms-actuals-layer-design.md on 2026-07-09.
> Approximate context budget target: keep each implementation file under 300k characters.
> Read docs\2026-07-08-sms-actuals-layer-design.md first for the split index and implementation order.

**Original line range:** 480-944
**Contains:** Dated forecast ledger, coverage lines, owner/completeness reconciliation, anchors, salary, income, cash, transfers, card cycles, annual/P2P, why-log, UI

---

## 7. The recommendation engine + explainable "why" log

This is the heart of the product. For a **target month** the engine produces one headline
number and a fully itemized justification. The headline is based on the **minimum projected
balance inside the month**, not only the month-end net.

### Required-in-bank (target month) as dated events
```
Required = Σ RecurringCommitments due in month        (SMS-detected + configured contributions)
         + Σ Known upcoming bills in month            (Gmail forecast)
         + SeasonalEstimate(month)                    (expected discretionary spend, per category)
```

Those sums are still useful category totals, but the engine converts them into dated
`ForecastEvent`s before producing the recommendation:

```dart
ForecastEvent {
  date;              // exact date or modeled allocation date
  amountPaise;       // integer paise
  direction;         // inflow | outflow
  source;            // salary | otherIncome | recurring | gmailBill | seasonal | transfer | manual | untrackedCash | cardOutstanding
  ownerKey;          // reconciliation owner; prevents double-counting
  label;
  confidence;
}

BalanceAnchor {
  amountPaise;
  asOf;              // transaction/SMS timestamp the balance belongs to
  accountLast4;
  source;            // smsBankBalance | manualUserEntry
  freshness;         // current | amber | stale
}

ForecastCoverageLine {
  label;
  amountPaise;       // nullable only when the amount is genuinely unknown
  reason;            // untracked_cash | stale_anchor | out_of_primary_scope | unscheduled_obligation | review_needed | future_earmark
  action;            // confirm_balance | set_due_month | dismiss | mark_unpaid | link_account
  confidence;
}

ForecastMonthResult {
  openingBalancePaise;
  closingBalancePaise;
  minimumBalancePaise;
  minimumBalanceDate;
  shortfallPaise;    // max(0, -minimumBalancePaise)
  events;
  coverageLines;     // named quantified exclusions; never silently hidden
  anchor;
  lines;             // UI why-log lines
}
```

**Dated ledger algorithm.**
1. Start from the strict primary-account balance anchor (§7 "Anchor safety").
2. Build dated inflow events: detected salary, user-configured salary fallback, recurring credits,
   and user-entered expected credits.
3. Build dated outflow events: unpaid obligations, known bills, configured contributions, and
   seasonal discretionary allocation.
4. Sort by date, apply events in order, and track both closing balance and the lowest balance.
5. Headline shortfall is based on the lowest point: if balance dips below zero on the 2nd and
   salary arrives on the 30th, the app reports the 2nd's gap instead of hiding it behind
   month-end surplus.
6. Same-date uncertainty is conservative: when an inflow and outflow share a date and no stronger
   posting time is known, outflows are applied before inflows for the minimum-balance calculation.
   This may overstate a same-day buffer need, but it does not hide an early-day shortfall.
7. Rolling forecasts carry the projected close exactly, including a negative projected close. The
   engine never clamps a deficit to zero between months; the shortfall remains visible until an
   actual or expected inflow covers it.
8. Month 2+ openings are tagged as projected carry-forward anchors, not as fresh SMS/manual balance
   anchors. This preserves the distinction between a real bank anchor and a forecast-derived
   opening balance when explaining confidence.

**Seasonal spend dates.** Seasonal estimates do not have exact due dates. For the minimum-balance
ledger they are allocated by historical day-of-month distribution when enough history exists; with
thin history they are spread evenly over the remaining days of the month and marked lower
confidence. They are still shown as category estimates, not fake exact transactions. If the
minimum-balance dip is caused only by low-confidence seasonal allocation, the UI labels it as an
estimated buffer shortfall rather than a hard due-date shortfall.

### One-owner + completeness reconciliation

The engine has two equal accounting invariants:

1. **Anti-double-count:** every actual/predicted rupee receives exactly one owner before totals are
   computed.
2. **No silent exclusion:** every observed or known rupee is assigned to exactly one **coverage
   bucket**:
   - `anchor_included` — already reflected in the latest safe balance anchor, so it must not be
     added again;
   - `dated_event` — applied to the forecast ledger on a date;
   - `quantified_excluded` — excluded from the dated ledger for a valid reason but shown beside the
     headline with amount, reason, and action;
   - `review_pending` — amount or identity is insufficient; shown in review, not hidden.

This is the safety counterpart to owner precedence. The app may say "this is uncertain," but it may
not silently drop a material known amount and still show a confident surplus.

Every actual/predicted rupee receives exactly one owner before totals are computed:

**Implementation contract.** The pure reconciliation result carries an `assignment` for every input
actual/predicted item. Exactly one assignment owns the rupee and places it in one coverage bucket.
Coverage lines can additionally warn about reliability (for example unknown account hint or material
cash usage), but those warning lines do **not** take a second owner. A test failure is required if an
input item produces zero assignments or two ownership assignments.

Known items outside the target month are still assigned for completeness. They do not become dated
events for the target month; they become `future_earmark` coverage/heads-up lines so annual or lumpy
obligations beyond the selected month are visible without polluting the current ledger.

| Owner | Counted where | Excluded from |
|---|---|---|
| Explicit recurring commitment | Required event | Seasonal training |
| Gmail bill | Required event | SMS recurring duplicate + seasonal training when payment matches |
| Configured contribution | Required event | SMS recurring duplicate + seasonal training |
| Card purchase SMS | Category insight + current card-cycle estimate | Immediate bank cash-flow and duplicate seasonal cash allocation |
| Estimated/actual card statement | One dated bank outflow on expected payment date | Duplicate card purchase cash outflow |
| Card bill/payment debit | Payment/reconciliation against estimated or actual statement | Duplicate expense count |
| Partial card outstanding | Carried into next statement reconciliation; quantified coverage line when date/amount is uncertain | Silent `needs_review` omission and duplicate next-statement count |
| Refund/reversal | Bank-routed refund = dated cash inflow; card-routed refund = reduced card cycle/statement/outstanding; both net category/seasonal against matched debit | Seasonal spend inflation, phantom bank cash, and cross-month double-count |
| Transfer | Balance/transaction list; never income/expense if self-transfer evidence exists | Seasonal training and recurring-income promotion |
| ATM / untracked cash | Cash-flow event + quantified cash-coverage caveat when material | Seasonal training and fake category inference |
| Non-primary-account obligation | Dated event only if primary-account debit/transfer is observed; otherwise quantified out-of-primary-scope line | Primary-account cash-flow subtraction |
| Undated known annual/quarterly obligation | Quantified unscheduled-obligation line until due month is known | Dated ledger totals |
| High-evidence recurring P2P outflow | Dated or quantified dismissable risk, depending on confidence/review state | Silent omission |
| P2P/self-transfer income candidate | Review/transfer exclusion until confirmed non-self income | Recurring-income promotion |
| Discretionary spend | Seasonal estimator | Explicit obligations |

The join cannot rely only on merchant because SMS merchant extraction is often weak. Matching uses
a hierarchy:
1. source IDs / references when available;
2. normalized merchant + amount-within-jitter + cadence/date window;
3. fallback for merchant-null rows: amount/cadence/category/account evidence;
4. card-bill payment rule: issuer/category/due-window/card-payment keywords, not only merchant
   (CRED/BillDesk often hides the issuer);
5. ambiguous matches go to review instead of silently merging or double-counting.

**Owner precedence when multiple sources match.**
1. explicit source/reference match;
2. user-confirmed manual/Gmail obligation;
3. configured contribution;
4. detected recurring commitment;
5. explicit refund/reversal netting;
6. transfer/ATM cash-flow-only classification;
7. discretionary seasonal training.

If two candidates have the same precedence and no source/reference tie-breaker, the row becomes
`needs_review` instead of being auto-owned.

This is the **single most important correctness test suite**: a monthly SIP, insurance premium,
credit-card bill payment, configured contribution, refund, and discretionary near-miss must each
be counted exactly once.

### Available & the rolling (carry-forward) balance
The app models a **rolling dated cash-flow**: each month's projected closing balance becomes the
next month's opening balance.

> **Net-new vs today.** This rolling loop does **not** exist yet: `computeRealInsights` currently
> derives only a two-state balance (current month = actual balance; next month = `balance +
> salary − thisMonthRequired`). The loop below is new construction, and `computeRealInsights`'s
> inputs/signature must grow to take the detected commitments, the seasonal map, and the anchor
> balance (they live in SQLite / the notifier, not in the `AppState` blob it takes today — see §3,
> §4). This is a real change to the forecast call graph, not a drop-in extension.

```
OpeningBalance(M) = projected closing balance of month M−1
Events(M)         = dated inflows/outflows inside M
Balance(t)        = opening balance + cumulative events through date t
Shortfall(M)      = max(0, -min_t Balance(t))
Closing(M)        = Balance(end of month)
```

**Balance anchor (decided):** *today's* balance is taken from a structured `BalanceAnchor`: the
**actual bank-account `Avl Bal` in the most recent strict primary-account SMS anchor** (ground
truth, self-correcting), falling back to a user-entered value if no safe SMS balance is found. All
future months roll **forward** from that anchor — we never reconstruct today's balance from
salary−expenses (which would drift from reality).

**Anchor selection and freshness.**
- Candidate anchors pass the strict safety filter first, then selection is `newest asOf` with a
  source tie-breaker of `smsBankBalance` over manual when timestamps are equal. A manual entry from
  today beats a bank SMS from three days ago; a bank SMS from today beats a manual entry from three
  days ago.
- Exact freshness bounds: `current` = age **0–1 day**, `amber` = **2–5 days**, `stale` = **6+
  days**. Tests assert the day-1/day-2/day-5/day-6 boundaries.
- Freshness changes behavior:
  - `current`: normal headline.
  - `amber`: headline allowed, but marked "based on balance from <date>" with lower confidence.
  - `stale`: headline becomes provisional and the primary CTA is **Confirm balance** / rescan; the
    app must not present "₹X extra" as a confident free-cash message.

**Anchor safety (decided — correctness-critical).** "Latest balance across all senders" is
**unsafe for money** and is not what we do. Two rules:
- **Positive bank-account evidence only.** A credit-card "available limit / available credit" must
  never be read as a balance — the balance keywords (`avl bal`, `available balance`, …) can
  otherwise match a card's available *limit*. Anchor extraction requires bank-account evidence and
  rejects card-limit signals even if the rest of the SMS parsed as a transaction.
- **Per-account, pick the primary.** With multiple accounts, resolve the anchor **per account**
  and use the **primary** one (where salary lands — identified from the salary-credit sender,
  else user-selected). A secondary-account or card SMS arriving later must not flip the anchor.
  v1 anchors to that primary; other accounts are shown but not summed. The anchor is displayed
  with its "as of <date/txn> · <account last4>" so the user can sanity-check.

**Current vs next month:**
- **Current month (in progress)** starts from the latest balance anchor. Expected items due before
  or on the anchor date are matched against SMS actuals:
  - matched → `paid`, do not subtract again;
  - due before a post-due balance anchor but unmatched → `needs_review` / "possibly already paid";
    do **not** auto-subtract again unless the user marks it unpaid or there is no safe balance
    anchor after the due date;
  - due today or future and unmatched → `unpaid`, apply on its due date.
  Its closing balance is the result of applying remaining dated events after the anchor, not
  subtracting the full-month budget again.
- **Current-month discretionary formula.** Let `S` be the full-month seasonal discretionary estimate
  after excluding owned obligations/transfers/card payments. Let `D_mtd` be all confirmed
  discretionary actuals from month start through "now" (both before and after the anchor). Let
  `D_post_anchor` be only those confirmed discretionary actuals after `anchor.asOf`. Then:
  - pre-anchor discretionary is already inside the anchor and is **not** replayed as events;
  - `D_post_anchor` is applied as dated ledger events;
  - remaining projected discretionary =
    `max(0, S - D_mtd)`, allocated over the remaining month using the residual historical
    day-of-month distribution when available, otherwise evenly with lower confidence.
  If `D_mtd > S`, the why-log says "you have already exceeded usual discretionary spend" instead
  of quietly showing zero remaining.
- **Next month** opens at the current month's projected close. So next-month figures are explicitly
  a projection that firms up as the current month ends.

**Salary (detected, not assumed):** the recurring **salary credit** (amount + typical day/window) is
detected from SMS as a recurring `credit`, with the user-configured salary as fallback. The view
reflects whether salary has **already landed** this month or is still expected.

**Salary confidence and date drift.**
- `salary_confidence` is one of `detected_stable`, `detected_variable`, `configured_fallback`,
  `insufficient_data`, or `unknown`.
- The recurring salary base is computed from the stable cluster of salary credits, excluding
  bonus/arrears/outlier months before taking the median. Excess over the stable base is tagged
  `otherIncome` and is not promoted to recurring unless it independently develops a cadence.
- Variable salary is projected conservatively: use a low-percentile floor from observed clean
  salary credits (starting rule: p20, or the lowest clean recurring salary when history is thin) and
  show a range rather than a falsely precise surplus. The why-log shows "salary estimate
  confidence" separately from spend confidence.
- Cold start guard: with fewer than 3 clean salary credits, a single high credit cannot become the
  recurring base automatically. It stays `insufficient_data` / `otherIncome` until confirmed by the
  user or supported by more history.
- Salary transactions store both `txn_date` (posted/cash date) and `effective_month` (budget period).
  **Cash ownership follows `txn_date`: if `txn_date <= anchor.asOf`, that salary is already inside
  the opening balance and is never added again as a forecast event.** `effective_month` only decides
  which month the salary belongs to for explainability and period comparison.
- The salary cadence generator also checks effective-month satisfaction: if a salary posted in this
  calendar month already satisfies the expected effective month, the engine does not create another
  projected salary event for the same effective month.
- Salary drift uses an observed date window, not a hard working-day promise. Weekend/holiday drift is
  absorbed by the window; the minimum-balance ledger uses the pessimistic/late edge when a required
  outflow falls before the likely salary date.
- If neither configured salary nor detected salary exists, forward-month headline forecasts are
  suppressed and replaced with "add income to enable forecast." The app may still show current
  transactions and balance, but it must not project months 2–12 from zero income and alarm the user
  with a false shortfall.

**Other income (decided).** Salary is not the only inflow: interest, reimbursements, cashback,
and one-off credits (e.g. an FD-maturity credit, §13) also land as `credit` SMS. The rolling
forecast adds an **`ExpectedOtherIncome(M)`** line (recurring detected credits + user-entered
expected credits) so months 2–12 don't drift downward by ignoring real money coming in.
Recurring income promotion is stricter than recurring outflow promotion: self-transfers/wallet
top-ups are excluded first, P2P income needs confirmation or strong non-self evidence, and
reimbursements/cashback remain actuals unless the user explicitly marks them expected.
Repeated possible income streams still appear as confirmable candidates ("possible recurring income
₹X from <payer> — confirm?") so real income is not permanently absent from the forward plan.
**Compounding caveat (applies to Spec 1, not just Spec 2).** Only month 1 is anchored to a real
`Avl Bal`; months 2–12 roll forward with no balance correction, so projection error grows
monotonically the further out you look. Far-month figures are labeled lower-confidence
projections, and the plan **re-anchors every time a fresh balance SMS arrives** — the headline
recommendation leans on the near, anchored months.

**Worked example — timing matters:**
| date | event | balance |
|---|---|---:|
| Aug 1 | Opening balance | ₹10,000 |
| Aug 2 | Rent due | −₹8,000 |
| Aug 30 | Salary lands | ₹77,000 |

A month-end-only engine would say "₹77,000 surplus." The dated ledger correctly says "you need
₹8,000 more by Aug 2" because the minimum projected balance is negative before salary arrives.
The symmetric case (no dip below zero) surfaces a surplus with the same itemized "why."

### Transfers & withdrawals (decided)
`type = transfer` and `type = atm` **reduce the balance** (cash left the account) but are
**excluded from the Seasonal Estimator's learning set**, so a one-off transfer/withdrawal never
inflates a future month's expected-spend estimate. They still appear in the transactions list
and the cash-flow math.

**ATM / untracked cash treatment.**
- ATM withdrawals are `untrackedCash` forecast events when they occur after the anchor; pre-anchor
  ATM withdrawals are already reflected in the anchor.
- The app never auto-splits ATM cash into groceries/travel/etc. without user-entered cash expenses.
  It shows a coverage caveat instead: "₹X cash withdrawn; cash spending category is unknown."
- Product decision: for the current month, cash is shown as **spent/withdrawn so far**. The app does
  not decide whether the user spent it on groceries, travel, rent, or kept it in wallet. That is the
  user's reality, not something SMS can infer.
- Because cash usage is unknowable, ATM withdrawals do **not** automatically reduce a specific
  seasonal category. Instead, when material cash appears in the same month as remaining seasonal
  buffer, the headline separates:
  - **hard dated obligations** (must-pay, known dates), and
  - **estimated remaining discretionary buffer**, with a caveat:
    "₹X cash already withdrawn this month; if this covered planned spending, remaining buffer may
    be lower."
  This avoids pretending precision while still showing the user how much has already left the bank.
- `cashDrainRatio(window)` is defined as:
  `atm_withdrawal_paise / max(1, atm_withdrawal_paise + tracked_discretionary_bank_debit_paise)`
  over the trailing 90 days, with current-month-to-date shown separately when material.
- Starting materiality thresholds (named constants, unit-tested, tuneable after golden data):
  - no caveat below **₹5,000 ATM total** or below **10%** ratio;
  - caveat at **10–25%**;
  - cash-heavy warning above **25%**;
  - low coverage warning above **40%**.
  These thresholds do not silently change the rupee math; they change coverage messaging and
  confidence wording so heavy-cash users are not told a surplus is fully reliable.

**Non-primary account obligations.**
- `payment_account_hint` is advisory. `unknown` defaults to **subtract from the primary forecast but
  flag the line**, because silently excluding normal bills understates the required-in-bank number.
- If a matching debit is observed on the primary account, it overrides a stale secondary hint.
- If a matching debit is observed only on a secondary account, the obligation is not subtracted from
  the primary-account ledger; it appears as `out_of_primary_scope` with amount/account/action. If a
  primary-to-secondary transfer is also observed, that transfer is the primary-account cash-flow
  event and must not be counted again as the obligation.
- Learned account hints expire/re-evaluate against latest actuals; a single old payment method must
  not permanently route a bill out of the primary forecast.

**Primary-to-secondary transfer bridge.**
- When a primary-account transfer occurs near a secondary-account obligation, create a
  `transfer_bridge_candidate` using: destination account last4 or known secondary account,
  amount band (exact or ±₹50), due window (starting rule: 0–5 days before obligation debit, 0–2 days
  after), and self-transfer/own-account evidence.
- If one candidate uniquely matches one secondary obligation, the primary ledger keeps only the
  transfer as the cash-flow event; the secondary obligation is marked funded/out-of-primary-scope and
  shown for explanation, not subtracted again.
- If multiple obligations/transfers could match, do **not** auto-link. Keep the observed primary
  transfer as the dated cash-flow event and show a quantified review line: "₹X transfer may fund
  <obligation>; confirm." This avoids both silent omission and double subtraction.
- If an `unknown` account-hint obligation has a matching primary-to-secondary transfer candidate,
  the obligation is not also subtracted from primary until the candidate is resolved; the transfer
  already captures the primary cash movement.

**Self-transfer / own-account detection.**
- Maintain a local, user-editable `known_accounts` / `known_own_vpas` list seeded from salary
  account anchors, observed secondary-account anchors, manual account labels, and user-marked
  "this is my account" decisions. This stays local.
- Classify as `self_transfer` when there is strong evidence: destination account last4 matches a
  known own account, VPA matches a known own VPA, bank text indicates own-account/self transfer, or
  a transfer bridge links primary funding to a secondary obligation.
- Ambiguous repeated P2P outflows that could be own-account movement are **held for confirmation**
  instead of auto-promoted as commitments. User decisions persist as `user_confirmed` or
  `user_dismissed`.
- Wallet top-ups are treated like untracked cash coverage: cash left the bank, wallet spending is
  invisible, and the app surfaces that coverage caveat instead of learning it as normal category
  spend.

### Refunds, card statements, and partial payments

Refund/reversal handling has two separate effects that must not collapse into one:
- **Category/seasonal effect:** a matched refund reduces the original expense category and seasonal
  training amount. Cumulative refunds are capped at the original debit amount; any over-refund or
  mismatched residual becomes `needs_review`/income instead of a negative expense.
- **Cash-flow effect:** a bank-routed refund is one dated bank cash inflow on the refund posting
  date. A card-routed refund is not bank cash; it reduces the card cycle, statement total, or
  outstanding. If a bank-routed refund arrives in a later month, that later month gets the inflow;
  the earlier month's expense category is netted for learning/explainability only. This prevents
  cross-month cash double-counting, phantom cash, and cash disappearing.

Explicit reimbursements (for example employer travel reimbursement) can be linked to the original
expense with the same owner/completeness model. When linked, they reduce the seasonal/category basis
without becoming recurring income. When not linked, they remain actual income/reviewable rather than
being guessed.

Credit-card cycle treatment:
- Goal: before the bank debit happens, the user must know **"your next card bill is expected around
  ₹X due <date>; plan accordingly."**
- Each card has a `CardCycle { cardLast4, issuer, cycleStartDay, statementDay, dueDay,
  paymentAccountHint, confidence }`. It can come from Gmail/card statement, SMS bill reminders,
  repeated payment dates, or user entry. Until known, the app shows a quantified "set card billing
  cycle" coverage line instead of guessing exact due dates.
- Per-purchase card SMS updates category insight and the **current cycle estimate**:
  `cycle_spend_seen = Σ purchases in cycle - Σ card-routed refunds/credits`.
  It does **not** become an immediate bank cash-flow outflow and does **not** also become seasonal
  cash allocation.
- The bank cash-flow ledger counts card usage exactly once: an estimated or actual
  `cardStatement` event on the expected payment date. When an actual statement/Gmail bill arrives,
  it replaces the estimate. When the payment debit arrives, it reconciles to that statement event
  and is not counted as a second expense.
- If an actual card-payment bank debit is observed for the same statement cycle after the anchor,
  that debit becomes the single dated bank-cash event and the expected statement line becomes
  `reconciled`. If the debit is already before or on the anchor, both statement/payment cash is
  `anchor_included`. Per-purchase card SMS remains card-cycle/category evidence in both cases.
  Statement/payment matching may use an explicit match key or the card-cycle identity; it must not
  depend on merchant text alone.
- If per-purchase card SMS coverage is partial, use:
  `statement_residual = statement_total - Σ observed_purchases_in_cycle + Σ observed_card_refunds`
  as an uncategorized/residual card amount, not a second full statement on top of observed
  purchases.
- If no per-purchase card SMS exists for a cycle, the statement/payment amount becomes the only card
  spend proxy for that cycle and may train category only as `uncategorized_card` unless Gmail/manual
  category detail exists.
- Partial payment stores `amount_paid_paise`, `outstanding_paise`, and `payment_status=partial`.
  The outstanding is carried into the **next statement reconciliation**, not added twice. If the
  next statement is unavailable, the outstanding appears as a quantified coverage line with
  expected interest/fees marked unknown; the user sees it before treating surplus as free.
- Refund routing matters: a bank-routed refund is a dated bank cash inflow; a card-routed refund
  reduces `cycle_spend_seen`, statement total, or outstanding. It is never a phantom bank inflow.

### Annual/quarterly obligations and P2P/UPI recurrence

**Known but unscheduled annual/quarterly obligations.** Excluding unknown due dates from the dated
ledger is correct, but the amount remains visible beside the headline:

```
Dated forecast: ₹20,000 extra
Known unscheduled obligations: ₹47,000 need due month
```

If recurrence is supported by a locked cadence (`next_expected_source=locked_cadence`), the next
due month is not guessed and may be included at lower confidence. If there is no reliable date
source, the item stays out of dated totals but appears as a quantified `unscheduled_obligation`
coverage line with "set due month" action. Stale/cancelled annual heads-up lines expire or require
refresh after a defined inactivity window (starting rule: annual >15 months without evidence).

**P2P/UPI recurrence.**
- VPA is a signal, not the identity key. Matching also uses normalized payee text, amount/cadence
  band, account, references, and user decisions.
- Self-transfers and own-wallet movements are excluded before any recurring income/outflow
  promotion.
- P2P **outflows** are safety-biased: high-evidence recurring debits to an individual VPA (for
  example rent/help/support) become included-and-dismissable or quantified coverage lines, not
  silent omissions. P2P individual streams require stronger evidence than merchant streams
  (starting rule: ≥4 occurrences or user confirmation) and can be marked
  `user_confirmed`/`user_dismissed`.
- P2P **income** is not safety-biased the same way: it requires confirmation or strong non-self
  evidence before becoming recurring expected income, because over-counting income creates a false
  surplus.
- Variable recurring P2P amounts are allowed as lower-confidence commitments using median/last
  amount bands; amount variation alone is not enough to discard a real recurring outflow.

### Forward earmark (keep "extra" honest) — seed of the Planner
A surplus is shown, but to serve the "relaxed *because aware*" goal it is accompanied by a
**heads-up line for large obligations beyond the next month** (e.g. "₹47,000 insurance premium
due in Feb") so the user doesn't treat earmarked money as free. Lightweight in v1; the annual
recurring commitments and Gmail-dated bills already give us the data.

This heads-up is the **seed of the Spec 2 Planner** (§13): the full version turns each future
lump into a **sinking fund** ("set aside ₹7,834/month for 6 months") and splits the balance into
**free vs earmarked**. To keep Spec 1 planner-ready, the `ForecastLine` breakdown already tags
each obligation with its **due month**, so future set-aside math needs no data-model change.

### Explainable "why" log (first-class)
Every figure is backed by a drill-down list. Tapping the headline (or any category) reveals the
exact contributors:
- each **recurring commitment** (e.g. "SIP – Index Fund ₹10,000 · monthly · auto-debit ~2nd"),
- each **known bill** (e.g. "LIC premium ₹47,000 · due 14th"),
- the **seasonal estimate** broken down by category with its confidence (e.g. "Groceries
  ₹9,500 — based on last year + 3-mo avg, medium confidence"),
- each dated inflow/outflow that creates the minimum-balance point,
- each current-month expected item marked **paid**, **unpaid**, or **overdue**,
- each **already-spent** transaction that is shown for traceability but not subtracted twice,
- each quantified coverage line: stale anchor, untracked cash, out-of-primary-scope payment,
  outstanding card amount, unscheduled annual/quarterly obligation, and review-pending P2P stream.

The model is: **no number without a traceable reason.** Data structures carry their line-item
breakdown (`List<ForecastLine>` with `{label, amount, source, date, ownerKey, status, confidence}`)
so the UI can render the log without recomputation.

### UI changes
- **Home** — headline recommendation card: "You need **₹X more by Aug 2**" when the dated ledger
  dips negative, or "For *August* you're projected to have **₹X extra**" when it does not. Includes
  a "**See why**" affordance opening the itemized log, anchor source/staleness, and salary
  breakdown strip (committed / expected / free). Live mode only.
- **Why-log screen/sheet** — the itemized breakdown described above; every line tappable to its
  source (a transaction, a bill, or the seasonal basis).
- **Transactions tab** — in live mode, real SMS + manual transactions grouped by day
  (replaces demo data; **sample mode keeps the demo list unchanged**).
- **Insights** — per-category **expected-vs-actual** for the current month, and a **same-month
  historical** comparison ("this month last year vs now").

### Honesty when history is thin
When the Seasonal Estimator lacks same-month-prior-year data, the recommendation states its
confidence and leans on recurring + bills, explicitly labeling the discretionary estimate as
provisional. The number is never presented as more certain than the data supports.
