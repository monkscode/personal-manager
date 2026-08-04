# TASK-34 — The whole forecast surface is unreachable on the live SMS path

**Severity:** Critical · **Phase:** 3 (found during Phase-3 device verification) ·
**Depends on:** nothing

Found on 2026-08-03 by installing the Phase-3 build on the device and looking for the
coverage lines the phase had just added. They are all computed correctly. None of them can
be reached.

---

## The defect

`lib/features/app/home_screen.dart:156`

```dart
if (i.forecastExplorer != null) ...[
  _spendSummaryCard(context, i, ctrl),
  ...
] else ...[
  if (liveForecast) ...[
    _recommendationCard(context, i),
  ],
  // hero card, balance check, ...
],
```

`_recommendationCard` (`home_screen.dart:446-571`) is the **only** widget that renders any
part of `ForecastOutlook`, and it is in the branch taken when `forecastExplorer` is
**null**. On the live SMS path `real_insights.dart:1009` always populates it, so that
branch is never taken and the card never renders.

> **Corrected 2026-08-04 — the card is dead in *every* state, not only the live one.**
> `forecastHeadline` is written at exactly one site (`real_insights.dart:1002`), inside
> `_forecastInsights`, which also always sets `forecastExplorer` (`:1009`). The only other
> `Insights` producer (`real_insights.dart:364`, the manual/sample path) sets neither, so
> both default to `''` / `null`. `liveForecast` (`home_screen.dart:32`) and
> `forecastExplorer != null` are therefore the **same condition** in production, and
> `if (liveForecast)` nested inside the `forecastExplorer == null` branch is unsatisfiable.
> Rendering the card required two different `Insights` producers, and there is only one.
> The hero card and balance check beside it are fine — they render for manual users.

Everything the forecast layer produces is reached through that one card. Traced across
`lib/`, each of these appears in exactly one rendered place, and that place is inside
`_recommendationCard` or the `_freshnessChip` it calls:

| Output | Only site | Verified 2026-08-04 |
|---|---|---|
| `forecastHeadline` (as content) | `home_screen.dart:491` | **Wrong — also reachable** (see below) |
| `salaryCommitted` / `salaryExpected` / `salaryFree` | `home_screen.dart:503-511` | Confirmed |
| `anchorProvisional` | `home_screen.dart:573` (`_freshnessChip`, called from :486) | The *chip* only; the marker itself was reachable |
| `anchorConfirmLabel` | `home_screen.dart:576-578` | Confirmed |
| `anchorAsOfLabel` | `home_screen.dart:526` | Confirmed |
| `forecastLines`, `coverageLines` | `home_screen.dart:538-541` | Confirmed |
| `forwardEarmarks` | `home_screen.dart:540` | **Wrong — also reachable** (see below) |

`home_screen.dart:538` is also the **only** navigation site for `WhyLogScreen` anywhere in
`lib/`. So the why-log — the screen whose entire purpose is to name what was excluded and
why — has no route to it in the state the app is actually in. That part is exactly right,
and it is the whole severity of this task.

`insights_screen.dart:20` touches `forecastHeadline` only as an `isEmpty` empty-state
guard, never as content. Confirmed.

### Corrected premise — the headline and the provisional marker already reach the user

Found by writing the "must fail now" test for the headline and watching it **pass**.

`real_insights.dart:807-815` copies `outlook.headline` verbatim into `alerts.first.text`,
and `home_screen.dart:236` renders `i.alerts.take(2)` as insight cards **outside** the
`if`/`else` — so on the live path. `insights_screen.dart:321` renders all of them. Since
`_headline` prefixes `'Provisional — confirm your balance. '` whenever the anchor is
provisional (`forecast_adapter.dart:920-922`), the TASK-22 provisional marker rides along
with it.

`real_insights.dart:816-825` does the same for `forwardEarmarks`, one alert card each.

So three of this file's "only site" claims were wrong, and two of its four proposed tests
("renders `forecastHeadline`", "shows the provisional marker") were already satisfied.
What is genuinely unreachable is narrower and worse: **the why-log route, the coverage
lines, the salary strip and the anchor provenance.** Coverage lines are what name an
exclusion, so "no silent exclusion" is still breached — a headline that says you have a
surplus, with no way to see what was left out of it, is the failure mode the invariant
exists to prevent.

