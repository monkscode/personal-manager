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
- [x] Verified on-device: refresh repairs a stored row, preserving decision and
      `created_at` — measured under a controlled edit, see below
- [x] Suggested commit: `Re-parse stored rows when the parser has since been corrected`

---

## On-device verification, 2026-08-02

Phase-2 build installed on the SM-G781B over the existing data (`adb install -r`, which
preserves the database) and refreshed from Home. Measured before and after.

**What is confirmed:**

- The **171** HDFC UPI rows this task was written about all carry merchants — `0`
  ownerless in that cohort. The outcome TASK-29 + TASK-30 were aiming at is present in the
  live data.
- **The rescan is idempotent, which is the guard that matters most here.** 384 rows before,
  386 after — the 2 additions are genuinely new messages. Nothing else was rewritten, and
  the user's decisions were untouched: **187 confirmed / 6 dismissed, identical before and
  after.** A rescan correcting nothing writes nothing, exactly as designed.

**What could not be exercised, and why:**

The `refreshParse` path never fired, because **no stored row's parse differs under this
build**. That was verified rather than assumed:

- The 174 rows created 2026-08-02 are *inserts*, not refreshes — messages the pre-TASK-07
  parser stored nothing for at all. Their `created_at` is new; a refresh preserves
  `created_at`, so these cannot be refreshes.
- The 210 older rows still hold 79 merchant-less rows, 45 `card purchase` merchants and
  20 reference-numbers-as-merchants. Those *look* like stale-parser artifacts and were
  initially read as such — wrongly. Feeding their real bodies to the **current**
  `parseOne` returns `merchant=null type=other dir=debit payee=unknown`, byte-identical to
  what is stored. `hasSameParseAs` is therefore right to return true and the refresh is
  right not to fire. These are **current parser gaps**, now recorded as
  [TASK-31](TASK-31-ownerless-merchant-formats.md) and
  [TASK-32](TASK-32-mandate-prenotification-double-count.md).
- Phase 2 changed the reconciliation layer, not `ParsedTxn`, so nothing in Phase 2 could
  have triggered a refresh either.

There is also no way to detect a *past* refresh after the fact: `transactions` has no
`updated_at`, and `created_at` is deliberately preserved. So whether the path ran during
the 2026-08-02 07:11 scan is unknowable from the stored data.

### Closing it: a controlled edit on the real database

Since no naturally-occurring row had a changed parse, one was made to. The full database
was pulled first as a backup, the app force-stopped, and a single row edited to look like
pre-fix parser output — merchant cleared, payee type dropped to `unknown` — while leaving
its `review_status` alone. The message body is a real HDFC UPI credit alert the current
parser reads correctly, so this is exactly the situation the task describes: a stored row
whose parse the present parser would improve.

Target: `sms_id = provider:12138`, a **user-confirmed** row.

| field | seeded state | after one pull-to-refresh | |
|---|---|---|---|
| `merchant` | `NULL` | `priyalpatel1910` | repaired |
| `payee_type` | `unknown` | `p2p_individual` | repaired |
| `review_status` | `confirmed` | `confirmed` | **decision survived** |
| `needs_review` | `0` | `0` | consistent |
| `created_at` | `1783717193076` | `1783717193076` | **not restamped** |
| row count | 386 | 386 | no duplicate |

Scope was checked, not assumed. Comparing the result against the pre-test backup across
`sms_id, merchant, payee_type, direction, type, amount_paise, review_status, created_at,
category_key, confidence`, **zero rows differ** — the app repaired the seeded damage and
touched nothing else. Decision totals were identical throughout: 191 auto-added,
187 confirmed, 6 dismissed, 2 needs-review.

So all four claims hold on real data: the refresh fires, the fresh parse lands, the user's
decision is carried across, and `created_at` is preserved.

**One observable side effect, not previously recorded.** The refreshed row's `id` changed
(42 → 697). The rewrite goes through `ConflictAlgorithm.replace`, which deletes and
reinserts, so `AUTOINCREMENT` issues a new rowid. Exactly one id changed — only the
refreshed row. This is benign here: nothing in `lib/` references `transactions.id`, there
is no foreign key or `transaction_id` column anywhere, and the stable identity is the
`sms_id UNIQUE` column. Worth knowing before anything ever keys on the rowid, and it is
the same REPLACE behaviour TASK-26 flags on the normal ingest path.

**Still true, and still the better end-to-end proof.** No *naturally* stale row exists on
this device — the 79 merchant-less rows are current parser gaps, not stale output. TASK-31
changes the parse of those 79 already-stored rows, and `refreshParse` is the only route by
which they can gain merchants, so verifying TASK-31 on the device will exercise this path
at population scale rather than on one seeded row. That check stays in TASK-31's
definition of done.
