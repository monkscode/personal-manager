# TASK-20 — Reconciliation minors (10 items)

**Severity:** Minor · **Phase:** 2 · **Depends on:** TASK-12 through TASK-19 merged first

Ten small items in the reconciliation slice, plus a test-quality note. Independent; do
them in any order.

---

## STATUS: DONE

All ten items are addressed or explicitly closed with a recorded reason, the boundary
tests are in, and every item now has coverage. `flutter analyze` clean, `flutter test`
**764 passing** (was 735 — +29).

Working the tests found one real defect in the M4 code that had already landed: it made
rupees vanish. See "M4 correction" below.

Each test was driven RED before being accepted. The code for M1–M6/M8/M9 was already
committed, so RED was demonstrated by reverting that item's fix (or, for the boundary
tests, by mutating the threshold) and recording the failure — the symptoms are under
each item.

---

## M1 — `anchor_selector` ignores `now`; a future-dated anchor wins forever

`lib/services/anchor_selector.dart:20-29`

`required DateTime now` is never used. Nothing rejects a future-dated anchor, and
`BalanceAnchor.freshnessAsOf` (`lib/data/forecast_models.dart:90-94`) classifies a
**negative** age as `current`. So one bad SMS timestamp yields an anchor that is
permanently "fresh" and permanently wins selection.

- [x] Use `now` to reject `asOf > now`, or drop the parameter. Prefer rejecting.

**Tests** `test/anchor_selector_test.dart` — group *"future-dated anchors (M1)"*, 4 tests.
**RED** (`_rejectFutureDated` reverted to a pass-through): 3 of 4 failed —
`Expected: same instance as <BalanceAnchor> / Actual: <BalanceAnchor>` (the future-dated
anchor won selection), and `Expected: null / Actual: <BalanceAnchor>` when both were
future-dated. The 4th, *"an anchor stamped exactly at now is kept"*, passes either way —
it is an off-by-one guard on `isAfter` vs `!isBefore`, not a regression test, and is
recorded as such rather than claimed as RED.

---

## M2 — one `untrackedCash` coverage line per ATM withdrawal

`lib/services/forecast_reconciliation_engine.dart:304-312`

Emits one line per ATM item, each carrying that item's individual amount.
`test/forecast_reconciliation_engine_test.dart:635-668` asserts two lines for two
withdrawals — so the test pins the current behaviour.

The spec's message is about the **monthly total** ("₹X cash withdrawn this month"), and
that total is already computed at `:21-30`.

- [x] Emit one aggregated line. Update the test to match.

**Tests** the existing *"uses monthly ATM total for material untracked-cash caveats"* was
updated with the code; new group *"untracked-cash aggregation threshold (M2)"* adds the
threshold edges.
**RED** (per-item line restored inside `_applyWinner`): the existing test failed
`Expected: an object with length of <1> / Actual: [ForecastCoverageLine, ForecastCoverageLine]`,
and the new at-threshold test failed the same way with three lines. The
*"one paise under the threshold"* case passes either way — under the threshold neither
version emits anything — so it is a guard, not RED.

---

## M3 — obligation source labels are wrong in the why-log

`lib/services/forecast_reconciliation_engine.dart:571-591`

`annualUnscheduled` and `nonPrimaryAccountObligation` both map to
`ForecastEventSource.gmailBill`, so an **SMS-detected** annual obligation is labelled
"Gmail bill" in the why-log. And `ForecastEventSource.manual` is never produced by any
path, despite `ObligationSourceType.manual` existing.

This weakens the product promise of *"no number without a traceable reason"*.

- [x] Map each source to its real origin. Produce `manual` where the obligation is manual.

**Tests** `test/forecast_reconciliation_engine_test.dart` — group *"why-log obligation
origin labels (M3)"*, 3 tests (sms / manual / gmail).
**RED** (`_eventSourceFor` flattened back to `gmailBill`): the SMS case failed
`Expected: ForecastEventSource.recurring / Actual: ForecastEventSource.gmailBill` and the
manual case `Expected: ForecastEventSource.manual / Actual: ForecastEventSource.gmailBill`.
The Gmail case is the guard that the fix did not over-rotate.

