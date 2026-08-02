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

## Correction — wiring alone would not have worked

`_groupKey` (`forecast_reconciliation_engine.dart`) tested `matchKey` **first**:

```dart
if (item.matchKey != null) return 'match:${item.matchKey}';
if (item.transferBridgeToId != null) return 'bridge:${item.transferBridgeToId}';
```

Every secondary obligation with a non-empty `merchantNorm` gets a match key from the
matcher — which is nearly all of them — so a bridge target would have stayed in its
merchant group and never met the transfer funding it. The engine's bridge fixtures only
passed because they are hand-built items with `matchKey: null`. The order is now reversed:
a transfer naming an obligation is direct evidence about *that* obligation, where a match
key is a merchant/cadence coincidence.

## Correction — this does not close a live double count

The stated rationale is an **`unknown`**-scope obligation funded by a transfer. But
`TransferBridgeMatcher.match` filters `paymentAccountScope == AccountScope.secondary`, and
a **secondary** obligation is *already* excluded from the primary ledger by
`_applyWinner`'s `outOfPrimaryScope` branch. So for the scope the module actually accepts,
both legs were never counted — one was.

The `unknown`-scope double count is real and is a **different defect**: `_obligationOwner`
maps unknown scope to `gmailBill`, so `_applyWinner` emits the event and only adds an
`accountHintUncertain` line, while the funding transfer is counted separately. Widening the
module to `unknown` would let any coincident same-amount transfer suppress a genuine
primary bill — a worse failure than the one it fixes — so it is **not** done here and is
recorded as an open finding rather than silently folded in.

What wiring does buy: the engine's bridge branches stop being dead code, the pairing
becomes explicit rather than incidental, and the date-bound fix below becomes reachable.

## Ambiguity is not routed away from the ledger

The plan asks for an ambiguous two-transfers-one-target case to be "routed to review". It
is surfaced, not removed: both transfers are observed primary debits, so both stay dated
events, and only the obligation is suppressed (with its coverage line). Excluding real cash
from the ledger because its *purpose* is unclear would understate required-in-bank — the
dangerous direction. An ambiguous pairing therefore sets no `transferBridgeToId` at all.

`_chooseWinners` was extended the same way as for card payments: every bridging transfer is
kept, so the latent "second transfer silently excluded" bug cannot arise even from
hand-built items.

## Tests to write first

Add to `test/reconciliation_matcher_test.dart` (integration — the wiring is the point):

- [x] A **secondary**-scope obligation funded by a primary→secondary transfer → the ledger
      subtracts the amount once. (Scope corrected from `unknown`, reason above.)
- [x] `transferBridgeToId` is actually populated by `_transferItems` when a bridge exists.
      — **RED** (null)
- [x] Two transfers pointing at one bridge target → both kept, obligation named, nothing
      silently excluded.
- [x] A transfer that funds nothing carries no bridge (regression guard).
- [x] The rupee-conservation helper from TASK-14 passes for a bridged scenario — every
      reconcile in the file routes through it.

Add to `test/transfer_bridge_matcher_test.dart`:

- [x] `_directlyPaidOnPrimary` with a matching debit **11 months old** does **not**
      suppress the current bridge. — **RED** (no candidates at all)
- [x] A matching debit **inside** the due window still suppresses it (regression guard).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `TransferBridgeMatcher` has a real production caller and `transferBridgeToId` is set
- [x] The engine's bridge branches are exercised by at least one integration test
- [x] Two-transfers-one-target emits a coverage line rather than silently dropping
- [x] `_directlyPaidOnPrimary` is date-bounded to the due window (window check extracted
      from `_bridges`, so both lanes share one definition)
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **710 passing** (was 704)
- [x] Suggested commit: `Wire the transfer bridge so funded obligations are not double counted`

## Open finding, not fixed here

An **`unknown`**-scope obligation and the transfer that funds it are still both subtracted.
Fixing it needs a scope-resolution rule, not a wider bridge. Not re-reported as new.
