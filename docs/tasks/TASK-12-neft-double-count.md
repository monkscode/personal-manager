# TASK-12 — NEFT/IMPS bill payment counted twice

**Severity:** Critical · **Phase:** 2 · **Depends on:** nothing

A bill paid by NEFT or IMPS is subtracted from the forecast **twice**. This is reachable
on ordinary Indian bank SMS traffic.

---

## The defect

`lib/services/reconciliation_matcher.dart:52-76`

The classification chain evaluates the **transfer lane (lines 62-64) above** both the
reference check (line 65) and the generic debit lane (line 73).

`lib/services/sms_transaction_parser.dart:284-287` assigns `TxnType.transfer` to any SMS
body containing `neft`, `imps`, or `transfer`.

So any bill paid that way:
- never reaches `_foldActualsIntoOwners`,
- never marks its obligation paid,
- **and simultaneously** becomes a standalone `ForecastOwner.transfer` outflow.

The code's own comment at lines 53-54 states the intended rule:

> A debit that references a known obligation is that obligation's payment… the reference
> wins.

But `referencesObligation` is *computed* at lines 53-56 and only *consulted* at line 65 —
**below** the transfer branch. The reference never wins.

---

## Failing scenario

Obligation: "LIC Premium", ₹47,000, due 14 Aug, primary scope.

SMS: `Rs.47000 debited via NEFT to LIC OF INDIA on 14-Aug-26, Ref REF123`

Result:
- `transfer:sms-x` outflow of ₹47,000, **plus**
- the unpaid `gmailBill` dated event of ₹47,000

**The ledger subtracts ₹94,000 for one ₹47,000 bill.** Required-in-bank is overstated by
a full month's premium, and the user is told to hold cash they don't need.

---

## The fix

Two changes, both required:

1. **Evaluate `referencesObligation` first**, before the transfer lane. This honours the
   rule the comment already states.
2. **For transfer-typed debits, attempt the owner fold before falling back to the
   transfer lane.** A transfer that successfully folds into an owner must **not** also
   emit a `transfer:` item.

Be careful not to break the genuine case the transfer lane exists for: a real
primary→secondary transfer between the user's own accounts, which should be a transfer
item and must not be treated as spend. The discriminator is whether the debit matches a
known obligation, not whether the word "transfer" appears.

---

## Interaction with other tasks

TASK-15 wires up `TransferBridgeMatcher`, which is the other half of the transfer story.
These two tasks both touch the transfer classification path. Prefer doing **TASK-12
first** — it is the simpler, higher-severity fix — then TASK-15 on top.

---

## Tests to write first

Add to `test/reconciliation_matcher_test.dart`:

- [x] The LIC scenario above → **one** ₹47,000 outflow in the ledger, not two. The
      obligation is marked paid and no standalone `transfer:` item exists. — **RED**
      (obligation came back `unpaid`, with a second ₹47,000 transfer outflow)
- [x] Same, with `IMPS` instead of `NEFT`. — **RED**
- [x] Same, where the SMS body contains the word `transfer` but no reference — the
      amount+merchant+date match should still fold it into the obligation. — **RED**
- [x] **Regression guard:** a genuine primary→secondary self-transfer that matches **no**
      obligation still produces a `transfer:` item and is not treated as spend.
- [x] A NEFT debit that matches no obligation at all stays a transfer item (unchanged).

Rupee conservation is asserted on all five via TASK-14's helper — every reconcile in this
test file routes through the wrapper that calls it.

## How the fallback is decided

A transfer-typed debit now enters **both** lanes: it is offered to the fold, and it is held
as a transfer candidate. `_foldActualsIntoOwners` returns the `smsId`s that reached an
owner, and only the transfers absent from that set become `transfer:` items. So the
discriminator is what the plan asked for — whether the debit matched a known obligation —
rather than whether the word "transfer" appears in the body.

A debit that reaches an owner but is held for review (ambiguous, or reference-only with an
incompatible amount) also counts as folded and emits no transfer item: its rupees are named
by the owners' coverage lines, and emitting a transfer too would restore the double count.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `referencesObligation` is evaluated before the transfer lane
- [x] Transfer-typed debits attempt the owner fold before falling back
- [x] A folded transfer never also emits a `transfer:` item
- [x] Genuine self-transfers still classify as transfers
- [x] All five tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green — **700 passing** (was 695)
- [x] Suggested commit: `Fold NEFT and IMPS bill payments into their obligation`
