# TASK-20 — Reconciliation minors (10 items)

**Severity:** Minor · **Phase:** 2 · **Depends on:** TASK-12 through TASK-19 merged first

Ten small items in the reconciliation slice, plus a test-quality note. Independent; do
them in any order.

---

## STATUS: PARTIALLY DONE — code landed, tests still owed

TASK-12 through TASK-19 are merged. The **code** for M1–M6, M8 and M9 is committed and
`flutter analyze` / `flutter test` are green at **735 passing**, but the dedicated tests for
those items were **not** written, and M7/M10 are decisions still to be recorded. Do not
treat the boxes below as evidence of coverage — see "What is still owed" at the end.

---

## M1 — `anchor_selector` ignores `now`; a future-dated anchor wins forever

`lib/services/anchor_selector.dart:20-29`

`required DateTime now` is never used. Nothing rejects a future-dated anchor, and
`BalanceAnchor.freshnessAsOf` (`lib/data/forecast_models.dart:90-94`) classifies a
**negative** age as `current`. So one bad SMS timestamp yields an anchor that is
permanently "fresh" and permanently wins selection.

- [ ] Use `now` to reject `asOf > now`, or drop the parameter. Prefer rejecting.

---

## M2 — one `untrackedCash` coverage line per ATM withdrawal

`lib/services/forecast_reconciliation_engine.dart:304-312`

Emits one line per ATM item, each carrying that item's individual amount.
`test/forecast_reconciliation_engine_test.dart:635-668` asserts two lines for two
withdrawals — so the test pins the current behaviour.

The spec's message is about the **monthly total** ("₹X cash withdrawn this month"), and
that total is already computed at `:21-30`.

- [ ] Emit one aggregated line. Update the test to match.

---

## M3 — obligation source labels are wrong in the why-log

`lib/services/forecast_reconciliation_engine.dart:571-591`

`annualUnscheduled` and `nonPrimaryAccountObligation` both map to
`ForecastEventSource.gmailBill`, so an **SMS-detected** annual obligation is labelled
"Gmail bill" in the why-log. And `ForecastEventSource.manual` is never produced by any
path, despite `ObligationSourceType.manual` existing.

This weakens the product promise of *"no number without a traceable reason"*.

- [ ] Map each source to its real origin. Produce `manual` where the obligation is manual.

---

## M4 — a duplicate item id throws and takes down the whole forecast

`lib/services/forecast_reconciliation_engine.dart:451-458`

`ArgumentError` on a duplicate item id. A data-quality issue then blanks the entire
forecast rather than degrading.

Note the real collision risk: `recurring_obligation_candidates.dart:53` deliberately
reuses `configuredPlanKey` as the dedupe key, and the matcher derives item ids as
`obl:<dedupeKey>` (`reconciliation_matcher.dart:120`). So an SMS-recurring record and a
configured-plan record sharing that key produce **identical ids**.

- [ ] Route the collision to review rather than throwing.

---

## M5 — `detectOtherIncome` doesn't exclude self-transfers and wallets

`lib/services/salary_income_detector.dart:159-185`

The spec says self-transfers and own-wallet movements are excluded **before** any
recurring-income promotion. They do require confirmation here, so the harm is UI noise
rather than wrong money. `now` is also unused in this function.

- [ ] Filter `selfTransfer` and `wallet` payee types before surfacing candidates.

---

## M6 — over-refund excess silently raises the projected balance

`lib/services/reconciliation_matcher.dart:495-511`

Excess becomes `ForecastOwner.otherIncome`, which the engine passes straight into the
ledger as a dated inflow (`forecast_reconciliation_engine.dart:194-207` only gates
`p2pIncomeCandidate`). An **unconfirmed** residual raises the projected balance.

- [ ] Gate over-refund residuals behind confirmation, as `p2pIncomeCandidate` already is.
      TASK-17 changes how this residual arises — do that first.

---

## M7 — `_hasUnresolvableTie` only inspects the first two members

`lib/services/forecast_reconciliation_engine.dart:496-501`

Inspects only `ordered[0]` and `ordered[1]`. A three-member group whose **2nd and 3rd**
tie is resolved arbitrarily.

- [ ] Check for ties across the whole ordered group. TASK-14 adds a test for exactly this
      case — coordinate.

---

## M8 — `ObligationRecord.copyWith` cannot clear a nullable field

`lib/data/obligation_models.dart:125-186`

`?? this.x` throughout, so `dueDate`, `amountPaise` and `sourceId` can never be set back
to null. Given obligations are re-derived and upserted on every scan, an obligation that
*loses* its due date keeps a stale one.