### Second unreachable channel — nothing can write a reserve or a risk decision

Not in the original finding. `TransactionsNotifier.updateReserveProgress`
(`transactions_notifier.dart:85`) and `.saveRiskDecision` (`:104`) have **zero callers in
`lib/`** — only tests. `HomeForecastExplorer` is their only intended caller, and it is
never built. Consequences, all of the same shape as TASK-13 and TASK-24 M7:

- No obligation can ever be enabled for a reserve, so `ReservePlan.schedules` is
  permanently empty in production and the whole `ReservePlanner` output is candidates-only.
- `forecast_risk_decisions` is never written, so `snapshot.riskDecisions` is always empty
  and `ForecastAdapter`'s confirmed/dismissed branches (`:172`, `:685-696`) are
  unreachable from `lib/`.

This is the strongest argument for wiring the explorer rather than deleting it: it is the
only surface that reaches either.

### The code contradicts its own test

`home_screen.dart:154` comments that the explorer "replaces old recommendation, hero, and
balance-check surfaces". `test/home_screen_test.dart:202` asserted the opposite — *"The
forecast explorer and its sections were removed from Home"*, requiring
`find.textContaining('See why')` to find nothing in live mode. Both arrived in the same
imported commit (`04bef7a`, "work developed on a second machine"), so git history does not
settle which was intended. It had to be decided, not derived.

### The replacement was never wired up

The comment above the branch says the explorer "replaces old recommendation, hero, and
balance-check surfaces". It does not: **`HomeForecastExplorer` is never instantiated
anywhere in `lib/`.** The only uses of `forecastExplorer` outside its own file are the
field declaration (`insights.dart:266,323`), the assignment (`real_insights.dart:1009`),
and the null check above. The widget file's own `plan.coverageLines` reference
(`home_forecast_explorer.dart:75`) is inside `_hasEvidence`, a boolean emptiness test —
coverage lines are never rendered as content even there.

So `forecastExplorer` functions purely as a flag that switches the forecast surface off.
Same shape as TASK-13's unreachable `CardCycle` and TASK-24 M7's unreachable card branch.

## Why this matters more than a missing card

It breaks the spec invariant the whole plan is measured against:

> **No silent exclusion.** The forecast may not silently drop a material known amount and
> still show a confident surplus. Anything excluded must produce a coverage line naming
> what was excluded and why.

The coverage line is produced. It is simply never shown. Every phase of this plan has been
adding lines into a channel with no outlet:

- TASK-21 `discretionaryNotModelled` — the omission it exists to name.
- TASK-22 `noBalanceEvidence`, and the "Provisional — confirm your balance" headline
  prefix, and `anchorConfirmLabel`.
- TASK-23 `duplicateSuppressed` — the ambiguous horizon join routed to review.
- TASK-24 M11 `pastDueObligation` — money already owed, with its new review action.
- Everything earlier: `untrackedCash`, `possiblyAlreadyPaid`, `staleAnchor`,
  `outOfPrimaryScope`, `reviewNeeded`.

What the user sees instead is `_spendSummaryCard`, which is built from the **insights**
layer, not the forecast ledger. On this device it reads *"Need for September ₹4,10,216"*
with no headline, no provisional marker, no anchor provenance and no coverage — see the
observation below for what is inside that number.

## Why no test caught it

`test/home_screen_test.dart` and `test/why_log_screen_test.dart` both exist and pass.
`why_log_screen_test.dart` renders `WhyLogScreen` **directly**, so it proves the screen
draws its lines correctly while saying nothing about whether anything can push it. That is
the gap: no test asserts that a live-mode Home containing coverage lines offers a route to
them.

## Fix

Decide which surface is the real one, then make the code say it:

- **If the embedded explorer is the intended replacement**, instantiate
  `HomeForecastExplorer` in the `forecastExplorer != null` branch and render coverage lines
  inside it. It already receives them.
- **If the recommendation card is still the surface**, drop the branch — render it on the
  live path too — and delete `home_forecast_explorer.dart` rather than leaving a widget
  nothing builds.