---

## M4 — a duplicate item id throws and takes down the whole forecast

`lib/services/forecast_reconciliation_engine.dart:451-458`

`ArgumentError` on a duplicate item id. A data-quality issue then blanks the entire
forecast rather than degrading.

Note the real collision risk: `recurring_obligation_candidates.dart:53` deliberately
reuses `configuredPlanKey` as the dedupe key, and the matcher derives item ids as
`obl:<dedupeKey>` (`reconciliation_matcher.dart:120`). So an SMS-recurring record and a
configured-plan record sharing that key produce **identical ids**.

- [x] Route the collision to review rather than throwing.

### M4 correction — the landed code made rupees vanish

Writing the test caught a real defect in the M4 code that had already shipped in
`1c5db9b`. `_dedupeIds` kept the **first** item per id and silently discarded the rest.
The discarded item then had no assignment, no coverage line and no event: its amount left
the forecast with nothing naming it. That is a direct breach of the spec invariant this
layer exists to enforce —

> **One owner per rupee.** No amount may be counted twice, and none may vanish.

It is not a hypothetical: the two records that collide need not agree on the amount (an
SMS-recurring guess and a configured plan routinely differ), so there is no "same rupee"
to fall back on. `_assertCompleteAssignments` did not catch it because the landed code
also passed it the *deduplicated* list rather than the input.

Fixed here: `_dedupeIds` is replaced by `_partitionIdCollisions`, which returns both the
unique-id items and **every** member of a collision. All colliding members are assigned a
`reviewNeeded` / `reviewPending` coverage line before grouping; none reaches the ledger.
`_assertCompleteAssignments` is back on the full input list.

**Tests** group *"duplicate item ids degrade to review (M4)"*, 3 tests.
**RED** (against the landed code, before this correction):
`every input rupee must land in exactly one coverage bucket — Expected: <1200000>,
Actual: <500000>`, and with an unrelated item in the batch `Expected: <3000000>,
Actual: <2300000>`. The dropped duplicate's ₹7,000 and ₹7,000 respectively had gone
missing. The third test pins that an unrelated item in the same batch still reaches the
ledger, so the degradation stays scoped to the collision.

---

## M5 — `detectOtherIncome` doesn't exclude self-transfers and wallets

`lib/services/salary_income_detector.dart:159-185`

The spec says self-transfers and own-wallet movements are excluded **before** any
recurring-income promotion. They do require confirmation here, so the harm is UI noise
rather than wrong money. `now` is also unused in this function.

- [x] Filter `selfTransfer` and `wallet` payee types before surfacing candidates.

**Tests** `test/salary_income_detector_test.dart` — group *"detectOtherIncome excludes
own-money movements (M5)"*. The fixture carries four credits: the month's salary pick, one
genuine other-income credit, a self-transfer and a wallet top-up.
**RED** (filter removed): `Expected: ['Acme Consulting'] / Actual:` all three non-salary
credits — the self-transfer and the wallet top-up were both surfaced for the user to
clear by hand.

---

## M6 — over-refund excess silently raises the projected balance

`lib/services/reconciliation_matcher.dart:495-511`

Excess becomes `ForecastOwner.otherIncome`, which the engine passes straight into the
ledger as a dated inflow (`forecast_reconciliation_engine.dart:194-207` only gates
`p2pIncomeCandidate`). An **unconfirmed** residual raises the projected balance.

- [x] Gate over-refund residuals behind confirmation, as `p2pIncomeCandidate` already is.
      TASK-17 changes how this residual arises — do that first.

**Tests** group *"unconfirmed other income is gated (M6)"*, 2 tests.
**RED** (gate narrowed back to `p2pIncomeCandidate` only): `Expected: empty / Actual:
[ForecastEvent]` — the unconfirmed residual reached the ledger as a dated inflow and
raised the projected balance. The second test is the guard that a *user-confirmed* other
income is still credited.

---

## M7 — `_hasUnresolvableTie` only inspects the first two members

