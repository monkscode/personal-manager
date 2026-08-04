# TASK-38 — Forecast-surface cleanups

**Severity:** Minor · **Phase:** 5 · **Depends on:** TASK-34

Findings 3 and 4 from the end of TASK-34, plus the `anchorConfirmLabel` render-or-delete
decision recorded in the same file. Grouped because each is a few lines and none changes
any monetary value.

| Item | Outcome |
|---|---|
| F3 — the `discretionaryNotModelled` tile prints its label twice | **Fixed** |
| `Insights.anchorConfirmLabel` rendered nowhere | **Deleted** (29 sites) |
| F4 — the floating `+` overlaps the "Free" value | **Fixed** — dropped from Home |

---

## F3 — a coverage tile printed its label twice

`_coverageTile` (`why_log_screen.dart:162-199`) renders the line's own label as the title
and the *reason* beneath it:

```dart
Text(c.label),                                   // 'Everyday spending not included'
Text(action.isEmpty
    ? _reasonLabel(c.reason)
    : '${_reasonLabel(c.reason)} · $action'),    // '...not included · Review'
```

`forecast_adapter.dart:472` and `why_log_screen.dart:511` had independently chosen the
same wording, so the tile read *"Everyday spending not included"* directly above
*"Everyday spending not included · Review"*.

**Fixed on the reason side, not the label side.** Every other entry in `_reasonLabel` is a
terse reason — `'Past due'`, `'May already be paid'`, `'Counted once, under another name'`
— and `discretionaryNotModelled` was the only one restating its own title. The label at
`forecast_adapter.dart:472` is the user-facing sentence naming the omission and is the
right thing to keep verbatim.

```dart
CoverageReason.discretionaryNotModelled => 'Not modelled for this month',
```

### Tests — `test/why_log_screen_test.dart`, group `TASK-38`

| Test | Kind | RED symptom |
|---|---|---|
| `the discretionary tile says the words once` | Regression | `Expected: exactly one matching candidate` / `Actual: Found 2 widgets with text containing 'Everyday spending not included'` |
| `and still explains itself in the subtitle` | **Guard** | Passed before the fix — the old subtitle also contained `· Review`. It is here so the repetition cannot be "fixed" by deleting the subtitle outright. |

---

## `anchorConfirmLabel` — deleted

TASK-34 left this open as render-or-delete. **Deleted**, across 29 sites (6 in `lib`,
23 in `test`).

It was a pure derivation of `isProvisional`
(`anchorConfirmLabel: isProvisional ? 'Confirm balance' : ''`) that reached no widget in
`lib/`. The decision turned on one check rather than taste: the message it carried is
already rendered **twice** and is already tested —

- `home_forecast_explorer.dart:458` — `'Provisional — confirm your balance'` in `_ActionHeader`
- `forecast_adapter.dart:922` — the same sentence inside the headline, rendered via `alerts`
- `test/home_forecast_explorer_test.dart:1180` asserts it reaches the user

so rendering `anchorConfirmLabel` would have made a **third** copy of one sentence on one
screen, when TASK-34 already recorded the existing duplication as more than enough.
Nothing user-facing was lost.

**No coverage was lost either.** All four test assertions that referenced it sat directly
beneath an assertion on `isProvisional` / `anchorProvisional` carrying the identical
signal, so each was strictly redundant:

| File | Line above the deleted assertion |
|---|---|
| `forecast_adapter_test.dart:287` | `expect(outlook.isProvisional, isTrue)` |
| `forecast_adapter_test.dart:1665` | `expect(outlook.isProvisional, isTrue)` |
| `forecast_insights_integration_test.dart:179` | `expect(i.anchorProvisional, isTrue)` |
| `sms_end_to_end_test.dart:201` | `expect(outlook.isProvisional, isTrue)` |

The remaining 19 sites were `anchorConfirmLabel: ''` constructor arguments in
`forecast_explorer_test.dart`.

---

## F4 — the floating `+` overlaps the "Free" value: FIXED

**Observed on the device 2026-08-04** after the device returned to adb. The FAB covers the
tail of `₹98,001`, leaving `₹98,00` legible.

> **A premise written earlier in this file was wrong.** It said the strip "collides only
> while scrolled through the FAB's corner", and concluded that bottom padding could not
> help. The first half is wrong: the collision is present **at the default resting scroll
> position, immediately on launch**, with no scrolling at all. The conclusion happens to
> survive — padding still does not help — but for a different reason, so the reasoning is
> corrected here rather than quietly kept.

Measured geometry, 1080×2400:

| | |
|---|---|
| `_ActionHeader` strip | three equal `Expanded` cells, `CrossAxisAlignment.start` (`home_forecast_explorer.dart:430-442`) |
| "Free" cell | last third; its value is left-aligned inside that third and runs right |
| FAB | `Scaffold.floatingActionButton` (`app_shell.dart:42-50`), pinned bottom-right |
| Result | the FAB's left edge lands inside the "Free" value's text run |

**Bottom padding on the list is not the fix**, and the real reason is that `_ActionHeader`
is *mid-list*, not last — the 12-month chart, month detail, Drivers and risk rows all
follow it. Padding only ever buys clearance at the *end* of a scrollable.

### It is not only the "Free" value — and that decided the fix

The second device screenshot shows the FAB covering the **"Dismiss" control of the
`transport` risk row**. That is an interactive control the user cannot reach, not an
obscured number, and it is the more serious of the two.