Either way the headline, the provisional marker and the coverage lines must be reachable on
the live SMS path.

### Decision taken 2026-08-04 — wire up the explorer

One fact settles it rather than taste. Coverage lines are computed **per horizon month**:
`forecast_ledger_engine.dart:44-47` merges `horizonCoverageLines[offset]` into each month,
and its own comment names the reason — *"the per-month channel future months previously had
no access to at all, which is why an omission in month 7 could not be reported anywhere
(TASK-21)"*. But `ForecastOutlook.coverageLines` is `month0.coverageLines` alone
(`forecast_adapter.dart:243`), and that is what `Insights.coverageLines` carries.

So the recommendation card can only ever open a **month-0** why-log. Restoring it would
have left months 1-11 — precisely the 11 months TASK-21 exists to fix — with no outlet,
and `_discretionaryCoverage` (`forecast_adapter.dart:453-482`) emits a line for *every*
unmodelled horizon month. Only `ForecastMonthPlan.coverageLines` reaches them, and only the
explorer's per-month "See why" reaches that. The recommendation card was not a smaller fix;
it was an incomplete one.

Supporting reasons: the explorer is the only surface that can reach the reserve and risk
channels above, and the product answers "how much do I need in the bank for any upcoming
month" — plural, which one card cannot express.

## Tests to write first

- [x] A live-mode Home (`forecastExplorer != null`) with a non-empty `coverageLines`
      renders at least one of them, or an affordance that opens them. Must fail now.
      RED: `Bad state: No element` — `find.textContaining('See why')` matched nothing to
      make visible. GREEN: tapping it pushes `WhyLogScreen` showing
      `coverageLines.first.label`.
- [x] A live-mode Home renders `forecastHeadline`, not just the insights spend summary.
      **Labelled a guard, not regression coverage** — it passed before the fix, via
      `alerts.first.text` (see the corrected premise above). Kept, with the scroll the
      taller Home now needs, so the one surviving route cannot be removed unnoticed.