`lib/services/forecast_reconciliation_engine.dart:496-501`

Inspects only `ordered[0]` and `ordered[1]`. A three-member group whose **2nd and 3rd**
tie is resolved arbitrarily.

- [x] **Closed as a no-op.** Do *not* check ties across the whole ordered group.

### M7 decision — verified, and the provisional reasoning was incomplete

The provisional note said a tie below the winner "cannot change any outcome" and that the
`matchKey == null` precondition makes the check "dead for every match-key group". Both
were re-derived from the source. The first is right; the second is true but too narrow,
and it does not establish what it was being used to conclude. The full picture:

1. **A tie among non-winners is unobservable — confirmed.** `_chooseWinners` returns
   *every* bridging transfer, or *every* dated card payment, or `[ordered.first]`. It
   never picks between two tied members. Every non-winner then goes to
   `_assignReconciledDuplicate`, which is a pure function of the item and
   `bridgeTargetIds` — nothing reads rank. So widening the check cannot fix a wrong
   answer; it can only convert resolvable groups into review.

2. **The precondition kills the check for `match:` groups only.** Every member of a
   `match:` group carries the same non-null `matchKey`, so `ordered[0].matchKey == null`
   is never true there. `cardCycle:` groups are the opposite — `_groupKey` tests
   `matchKey` first, so a group only falls through to `cardCycle:` when every member has
   a null one. The check is live there.

3. **`bridge:` groups can never tie at `ordered[0..1]`.** `_bridgeTargets`
   (`reconciliation_matcher.dart:155-159`) only emits a target for a candidate whose
   `obligation != null`, i.e. a `funded` (uniquely-paired) one — an obligation contested
   by two transfers is `ambiguous` and yields no target at all. So at most one transfer
   names any given target, and the target itself is an `obl:` item whose owner precedence
   is never 50. No tie.

4. **`cardCycle:` groups — the only live case — do not form in the shipped app.**
   TASK-13 measured this: `CardCycle` is never constructed anywhere in `lib/`, so
   `needsCycleSetup` is always true (card items are `cardPurchase`, never
   `cardStatement`) and `dueDate` is always null, so `_cardCycleFor` returns
   `none()` and every `cardpay:` item carries a null `cardCycleKey`.

So `_hasUnresolvableTie` returns `false` on every group the app can currently produce, and
the widened version is actively wrong. Implementing the proposed fix breaks two tests:

```
ForecastReconciliationEngine user-confirmed obligation wins over unconfirmed
commitment at same owner precedence [E]
  Expected: an object with length of <1>
    Actual: []
a tie below the winner is not resolved at all (M7) the strict precedence winner is
still booked [E]
```

The first is TASK-14's — the widened check sends every same-amount duplicate pair to
review instead of deduplicating it, exactly as the provisional note feared.

**Recorded instead:** the limit is now a doc comment on `_hasUnresolvableTie` explaining
why it stops at `ordered[0..1]`, plus a characterization test
(*"a tie below the winner is not resolved at all (M7)"*, 2 tests) that pins the behaviour
and asserts the outcome is identical when the two tied members swap ids — which is what
"resolved arbitrarily" would have to mean to matter. Note the tie is in fact broken
*deterministically*, by `(isUserConfirmed, id)`, not arbitrarily; nothing downstream reads
that order.

**One thing to revisit if TASK-13's condition changes.** The moment anything supplies a
`CardCycle`, `cardCycle:` groups become reachable — and a group of two `cardPayment` items
with no `cardStatement` would tie at `ordered[0..1]` with a null `matchKey`, sending both
to review. That contradicts TASK-13's rule that two payments in a cycle are two real
debits. That is a *narrowing* of the check, not the widening M7 proposed, and it is out of
scope here because the path is dead.

---

## M8 — `ObligationRecord.copyWith` cannot clear a nullable field

`lib/data/obligation_models.dart:125-186`

`?? this.x` throughout, so `dueDate`, `amountPaise` and `sourceId` can never be set back
to null. Given obligations are re-derived and upserted on every scan, an obligation that
*loses* its due date keeps a stale one.

