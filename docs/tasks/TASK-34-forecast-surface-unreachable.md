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

Everything the forecast layer produces is reached through that one card. Traced across
`lib/`, each of these appears in exactly one rendered place, and that place is inside
`_recommendationCard` or the `_freshnessChip` it calls:

| Output | Only site |
|---|---|
| `forecastHeadline` (as content) | `home_screen.dart:491` |
| `salaryCommitted` / `salaryExpected` / `salaryFree` | `home_screen.dart:503-511` |
| `anchorProvisional` | `home_screen.dart:573` (`_freshnessChip`, called from :486) |
| `anchorConfirmLabel` | `home_screen.dart:576-578` |
| `forecastLines`, `forwardEarmarks`, `coverageLines` | `home_screen.dart:538-541` |

`home_screen.dart:538` is also the **only** navigation site for `WhyLogScreen` anywhere in
`lib/`. So the why-log — the screen whose entire purpose is to name what was excluded and
why — has no route to it in the state the app is actually in.

`insights_screen.dart:20` touches `forecastHeadline` only as an `isEmpty` empty-state
guard, never as content.

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

## Tests to write first

- [ ] A live-mode Home (`forecastExplorer != null`) with a non-empty `coverageLines`
      renders at least one of them, or an affordance that opens them. Must fail now.
- [ ] A live-mode Home renders `forecastHeadline`, not just the insights spend summary.
- [ ] With an evidence-free anchor, live-mode Home shows the provisional marker
      (TASK-22's `isProvisional` reaching a pixel).
- [ ] Whichever widget is deleted, no orphan remains: assert `HomeForecastExplorer` is
      either constructed in `lib/` or gone.

## Definition of done

- [ ] One forecast surface, reachable on the live SMS path
- [ ] Coverage lines visible to the user in that surface
- [ ] The unused widget removed, or wired up
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Render the forecast surface on the live SMS path`

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