> **My own recommendation in this file was wrong and is corrected here.** It proposed
> hiding the FAB while the list scrolls. That fails twice: the strip collision happens
> **at rest, with no scrolling at all**, so hiding-on-scroll never fires for it; and it
> leaves the at-rest case — the one actually photographed — untouched.

Options, re-judged against both collisions:

| Option | Fixes the strip (at rest) | Fixes the buttons (scrolled) |
|---|---|---|
| Hide the FAB on scroll | No | Yes |
| Re-lay the strip | Yes | No |
| **Drop the FAB from Home** | **Yes** | **Yes** |

**Chosen: drop the FAB from Home.** `fabVisible` already enumerates tabs
(`app_shell.dart:25`), so it is one line. Since TASK-34 wired up the forecast surface,
Home is a read-and-decide dashboard carrying its own controls — Confirm / Edit / Dismiss,
"Start reserve" — and a floating add-expense button over financial figures was competing
with them. Adding an expense still lives one tab away on Activity, which is where
transactions are, and the FAB is unchanged there and on Invest.

This is a product call, made on the user's instruction to proceed, and recorded as one
rather than presented as a defect fix.

### Tests

| Test | Kind | RED symptom |
|---|---|---|
| `Home carries no floating action button` | Regression | `Expected: no matching candidates` / `Actual: Found 1 widget with type "FloatingActionButton"` |
| `Activity still has one, so adding is not lost` | **Guard** | Passed before the fix. It is what stops the removal being widened to every tab. |

Both boot the real app through `ExpenseInsightApp` and skip onboarding, so they exercise
the shell the device runs rather than a widget in isolation.

---

## Definition of done

- [x] F3 fixed on the reason side; 2 tests, 1 regression + 1 guard, RED recorded
- [x] `anchorConfirmLabel` deleted from `lib` and `test`; zero references remain
- [x] Confirmed the provisional message still reaches the user from two other sites
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 918 passing, 0 failing (903 after F3, 918 after F4 and TASK-37)
- [x] F4 — fixed by dropping the FAB from Home; Activity keeps it
- [x] Device verification — done, see below

---

## Device verification, 2026-08-04

Samsung SM-G781B, 1080×2400. Built and installed with `adb install -r`. **No scan was
triggered and no destructive control was tapped.**

Reconciled exactly — the database is **byte-identical** before and after (`cmp`), and
every count matches the Phase-4 baseline:

| | Before | After |
|---|---|---|
| `user_version` | 4 | 4 |
| transactions / `MAX(id)` / `MIN(id)` | 2061 / 2716 / 14 | 2061 / 2716 / 14 |
| auto_added / confirmed / needs_review / dismissed | 1759 / 187 / 109 / 6 | 1759 / 187 / 109 / 6 |
| obligations / risk decisions / known accounts | 9 / 3 / 0 | 9 / 3 / 0 |

### TASK-35 confirmed on real data

August's **"Unconfirmed risk" reads ₹1,21,640**, down from the ₹2,73,425 recorded in
TASK-34. The salary credit is gone from the total and no longer appears in the risk rows,
which now read `hdfc bank ltd ₹61,415`, `other ₹2,044`, `groceries ₹32`, `transport ₹36`,
`utilities …` — all outflows.

**The drop is ₹1,51,785 against a salary of ₹1,51,556 — a ₹229 residual, not an exact
match.** Stated rather than rounded away. The two figures were measured on different runs
and the seasonal estimate is recomputed per day (TASK-16's per-day-per-category lines are
visible in the why-log, and `other` alone moves in ₹2,044 steps), so day-boundary drift in
the seasonal component is the likely cause. Not chased further; recorded so nobody reads
the near-match as exact.

### TASK-37 confirmed on real data

The why-log's RECURRING section renders the double count directly:

| Line | Date | Amount |
|---|---|---|
| `phonepe` | 29 Aug · Overdue | ₹120 |
| `ece9ae70c53842d58abf92660f4698af` | 29 Aug · Unpaid | ₹120 |
| `google` | 28 Apr · Overdue | ₹1,999 |
| `google asia pacific pte.ltd` | 11 Jul · Overdue | ₹1,999 |
| `xfkxfma537eoyvuzwkvss3vbvbr1oxoo` | 28 Aug · Unpaid | ₹1,999 |

Same amount, same commitment, listed two and three times. Exactly what the TASK-37
reproduction asserts, now on a rendered screen.

### F3 not verified on device

The coverage tiles sit below the RECURRING and per-day seasonal sections, and TASK-16's
line volume puts them hundreds of rows down. Scrolling there was not a good use of the
device, and the widget test is the stronger evidence anyway — it is deterministic and
repeatable, where a screenshot is neither. Called out rather than left implied.

### Found while verifying: TASK-39

A Drivers row read **`autopay  bharat connec`**, which turned out to be a real defect in
the `to <payee>` fallback. Written up as [TASK-39](TASK-39-untidied-fallback-payee.md) and
fixed. This is the fourth consecutive phase where installing the build found something
code review did not.

### Still outstanding

**A rescan is a separate decision, not a step.** TASK-36 and TASK-39 only change rows as
they are re-parsed, so their 49 rows keep their current merchants until a scan runs — and
per TASK-37 that same scan will strand `sms_recurring:ece9ae70…:monthly` as a permanent
orphan, because the retirement path does not exist yet. Landing TASK-37 before rescanning
avoids creating a duplicate that then has to be cleaned up by hand.