- [x] Use explicit sentinel wrappers for nullable fields, or add dedicated `clearX()`
      helpers. Note TASK-02 currently *relies* on `?? this.x` preserving values — read
      that task before changing this, and keep its behaviour intact.

**Tests** `test/obligation_repository_test.dart` — group *"a rescan that drops a derived
field clears it (M8)"*, 3 tests. The third is TASK-02's guarantee re-asserted on the same
rescan, so the two cannot regress independently.
**RED** (`_merge` reverted to `existing.copyWith(...)`): all three failed —
`Expected: null / Actual: DateTime:<2026-08-15 00:00:00.000>` for a due date the rescan
had dropped, and `Expected: null / Actual: <4700000>` for a dropped amount. The stale
values survived forever.

---

## M9 — `ObligationRecord` has no `==` / `hashCode`

`lib/data/obligation_models.dart`

`TransferBridgeMatcher` uses `ObligationRecord` as a `Map`/`Set` key
(`transfer_bridge_matcher.dart:81, 90, 125`). This works **only** because the identical
instances flow through both calls — a `copyWith` between them would silently break
direct-payment suppression.

- [x] Add value equality, or key the maps on `dedupeKey` instead. Prefer the latter; it is
      less code and removes the hazard entirely. TASK-15 wires this module up, which makes
      the hazard live — do TASK-15 first.

**Tests** `test/transfer_bridge_matcher_test.dart` — 2 tests.
**RED** (both maps keyed back on `ParsedTxn` / `ObligationRecord` instances): two rows
sharing a `dedupeKey` read as two separate obligations, so two transfers each aiming at
one of them were both auto-linked —
`Expected: {TransferBridgeResolution.ambiguous} / Actual: {TransferBridgeResolution.funded}`.
That funds one bill twice, which is the double count this module exists to stop. The
second test is the guard that honestly-distinct `dedupeKey`s still fund uniquely, so the
collapse keys on identity rather than merely on count.

**Not covered, and why.** The *direct-payment suppression* half of the hazard is not
observable through the public API. `_directlyPaidOnPrimary` and the filter that consumes
its result are both fed the same caller-supplied list inside one `match()` call, so
instance identity always held and no fixture can break it from outside. The `dedupeKey`
keying removes that hazard by construction rather than by test — worth knowing the test
above pins only the contested-obligation half.

---

## M10 — model invariants are `assert`s, absent in release builds

`lib/data/obligation_models.dart:92-94`

`amountPaise >= 0` and `confidence in [0,1]` are `assert`s, so they do not run in release.
Fine for internal call sites — worth knowing they are **not** a production guarantee.

- [x] **Decision: keep them as asserts; documented as development-only. Not promoted.**

### M10 decision

Measured first. The DB read is a genuinely unguarded boundary:
`ObligationRepository._fromRow` (`obligation_repository.dart:263-301`) passes every column
straight into the constructor with no clamping, and the `obligations` DDL
(`sms_storage_schema.dart:44-73`) carries **no CHECK constraint** behind any of the three
invariants — `amount_paise INTEGER`, `confidence REAL NOT NULL`,
`reserve_funded_paise INTEGER NOT NULL DEFAULT 0`. So in a release build a corrupt row is
hydrated exactly as stored.

Promoting them to real throws there was rejected: `_fromRow` is on the **read** path, so
one bad row raising would take out `allActive()` and blank the entire obligation list —
the precise failure mode M4 exists to remove from the forecast. Trading a silent bad value
for a blank screen is not an improvement, and the tension is already noted in the item.

The write side is where a real check belongs, and one already exists there:
`updateReserveProgress` throws `ArgumentError` on a negative `fundedPaise`
(`obligation_repository.dart:162-167`). That is the pattern to extend if this is ever
revisited — guard the writer, and if a reader guarantee is ever wanted, degrade the row to
review rather than throwing.

Adding CHECK constraints to the DDL would be a schema change and belongs with the Phase-4
schema work (TASK-25), not with a Phase-2 minor.

