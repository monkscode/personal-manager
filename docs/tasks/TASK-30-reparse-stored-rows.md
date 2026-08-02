# TASK-30 — A parser fix never reaches already-stored rows

**Severity:** Critical · **Phase:** 1 (infrastructure for every later parser fix) ·
**Depends on:** TASK-09 (same `sms_id` path), TASK-29 (the first fix that needs it)

Not from the audit. Found on 2026-08-02 when TASK-29 fixed HDFC merchant capture and the
fix changed nothing on the device, because every affected row was already stored.

---

## The defect

`lib/services/sms_ingestion_policy.dart` — the first check in `_classify`:

```dart
if (smsIdMatches.any((txn) => txn.smsId == incoming.smsId)) {
  return IngestionDecision(action: IngestionAction.skipDuplicate, ...);
}
```

A message already in the table short-circuits to `skipDuplicate` and the stored row is
never touched again. The row keeps whatever the parser of the day produced — **forever**.

Every Phase-1 parser fix is therefore future-only:

| task | what it corrects | reaches stored rows? |
|---|---|---|
| TASK-06 | direction (EMI booked as income) | **no** |
| TASK-07 | HDFC/SBI UPI formats | only as *new* rows |
| TASK-08 | greedy merchant, card-as-bank | **no** |
| TASK-29 | HDFC `To` payee | **no** |

### Measured on live data

After Phase 1, the author's device held 383 rows, of which **210 were parsed by the
pre-Phase-1 parser** and could never be corrected. They carry the old greedy merchants,
the `merchant='card purchase'` fallback, and old directions. The forecast's historical
months are computed from them.

The user cannot fix this themselves. Clearing the app's data would work, but
`isFirstScan = existing.isEmpty` (`scan_controller.dart:59`), so a wipe sends **every**
row to the review queue — 383 manual confirmations — and destroys the confirmed/dismissed
decisions the user already made.

---

## Fix

Add `IngestionAction.refreshParse`. When a stored message is seen again:

- if `incoming.hasSameParseAs(stored)` → `skipDuplicate` exactly as before, so a rescan
  that corrects nothing writes nothing and stays idempotent;
- otherwise → rewrite the row from the fresh parse, carrying the user's decision across
  via `ParsedTxn.withDecisionsFrom(stored)`.

`withDecisionsFrom` is deliberately **not** `copyWith`. `copyWith` resolves every argument
with `?? this.x` and so cannot copy a *null* across: a confirmed row has a null
`reviewReason`, and a `copyWith` merge would leave the fresh parse's `parserUncertain` in
place and drag a resolved row back into review. Every decision field is assigned
unconditionally: `reviewStatus`, `reviewReason`, `autoAddedAt`, `collisionSetId`,
`coverageBucket`, `scanBatchId`.

`created_at` is read back and preserved — REPLACE would otherwise stamp the rescan's clock
over the date the message was first seen. (Related to TASK-26, which flags the same REPLACE
behaviour on the normal path; this task fixes it only for the refresh path.)

Refreshed rows join `persisted`, so a corrected merchant reaches recurring detection —
which is the point of re-parsing at all.

## Tests to write first

`test/sms_ingestion_policy_test.dart`:

- [x] A changed parse returns `refreshParse` and carries the new merchant. — **RED**
      (`skipDuplicate`)
- [x] The user's decision survives: a dismissed row stays dismissed. — **RED**
- [x] A resolved row does not inherit the fresh parse's `parserUncertain`. — **RED**
      (came back `needsReview`); this is the `copyWith`-cannot-clear trap
- [x] A resolved collision set id is preserved. — **RED** (came back null)
- [x] An unchanged parse is still `skipDuplicate`. — **green guard**, and the one that
      keeps a rescan from rewriting all 383 rows every time
- [x] A corrected direction reaches the stored row. — **RED**

`test/transaction_repository_test.dart`:

- [x] A refresh rewrites the row and does **not** duplicate it; status survives. — RED
- [x] `created_at` keeps the original date. — RED
- [x] A rescan correcting nothing writes nothing. — green guard

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `refreshParse` action added and handled in the orchestrator and repository
- [x] Decisions preserved across a re-parse, including nulls
- [x] `created_at` preserved
- [x] Unchanged parses still skip, so rescans stay idempotent
- [x] Refreshed rows feed recurring detection
- [x] `flutter analyze` clean, `flutter test` green — **688 passing** (was 679)
- [ ] Verified on-device: the 171 ownerless rows gain merchants after a rescan
- [x] Suggested commit: `Re-parse stored rows when the parser has since been corrected`