- [x] With an evidence-free anchor, live-mode Home shows the provisional marker
      (TASK-22's `isProvisional` reaching a pixel). Rewritten to assert the marker is on
      the forecast surface itself (`find.descendant(of: HomeForecastExplorer)`), because
      the headline alert already carried the word. RED: *"Found 0 widgets with text
      containing Provisional descending from HomeForecastExplorer"*.
- [x] Whichever widget is deleted, no orphan remains: assert `HomeForecastExplorer` is
      either constructed in `lib/` or gone. RED: *"Found 0 widgets with type
      HomeForecastExplorer"*. `_recommendationCard` and `_freshnessChip` are deleted.

Four more added, each failing first:

- [x] Live Home names the balance the forecast opens on. RED: *"Found 0 widgets with text
      containing as of 1 Aug · 1234"*.
- [x] Live Home renders the committed / expected / free strip. RED: *"Found 0 widgets with
      text ₹85,000"*.
- [x] **A future month's coverage line is reachable (TASK-21).** Selects "Next month", opens
      its why-log, and asserts the screen's own month title — both months label the omission
      identically, so the title is what proves the future month opened. RED: `Bad state: No
      element`.
- [x] A reserve action from Home reaches the persistence layer: tapping "Start reserve"
      with no database surfaces the store's own `StateError` as a snackbar. An unwired
      callback would say nothing. RED: `Bad state: No element` — no "Start reserve" existed.

## Definition of done

- [x] One forecast surface, reachable on the live SMS path
- [x] Coverage lines visible to the user in that surface
- [x] The unused widget removed, or wired up
- [x] `flutter analyze` clean, `flutter test` green — **863 passing** (855 before)
- [x] Suggested commit: `Render the forecast surface on the live SMS path`

## What landed

`_forecastExplorer` (`home_screen.dart`) builds `HomeForecastExplorer` in the live branch,
below the spend summary, with `embedded: true`. Its three callbacks are wired to the real
stores: `onUpdateReserve` and `onSaveRiskDecision` to `TransactionsNotifier`, `onSeeWhy` to
`WhyLogScreen`. `_recommendationCard` and `_freshnessChip` are gone.

The month-0 why-log passes `Insights.forecastLines` and `forwardEarmarks` — the reconciled
line set, including paid and already-in-anchor rows. A future month has no actuals to
reconcile against, so it passes `plan.hardLines`. Both pass `plan.coverageLines`,
`plan.riskLines` and `plan.reserveSchedules`.

`HomeForecastExplorer` gained four optional string parameters — `anchorLabel`,
`committedLabel`, `expectedLabel`, `freeLabel` — rendered in `_ActionHeader`. They carry
the four outputs the deleted card was the only site for. Defaulted to `''`, so the existing
1,513-line widget test file needed no change.

### Decisions recorded

- **The explorer sits below the spend summary, not above it.** Placing it first was tried
  and measured: the explorer is ~600px tall, and in an 800×600 test viewport it pushed
  "Spent this month" and the alert cards out of the `ListView`'s build window entirely.
  Summary first, then the 12-month tool, is progressive disclosure and leaves the existing
  live layout intact.
- **The headline is deliberately *not* repeated in the explorer header.** It already
  renders as `alerts.first`, and printing the same sentence twice on one screen is worse
  than leaving the header to state the plan in its own words.
- **`anchorConfirmLabel` is now rendered nowhere, by decision.** It is a pure derivation of
  `isProvisional` (`isProvisional ? 'Confirm balance' : ''`), and `_ActionHeader` already
  states the same thing. The honest options are to render it or delete it; deleting a
  required `ForecastOutlook` field across ~20 test call sites is not this task's job. It
  names no amount and no exclusion, so nothing user-visible is lost — but it is a string
  the model computes for nobody, and it should be deleted when that file is next opened.
- **"Provisional — confirm your balance" now appears twice on live Home** — once in the
  headline alert, once in `_ActionHeader` beside the number it qualifies. Cosmetic
  duplication, left alone: removing the headline alert is a product decision beyond this
  task.

---

## Device verification, 2026-08-04

Installed with `adb install -r` (database preserved, nothing rescanned — this is a UI-only
change, so stored rows are untouched by construction). Samsung SM-G781B, 1080×2400.

Everything below reached a real pixel for the first time:

- **The plan band.** *"Your plan now ₹1,999 / until 28 Aug / as of 4 Aug"* with the
  Committed ₹1,999 · Expected ₹0 · Free ₹98,001 strip. The anchor provenance line is the
  `anchorAsOfLabel` that had no render site.
- **The 12-month chart and month detail.** "August plan" → Required in bank, Lowest balance
  ₹98,001 on 28 Aug, Reserve, Unconfirmed risk, Confidence 30%.
- **The why-log route.** "See why August requires ₹1,999" opens *"Why August looks like
  this"*. TASK-24 M11's six past-due obligations are all there and marked **Overdue** —
  `unnamed mandate`, `axis bank cc`, `phonepe`, `bharat connect postpaid bill payment`,
  `google`, `google asia pacific pte.ltd` — exactly the six this file predicted.
- **Coverage lines.** August's *"Everyday spending not included — ₹1,17,462"* under NEEDS
  YOUR ATTENTION, alongside a run of `possiblyAlreadyPaid` lines.
- **The per-month route, which is the whole reason the explorer won.** Selecting "Next
  month" opens *"Why September looks like this"*, whose NEEDS YOUR ATTENTION section holds
  **"Everyday spending not included — ₹3,09,274"** (TASK-21, month 1) and **"'Hdfc Bank Ltd'
  looks like the same commitment as 'Hdfc Bank Ltd mandate' — counted once" — ₹61,415**
  (TASK-23's `duplicateSuppressed`). `Insights.coverageLines` carries August's alone, so
  the recommendation card could not have shown either. Decision vindicated on real data.

### What the newly-reachable surface exposed — no task file yet

These are only visible *because* the surface now renders. None is caused by this change.

1. **`riskBufferPaise` sums inflows into "Unconfirmed risk".** August's risk list contains
   `Salary ₹1,51,556` and the total reads ₹2,73,425 (September: ₹5,22,364). Verified in
   source, not inferred: `ForecastLine` has **no direction field**
   (`forecast_models.dart:189-217`), `forecast_adapter.dart:176-179` routes *any* weak
   candidate event to `riskLines` regardless of direction, and
   `forecast_explorer.dart:143-146` folds them with `sum + line.amountPaise` and no filter.
   So an uncertain *credit* is presented to the user as money that might have to go out.
   Direction-blind, and material at ₹1.5 lakh. **The most serious of the four.**
2. **Opaque hashes rendered as commitment labels.** `xfkxfma537eoyvuzwkvss3vbvbr1oxoo`
   (₹1,999, 28 Aug) and `ece9ae70c53842d58abf92660f4698af` (₹120, 29 Aug) appear as
   why-log lines, and the first is September's top entry under **Drivers**. Both carry the
   same amounts as named commitments (`google` / `google asia pacific pte.ltd` ₹1,999;
   `phonepe` ₹120), so they are plausibly the same obligations under an unresolved key —
   a duplicate-count risk as well as an unreadable label. Distinct from TASK-33's
   merchant-capture family: this is an internal identifier surfacing as a user-facing name.
3. **The `discretionaryNotModelled` coverage tile prints its label twice** — title
   *"Everyday spending not included"* and subtitle *"Everyday spending not included ·
   Review"* — because `forecast_adapter.dart:472` and `why_log_screen.dart:511` chose the
   same wording independently. Cosmetic, one line to fix either side.
4. **The floating "+" button overlaps the Free value** in the new strip on a 1080-wide
   screen. Pre-existing FAB, newly colliding with content.

---

## Device observations recorded at the same time

Not part of this task; recorded so they are not re-derived. Measured against the 2,058-row
device database on 2026-08-03.

**A near-cancelling seasonal pair inflates September.** The Insights screen shows
*"Seasonal · last September ₹2,91,946"* against *"Extra income · last September
₹2,92,216"* — a difference of ₹270 on figures near ₹2.9 lakh. September 2025 holds 8
credits totalling ₹5,96,937 and 41 debits totalling ₹4,36,984, and its largest rows show
why:

| Direction | Amount | Stored merchant |
|---|---|---|
| credit | ₹2,24,505 | `clearing` |
| credit | ₹1,32,857 | `clearing` |
| credit | ₹1,10,667 | `05:31:47 ist` |
| debit | ₹1,00,000 | `a/c **0306 (upi` |
| debit | ₹63,600 | `austra` |
| credit | ₹63,600 | *(null)* |
| debit | ₹61,415 | `hdfc ltd` |
| debit | ₹61,415 | `hdfc bank ltd` |

Three things in one table, all extending findings already on file:

1. **A timestamp captured as a merchant** (`05:31:47 ist`, ₹1,10,667) — a new instance of
   TASK-33's merchant-capture class, not previously seen.
2. **A ₹63,600 debit and a ₹63,600 credit** that are almost certainly one transfer counted
   on both sides — the credit has no merchant at all, so nothing can join them.
3. **The same ₹61,415 mandate debit stored twice** under `hdfc ltd` and `hdfc bank ltd`.
   TASK-23 now collapses spellings like this in the *horizon* join, but stored rows are
   untouched — this is a reconciliation-layer duplicate, and it is the same ₹61,415 HDFC
   mandate that TASK-32 dealt with.

**TASK-22 is not exercised on this device.** 393 rows carry a `balance_paise` reading, the
newest dated 2026-07-31 (₹1,63,901.18, account 7106). Against a `now` of 2026-08-03 that
anchor is 3 days old — `AnchorFreshness.amber`, `hasEvidence == true`. So the fabricated
zero anchor, the `noBalanceEvidence` line and the forced-provisional path never fire here.
They matter for a user with no bank-balance SMS. Correct, and untested in the field.

**TASK-24 M11 has six live subjects.** Of nine stored obligations, six are due before
2026-08 and unpaid, so they now classify as `pastDueObligation` with a review action rather
than `futureEarmark` with none: `unnamed mandate` (2018-10-31), `axis bank cc`
(2022-10-04), `phonepe` (2025-08-28), `bharat connect postpaid bill payment` (2026-02-03),
`google` (2026-04-27), `google asia pacific pte.ltd` (2026-07-10). None of it is visible
until TASK-34 is fixed.