**Tests** `test/obligation_repository_test.dart` — group *"ObligationRecord invariants are
development-only (M10)"*, 2 tests, pinning that a negative amount and an out-of-range
confidence raise `AssertionError` — i.e. that these are asserts, not checks. No RED: this
item is a recorded decision with no code change, and the tests are characterization. Their
value is that converting either assert to a real check must fail here and force the
decision to be revisited rather than drifting.

---

## Test-quality note (not a code fix)

These assert a constant equals the literal from its own source line. Defensible as spec
pins, but no behavioural test drove any of the four named constants to a boundary.

**The premise had drifted — corrected here.** The audit said all four were "exercised only
by these identity assertions". Re-grepped before writing anything: only
`kRecurringDayOfMonthVarianceDays` still had one
(`recurring_debit_detector_test.dart:349`). `kSalaryMinMonthlyPaise`,
`kVariableSalaryUpperPercentile` and `kSeasonalBufferDayOfMonth` had **no test reference
at all** — not even an identity assertion. They were untested outright, which is worse
than the note claimed.

- [x] Add one boundary test per constant: a case just inside and just outside each
      threshold.

Each was driven RED by mutating the threshold — there is no bug being fixed here, so the
honest RED is proof the test discriminates:

| Constant | Test | Mutation | RED symptom |
|---|---|---|---|
| `kRecurringDayOfMonthVarianceDays` | `recurring_debit_detector_test.dart` — *"kRecurringDayOfMonthVarianceDays boundary"* | `daySpread <= k` → `<` | spread-4 stopped locking: `Expected: an object with length of <1> / Actual: []` |
| `kSalaryMinMonthlyPaise` | `salary_income_detector_test.dart` — *"kSalaryMinMonthlyPaise boundary"* | `amountPaise >= k` → `>` | a credit exactly at the floor stopped being salary: `Expected: SalaryConfidence.detectedStable / Actual: SalaryConfidence.insufficientData` |
| `kVariableSalaryUpperPercentile` | `salary_income_detector_test.dart` — *"kVariableSalaryUpperPercentile boundary"* | `0.80` → `0.75` | `Expected: <1320000> / Actual: <1300000>` |

Notes on the fixtures:

- **Day variance.** Three monthly debits, identical amount and merchant, every
  inter-occurrence gap inside the (28, 33) monthly window, so day-of-month drift is the
  only variable. Days `[10, 12, 14]` give `circularDaySpread == 4` and lock;
  `[10, 12, 15]` give 5 and do not.
- **Salary floor.** Three monthly credits at exactly `kSalaryMinMonthlyPaise` detect as a
  stable salary; at one paise under, `_isSalaryCandidate` rejects every credit and the
  profile falls to `insufficientData`.
- **Upper percentile.** Five clean monthly credits ₹1,000 apart, spread wide enough to be
  `detectedVariable`. p80 lands at rank 3.2 — *between* the 4th and 5th sample — so
  `rangeHighPaise == 1320000` distinguishes it from both the p75 (13,00,000) and the
  maximum (14,00,000). Asserted against both neighbours, not just the literal.

### `kSeasonalBufferDayOfMonth` — retired, no boundary test possible

Verified rather than assumed. The constant still exists at
`reconciliation_matcher.dart:29`, is marked
`@Deprecated('Superseded by _remainingDays; no longer dates anything.')`, and the only
remaining reference in `lib/` is a doc comment on `_remainingDays` explaining what it
replaced. It dates nothing, so there is no threshold to sit either side of.

TASK-16 retired it: the discretionary residual used to be dropped on day 28, which both
fabricated the "you need ₹X by the 28th" headline and made the whole estimate vanish on
the 29th, when day 28 stopped being after the anchor. It is now spread across the days
still ahead of the anchor. The constant is kept only so the D3 default stays on record.

Recorded here in place of a test, as the task file directed.

---

## What landed

- **M1** `AnchorSelector` now rejects any anchor dated after `now`. This immediately caught
  **two adapter fixtures whose own clock was incoherent** — `_now` was 1 Aug while the
  fixture anchor claimed a balance read on 10 Aug. Both now build with a mid-month `now`.
