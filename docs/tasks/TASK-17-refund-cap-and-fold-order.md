# TASK-17 — Refund over-credit; order-dependent fold

**Severity:** Important ×2 · **Phase:** 2 · **Depends on:** nothing

Two ways the reconciliation produces a different answer than it should — one inflates
income, the other makes the result depend on list order.

---

## Defect 1 — refund cap is per group key, not per original debit

`lib/services/reconciliation_matcher.dart:461-465, 473-477, 520-532`

Groups are keyed by `refNumber ?? normalized merchant` (lines 517-518), and the cap is
computed **independently inside each group**.

### Failing scenario

Two refunds for the same ₹10,000 Amazon order, carrying **different reference numbers** —
routine for item-level refunds on a multi-item order.

They form **two groups**. Each resolves `_findOriginalDebit` to the *same* ₹10,000 debit.
Each is capped at ₹10,000 independently. Result: up to **₹20,000 of bank inflow recorded
for a ₹10,000 purchase.**

The spec's rule — *cumulative refunds are capped at the original debit amount* — is not
achieved, because "cumulative" is evaluated per group rather than per debit.

### Second, related bug

`_findOriginalDebit` (lines 526-531) returns the **first merchant-matched debit** with no
amount check and no date-proximity check. So a ₹3,000 AMAZON refund can cap against a
₹200 AMAZON debit and generate a **₹2,800 phantom "over-refund income"**.

### Fix

- Track the refund cap **per original debit**, not per group. Accumulate across all groups
  that resolve to the same debit.
- Give `_findOriginalDebit` an amount check (the refund cannot exceed the debit) and a
  date-proximity bound (a refund arrives after its debit, within a plausible window).
- When no plausible original debit exists, route to review rather than inventing income.

---

## Defect 2 — the fold is order-dependent on the `actuals` list

`lib/services/reconciliation_matcher.dart:255-276`

`paymentStatus` is overwritten **unconditionally** in both branches.

### Failing scenario

- Debit **A** is ambiguous — it matches owners X and Y.
- Debit **B** uniquely matches X.

Processing order **A → B** leaves X as `paid`.
Processing order **B → A** downgrades X to `possiblyPaid` and **drops it from the ledger**.

Same inputs, different order, **different rupee outcome**.

### Fix

Either:
- Make the status transition **monotonic** — a confirmed unique match must never be
  downgraded by a later ambiguous one; or
- Resolve **all** debits globally before assigning any status (preferred — it is easier to
  reason about and matches how `TransferBridgeMatcher` already does bipartite matching at
  `transfer_bridge_matcher.dart:80-111`).

The engine's own ordering is already deterministic
(`forecast_reconciliation_engine.dart:538-551` — precedence → user-confirmed → id, with
`LinkedHashMap` throughout, so there is no hash-iteration dependence). This fold is the
one place that leaks input order into the result. Close it.

---

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

**Refunds:**
- [x] Two refunds with different reference numbers against one ₹10,000 debit → total
      credited is capped at **₹10,000**, not ₹20,000. — **RED** (₹13,000 credited)
- [x] A ₹3,000 refund with only a ₹200 same-merchant debit available → routed to review,
      **no** phantom income generated. — **RED** (an `otherIncome` item appeared)
- [x] A refund dated *before* its candidate debit is not matched to it. — **RED**
- [x] A single legitimate refund within the cap still credits normally (regression guard).

**Fold order:**
- [x] The A→B and B→A scenario above produces the **same** `paymentStatus` for X and the
      same ledger total. — **RED**: `paid` one way, `possiblyPaid` the other, and a
      ₹10,000 difference in the ledger from list order alone.
- [x] The rupee-conservation helper (TASK-14) passes under both orderings — every
      reconcile in the file routes through it.

## Decisions taken

**The refund lookback window is a chosen default, not a spec value.**
`kRefundLookbackDays = 90`. The plan asked for "a plausible window" without naming one.
Permissive enough that ordinary merchant refunds land inside it, tight enough that a refund
cannot bind to an unrelated purchase months earlier. In production the matcher is only ever
handed one month of actuals, so this bites only on longer windows. Worth confirming against
the spec if a number exists there.

**A reference-number match is still unbounded.** An exact reference is a strong identifier,
so it is trusted without the amount and date checks the merchant-name path now carries. The
cap still applies, so a large refund against a small referenced debit surfaces as an
over-refund residual rather than a full credit — and TASK-20 M6 gates that residual behind
confirmation.

**Global resolution, not monotonic status.** Of the plan's two options the second was
taken: every debit is resolved against every owner first, then statuses are assigned. A
unique match settles the owner; an ambiguous debit can only raise a question about an owner
nothing else answered. `actualDate` takes the *earliest* settling debit rather than
whichever arrived first, so it is deterministic too.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Refund cap accumulates per original debit across all groups — refunds are processed
      in date order against a per-debit ledger, and the group key is gone entirely
- [x] `_findOriginalDebit` bounded by amount and date proximity, and prefers the most
      recent qualifying purchase
- [x] No plausible original debit → review, not income
- [x] Fold result is independent of `actuals` ordering
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **722 passing** (was 716)
- [x] Suggested commit: `Cap refunds per original debit and make the actuals fold order-independent`
