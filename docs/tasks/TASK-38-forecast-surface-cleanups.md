# TASK-38 — Forecast-surface cleanups

**Severity:** Minor · **Phase:** 5 · **Depends on:** TASK-34

Findings 3 and 4 from the end of TASK-34, plus the `anchorConfirmLabel` render-or-delete
decision recorded in the same file. Grouped because each is a few lines and none changes
any monetary value.

| Item | Outcome |
|---|---|
| F3 — the `discretionaryNotModelled` tile prints its label twice | **Fixed** |
| `Insights.anchorConfirmLabel` rendered nowhere | **Deleted** (29 sites) |
| F4 — the floating `+` overlaps the "Free" value | **Deferred — could not observe** |

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

## F4 — the floating `+` overlaps the "Free" value: DEFERRED

**Not fixed, and deliberately not attempted blind.**

The device dropped off wireless adb partway through this session and could not be
recovered — `adb devices` empty, `adb mdns services` empty, and the recorded mDNS name no
longer resolves. Restoring it needs someone to re-enable Wireless debugging on the phone.
The only report of this defect is a screenshot observation, so there was nothing left to
work from.

What the source says, for whoever picks it up:

- The FAB is an ordinary `Scaffold.floatingActionButton` (`app_shell.dart:42-50`), pinned
  bottom-right above the bottom bar, floating over `HomeScreen`'s scrolling list.
- `_ActionHeader` is *inside* that scrolling list, so it is not permanently occluded — it
  collides only while scrolled through the FAB's corner. That materially changes the fix:
  **bottom padding on the list would not help**, because the collision is mid-scroll, not
  at the end.
- So the real options are to move or shrink the FAB, hide it while the explorer is
  scrolling, or move the "Free" value out of the bottom-right — all product decisions, not
  a one-line cleanup, and none of them safe to pick without seeing the actual overlap.

A useful next step that does **not** need the phone: a widget test pumping `AppShell` at
the device's logical size (1080 physical ÷ DPR ≈ 393 × 873) that asserts the FAB's rect
does not intersect the "Free" value's rect. That would turn a screenshot observation into
a repeatable assertion, and it should be written before any fix.

---

## Definition of done

- [x] F3 fixed on the reason side; 2 tests, 1 regression + 1 guard, RED recorded
- [x] `anchorConfirmLabel` deleted from `lib` and `test`; zero references remain
- [x] Confirmed the provisional message still reaches the user from two other sites
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 903 passing, 0 failing (was 901)
- [ ] F4 — blocked on device access; not attempted
- [ ] Device verification of TASK-35/36/38 — blocked, see below

---

## Device verification: BLOCKED

Not done, and not claimed. The APK for this batch built cleanly
(`flutter build apk --debug` → `build/app/outputs/flutter-apk/app-debug.apk`) but was
never installed, because the device left adb before the build finished.

**Nothing was written to the device this session.** The only device contact was a
read-only `adb exec-out run-as … cat databases/transactions.db` early on, whose copy was
deleted. The database therefore still reads exactly as measured on 2026-08-04: schema v4,
2,061 rows, `MAX(id)` 2716, `MIN(id)` 14, 1759/187/109/6, 9 obligations,
3 `forecast_risk_decisions`.

Still outstanding when the device returns:

1. Install and confirm the TASK-35 risk buffer no longer includes the ₹1,51,556 salary —
   August's "Unconfirmed risk" should drop from ₹2,73,425, and September from ₹5,22,364.
2. Observe F4 and decide it properly.
3. **A rescan is a separate decision, not a step.** TASK-36 only changes rows as they are
   re-parsed, so its 41 rows keep their handle merchants until a scan runs — and per
   TASK-37 that same scan will strand `sms_recurring:ece9ae70…:monthly` as a permanent
   orphan, because the retirement path does not exist yet. Landing TASK-37 before
   rescanning avoids creating a duplicate that then has to be cleaned up by hand.