- **M2** One aggregated `untrackedCash` line carrying the monthly total, emitted once in
  `reconcileMonth` rather than per ATM item. Existing test updated.
- **M3** `_eventSourceFor` takes the item, not just the owner, and obligation-shaped owners
  map through `_obligationSourceFor(item.source)`. `ForecastEventSource.manual` is now
  reachable, and an SMS-detected annual obligation no longer reads "Gmail bill".
- **M4** `_assertUniqueIds` replaced by `_partitionIdCollisions`: **every** member of an id
  collision is routed to review before grouping, and the forecast no longer blanks on a
  data-quality problem. The first attempt (`_dedupeIds`, shipped in `1c5db9b`) kept only
  the first item per id and dropped the rest, which made their rupees vanish — see
  "M4 correction" above.
- **M5** `detectOtherIncome` filters `selfTransfer` and `wallet` payee types.
- **M6** The unconfirmed-inflow gate in `_applyWinner` now covers `otherIncome` as well as
  `p2pIncomeCandidate`, so an over-refund residual cannot raise the projected balance
  without confirmation.
- **M8** `ObligationRepository._merge` is written out in full instead of via `copyWith`.
  `copyWith`'s `?? this.x` cannot carry a null, so a rescan that dropped a due date kept
  the stale one forever. The preserved set (row identity + user intent) is now visible in
  one place, and `copyWith` keeps its existing semantics for every other caller — TASK-02's
  behaviour is intact because it is expressed explicitly rather than by omission.
- **M9** `TransferBridgeMatcher` keys its maps on `smsId` / `dedupeKey` instead of on model
  instances that have no value equality.

## Tests added (29)

| File | Group | Tests |
|---|---|---|
| `anchor_selector_test.dart` | future-dated anchors (M1) | 4 |
| `forecast_reconciliation_engine_test.dart` | untracked-cash aggregation threshold (M2) | 2 |
| `forecast_reconciliation_engine_test.dart` | why-log obligation origin labels (M3) | 3 |
| `forecast_reconciliation_engine_test.dart` | duplicate item ids degrade to review (M4) | 3 |
| `forecast_reconciliation_engine_test.dart` | unconfirmed other income is gated (M6) | 2 |
| `forecast_reconciliation_engine_test.dart` | a tie below the winner is not resolved at all (M7) | 2 |
| `salary_income_detector_test.dart` | detectOtherIncome excludes own-money movements (M5) | 1 |
| `salary_income_detector_test.dart` | kSalaryMinMonthlyPaise boundary | 2 |
| `salary_income_detector_test.dart` | kVariableSalaryUpperPercentile boundary | 1 |
| `obligation_repository_test.dart` | a rescan that drops a derived field clears it (M8) | 3 |
| `obligation_repository_test.dart` | ObligationRecord invariants are development-only (M10) | 2 |
| `transfer_bridge_matcher_test.dart` | M9 dedupe-key identity + guard | 2 |
| `recurring_debit_detector_test.dart` | kRecurringDayOfMonthVarianceDays boundary | 2 |

Not every one of these went RED, and the ones that did not are marked as such under their
item: the M1 "exactly at now" case, the M2 sub-threshold case, the M3 Gmail case, the M6
confirmed case and the M9 distinct-key case are **guards** — they pin that the fix did not
over-rotate, and they pass with or without it. The M7 and M10 groups are
**characterization** tests for items closed as no-ops. Counting all 29 as regression
coverage would overstate what they prove.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] All ten items addressed, or explicitly closed with a reason recorded here
      — M1–M6, M8, M9 done with tests; M7 and M10 closed with recorded decisions
- [x] Boundary tests added for the untested constants — three written,
      `kSeasonalBufferDayOfMonth` recorded as retired instead
- [x] `flutter analyze` clean, `flutter test` green — **764 passing** (was 735)
- [x] Commit: `Cover reconciliation edge cases and pin threshold boundaries`
