# TASK-15 — `TransferBridgeMatcher` is never called

**Severity:** Important ×2 · **Phase:** 2 · **Depends on:** TASK-12 (same classification path)

An entire module and all its engine branches are dead in production. The double-count it
exists to prevent is therefore live.

---

## Defect 1 — the module has no production caller

`lib/services/transfer_bridge_matcher.dart` (whole file)

Grep over `lib/` finds **no production caller** — only `test/transfer_bridge_matcher_test.dart`.

`ReconciliationMatcher._transferItems` (`lib/services/reconciliation_matcher.dart:550-562`)
never sets `transferBridgeToId`. Consequently every bridge branch in the engine is
unreachable: `forecast_reconciliation_engine.dart:479-494`, `:503-516`, `:378-385`.

### Why it matters

For an `unknown`-scope obligation funded by a primary→secondary transfer, **both legs are
counted** — the transfer as an outflow *and* the obligation as a dated event. That is
exactly the double-subtraction the bridge exists to prevent.

The spec rule being violated (§7, "Primary-to-secondary transfer bridge"):

> When a transfer from the primary account funds an obligation held on a secondary
> account, the transfer and the obligation are two views of **one** rupee movement. Count
> the transfer, and mark the obligation as funded — never subtract both.

### Latent bug, for when it is wired

Two transfers pointing at the same `transferBridgeToId` land in one `bridge:` group.
`_chooseWinner` returns the first and **the second is silently excluded with no coverage
line** — the same defect as TASK-13 and TASK-14. Fix it here at the same time, using the
coverage-line change those tasks introduce.

---

## Defect 2 — `_directlyPaidOnPrimary` has no date bound

`lib/services/transfer_bridge_matcher.dart:115-140`

It scans **all** non-transfer primary debits with no time window whatsoever.

So a ₹47,000 debit to "LIC Premium" from **eleven months ago** permanently suppresses this
month's bridge. The user's current transfer never bridges, and the obligation is counted
separately — reintroducing the double count the module exists to stop.

**Fix:** constrain the direct-debit lookup to the same due window `_bridges` already uses.

---

## What is already correct — do not regress it

The matcher's core logic is genuinely well built and its tests are the best in the
reconciliation slice. Preserve:

- `transfer_bridge_matcher.dart:80-111` — real bipartite uniqueness
  (`matched.length == 1 && transfersByObligation[...].length == 1`), not the naive "this
  transfer has one match" check. Two-transfers-one-obligation is correctly ambiguous, and
  `test/transfer_bridge_matcher_test.dart:174-199` pins it.
- `transfer_bridge_matcher.dart:142-160` — window bounds are date-normalised before
  comparison and inclusive on both edges, with day 5/6 and day 2/3 asserted explicitly at
  `test/transfer_bridge_matcher_test.dart:109-144`. This is the one place in the reviewed
  code where tolerance boundaries are unambiguous **and** tested. Use it as the model when
  fixing tolerance elsewhere.

---

## Tests to write first

Add to `test/reconciliation_matcher_test.dart` (integration — the wiring is the point):

- [ ] An `unknown`-scope obligation funded by a primary→secondary transfer → the ledger
      subtracts the amount **once**, not twice.
- [ ] `transferBridgeToId` is actually populated by `_transferItems` when a bridge exists.
- [ ] Two transfers pointing at one bridge target → ambiguous, routed to review, and
      neither silently excluded (assert a coverage line exists).
- [ ] The rupee-conservation helper from TASK-14 passes for a bridged scenario.

Add to `test/transfer_bridge_matcher_test.dart`:

- [ ] `_directlyPaidOnPrimary` with a matching debit **11 months old** does **not**
      suppress the current bridge.
- [ ] A matching debit **inside** the due window still suppresses it (regression guard —
      `:201-227` covers the same-week case today).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `TransferBridgeMatcher` has a real production caller and `transferBridgeToId` is set
- [ ] The engine's bridge branches are exercised by at least one integration test
- [ ] Two-transfers-one-target emits a coverage line rather than silently dropping
- [ ] `_directlyPaidOnPrimary` is date-bounded to the due window
- [ ] All six tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Wire the transfer bridge so funded obligations are not double counted`
