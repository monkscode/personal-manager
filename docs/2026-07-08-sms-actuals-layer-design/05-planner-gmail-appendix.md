# SMS Actuals Layer - Planner and Gmail Appendix

> Split from docs\2026-07-08-sms-actuals-layer-design.md on 2026-07-09.
> Approximate context budget target: keep each implementation file under 300k characters.
> Read docs\2026-07-08-sms-actuals-layer-design.md first for the split index and implementation order.

**Original line range:** 1207-1308
**Contains:** Future planner relationship and Gmail parsing appendix

---

## 13. Relationship to the year-round Planner (Spec 2 — future, not built here)

Spec 1 is the foundation; the **Planner** is a separate brainstorm/spec built on top. Captured
here only so Spec 1 stays compatible — **none of this is implemented in Spec 1.**

**Planner scope (Spec 2):**
- **Sinking funds** for lumpy obligations — target ÷ months-to-due = monthly set-aside; roll all
  active funds into one "set aside ₹X/month" with progress tracking. (Generalizes the *mechanic*
  of the existing FD round-off plan — not its FD-reinvestment framing; see deprioritized note.)
- **Savings goals** with deadlines — PPF ₹1.5L by Mar 31 (80C), NPS 80CCD(1B) ₹50k, post-office
  schemes. Generic user-defined targets first; **built-in instrument templates** (caps,
  deadlines, rates) later. (Generalizes the existing NPS/PPF/MF onboarding.)

**Deprioritized / out of scope (decided):** **FD reinvestment & renewal advisory** — "reinvest
your maturing FD," "reserve money to renew the FD at ₹2L," etc. This is wealth-optimization
*advice* (different domain, data-starved, advisory risk), off the obligation-prep north star. The
existing FD round-off card is already sample-mode-only and will not appear in the live planner.
Note: a detected **FD-maturity credit** is still valid as a plain **inflow** into the rolling
balance — data, not a recommendation.
- **Free vs earmarked balance** — the app never moves money, so "set aside" is earmarking within
  the same balance; the balance splits into free vs reserved so surplus is never overstated.
- **Feasibility / waterfall** — when salary can't cover obligations + goals + expected spend, the
  planner prioritizes (must-pay obligations → deadline tax-goals → discretionary → optional
  goals) and shows the gap honestly rather than only happy paths.
- **Yearly timeline + monthly action list** — "what's coming this year" and "what to do this
  month," a rolling monthly re-plan (not a fixed annual budget, since forecast error compounds).

**Why Spec 1 is already compatible:** the existing app already has a 12-month display surface, but
Spec 1 replaces the underlying month-bucket math with a dated cash-flow ledger and rolling
carry-forward balance (today's balance math is only two-state: current month = actual balance,
next month = `balance + salary − thisMonthRequired`; there is no
`OpeningBalance(M)=closing(M−1)` loop yet — see §7). Obligations carry a **due month/date**;
`RecurringCommitment` + `ForecastLine` are reused directly by the planner; the balance model can
later add a free/earmarked split on top of the same event ledger; salary and recurring detection
feed goal/feasibility math.

**Planner-specific risks to resolve at Spec 2 brainstorm:** earmark accounting vs real transfers;
prioritization/waterfall rules; instrument-rule accuracy (tax caps/deadlines); compounding
12-month forecast error; feasibility messaging when the plan can't be funded.

## 14. Gmail email parsing — findings, applied fix & hardening (live debug 2026-07-08)

Captured here so the email-extraction logic is reviewable and can be worked on further. This is
the **existing Gmail path** (separate from the SMS Spec 1 above), debugged live against a real
inbox.

### What we observed
Instrumented the scan pipeline; ran against a real Gmail account (40 messages, Gemini
`gemini-2.5-flash`):
- Gmail fetch and the Gemini call both **succeeded** (HTTP 200) — not a network/auth/key issue.
- Of 40 fetched emails only ~2 were real upcoming bills ("Payment Reminder" → Gas, Mobile
  Postpaid); the rest were job alerts, newsletters, SIP/portfolio confirmations and promos — all
  correctly rejected by the AI.
- The 2 real bills returned `isBill:true` but **`amount:0`**, because body extraction returned a
  130/142-char `text/plain` **stub** with no amount while the figure lived in the richer
  `text/html` part we discarded.
- Code then **dropped every bill with `amount < 1`** → user saw "nothing found."

### Root cause (two compounding bugs)
1. `_extractBody` preferred `text/plain` unconditionally → a short stub hid the amount in the
   HTML part.
2. `mapItems` silently dropped amountless bills → real, correctly-classified bills vanished.

### Fix applied (this change set)

> **Status / where this lives:** these fixes are in the **working tree** (uncommitted vs
> `a1f2137`). A clean checkout still shows the pre-fix code, so any review must be grounded
> against the working tree — commit these changes so this section stays reproducible.

- **`_extractBody` now picks the richer part** (max of plain vs stripped-HTML length). Verified:
  the two reminders went 130→498 and 142→511 chars and the model then extracted the amounts —
  **2 bills with amounts vs 0 before**.
- **Keep amountless bills** (`mapItems` no longer drops `amount==0`; 0 = "not detected").
- **Rule-based amount backstop** (`GmailService._recoverAmounts`): when the AI returns no amount,
  `EmailParser.extractAmount` tries to recover it from the source email.
- **Wider AI window** (email body clip 1500→4000) + **sharper prompt** (scan the whole email for
  the exact payable amount; never fabricate; still return the bill with amount 0 if truly absent).
- **"Set amount" review UI**: amountless bills show a tappable amber chip to enter the figure
  instead of a misleading ₹0; the entered value flows into the confirmed obligation.
- **Still pending for the non-AI rules path:** `EmailParser.parseOne` currently rejects
  amountless bill-like emails. It must keep **high-confidence amountless reminders** for review
  while still rejecting low-confidence noise.

### Confirmed learnings (design-level)
- **Indian bill *reminder* emails frequently omit the amount** (behind a login / in a PDF / only
  in SMS). No email parser can extract a number that isn't in the text. → **Email = what's due +
  when; SMS = the precise amount + balance.**
- HTML-part extraction quality matters more than regex cleverness for email.
- Most of a real inbox is non-bill noise; an AI `isBill` classifier is essential and precision
  must come from a structural test, not keyword lists.

### To apply next (research-backed; not yet implemented)
- Port the `transaction-sms-parser` **normalize → tokenize → token-adjacency amount** (§6) into
  `EmailParser.extractAmount`, replacing the greedy currency regex that produced false hits (e.g.
  "₹10 Lakhs" inside a loan promo).
- Change the non-AI `EmailParser` gate so a strong sender/due-date/bill signal with no amount is
  returned as `amount_status=missing` / amount `0` for review, matching the AI path.
- Add the **2-of-N validity guardrail** (§6) to the SMS parser as the primary "no false data"
  filter.
- Tighten the Gmail search query (currently broad `newer_than:6m (due OR premium OR …)`) and/or
  add a pre-AI sender/keyword prefilter — this scan sent ~59k prompt tokens, mostly noise, so a
  prefilter cuts cost and further reduces false positives.