- [ ] Use explicit sentinel wrappers for nullable fields, or add dedicated `clearX()`
      helpers. Note TASK-02 currently *relies* on `?? this.x` preserving values — read
      that task before changing this, and keep its behaviour intact.

---

## M9 — `ObligationRecord` has no `==` / `hashCode`

`lib/data/obligation_models.dart`

`TransferBridgeMatcher` uses `ObligationRecord` as a `Map`/`Set` key
(`transfer_bridge_matcher.dart:81, 90, 125`). This works **only** because the identical
instances flow through both calls — a `copyWith` between them would silently break
direct-payment suppression.

- [ ] Add value equality, or key the maps on `dedupeKey` instead. Prefer the latter; it is
      less code and removes the hazard entirely. TASK-15 wires this module up, which makes
      the hazard live — do TASK-15 first.

---

## M10 — model invariants are `assert`s, absent in release builds

`lib/data/obligation_models.dart:92-94`

`amountPaise >= 0` and `confidence in [0,1]` are `assert`s, so they do not run in release.
Fine for internal call sites — worth knowing they are **not** a production guarantee.

- [ ] Decide: promote to real checks at trust boundaries (parser output, DB read), or
      document that they are development-only. Record the decision here.

---

## Test-quality note (not a code fix)

These four assert a constant equals the literal from its own source line:

- `test/recurring_debit_detector_test.dart:230-238`
- `test/salary_income_detector_test.dart:212-218`
- `test/reconciliation_matcher_test.dart:151-153`
- `test/transfer_bridge_matcher_test.dart:67-73`

Defensible as spec pins. But note that `kRecurringDayOfMonthVarianceDays`,
`kSalaryMinMonthlyPaise`, `kVariableSalaryUpperPercentile` and `kSeasonalBufferDayOfMonth`
are exercised **only** by these identity assertions — no behavioural test drives any of
them to a boundary.

- [ ] Add one boundary test per constant: a case just inside and just outside each
      threshold.

---

## What landed (code only, tests still owed)

- **M1** `AnchorSelector` now rejects any anchor dated after `now`. This immediately caught
  **two adapter fixtures whose own clock was incoherent** — `_now` was 1 Aug while the
  fixture anchor claimed a balance read on 10 Aug. Both now build with a mid-month `now`.
- **M2** One aggregated `untrackedCash` line carrying the monthly total, emitted once in
  `reconcileMonth` rather than per ATM item. Existing test updated.
- **M3** `_eventSourceFor` takes the item, not just the owner, and obligation-shaped owners
  map through `_obligationSourceFor(item.source)`. `ForecastEventSource.manual` is now
  reachable, and an SMS-detected annual obligation no longer reads "Gmail bill".
- **M4** `_assertUniqueIds` replaced by `_dedupeIds`: the first item per id is kept, the
  colliding id is routed to review, and the forecast no longer blanks on a data-quality
  problem.
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

## What is still owed

- [ ] **Tests for M1–M6, M8, M9.** None were written. The suite is green because the
      changes are behaviour-preserving for existing fixtures, not because they are covered.
- [ ] **M7 decision.** Reading the engine, a tie *below* the winner cannot change any
      outcome: `_chooseWinners` takes `ordered.first` and every non-winner goes through the
      same suppression path regardless of how they rank among themselves. The real question
      is the `ordered[0].matchKey == null` precondition, which makes the check dead for
      every match-key group — but relaxing it would send every same-amount duplicate pair to
      review, which TASK-14 deliberately deduplicates instead. Provisional conclusion: close
      as no-op with this reasoning. **Verify before recording.**
- [ ] **M10 decision.** Promote the `ObligationRecord` asserts to real checks at trust
      boundaries, or document them as development-only. Note the tension with M4: throwing
      at a trust boundary is the failure mode M4 just removed.
- [ ] **Four boundary tests.** `kRecurringDayOfMonthVarianceDays` (spread 4 locks, 5 does
      not), `kSalaryMinMonthlyPaise` (a credit at exactly the floor is a candidate, one
      paise under is not), `kVariableSalaryUpperPercentile` (`rangeHighPaise` is the p80).
      `kSeasonalBufferDayOfMonth` **cannot** get one — TASK-16 retired it and it now dates
      nothing; record that instead of writing a test for a dead constant.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] All ten items addressed, or explicitly closed with a reason recorded here
      — M1–M6, M8, M9 done; M7 and M10 outstanding
- [ ] Four boundary tests added for the untested constants — none written
- [x] `flutter analyze` clean, `flutter test` green — **735 passing**
- [ ] Suggested commit: `Tidy reconciliation edge cases and add threshold boundary tests`
