# TASK-26 — REPLACE resets `created_at`; missing indexes; a test that guards nothing

**Severity:** Important ×3 · **Phase:** 4 · **Depends on:** TASK-25 (index plumbing)

---

## Defect 1 — the ingest flag path resets `created_at` and churns the row id

`lib/data/transaction_repository.dart:64-68, 78-88`

`_insertRow` always uses `ConflictAlgorithm.replace`. On `transactions`, `sms_id` is
UNIQUE, so re-inserting an existing row makes SQLite **delete and re-insert** it.

Two consequences:

1. **`created_at` is overwritten.** Line 65 passes `DateTime.now()` for the *existing* row
   being flagged, so the original creation timestamp — an audit column the spec defines at
   `docs/2026-07-08-sms-actuals-layer-design/02-data-ingestion-storage-parser.md:64` — is
   destroyed the moment a later SMS collides with it.
2. **The `AUTOINCREMENT` id changes.** Every read query in this file uses `id ASC` or
   `id DESC` as the ordering tiebreak (lines 108, 118, 130, 141, 154, 191, 207), so a
   flagged row silently **jumps to the end of its date group** in the UI.

Line 65 also passes `DateTime.now()` rather than the injected `now`, unlike line 68 which
threads it correctly — so this path is **non-deterministic in tests**.

> **Scoped 2026-08-04.** Only the `existingToFlag` loop is still live. The *other* write in
> this method — the `refreshParse` path the file describes at line 68 — was fixed by
> TASK-30 and now reads the stored `created_at` back before rewriting. Both halves of the
> defect were confirmed on the remaining path: the RED test read `created_at` as
> `2026-08-04 11:44:34.498` (wall-clock, not the injected `now`, not the stored
> `2026-01-01`) and the row id as `3` where it had been `1`.

### Fix

For the flag-existing-row path, use a targeted update instead of a full REPLACE insert:

```dart
await executor.update(
  'transactions',
  { /* only the review fields */ },
  where: 'sms_id = ?',
  whereArgs: [smsId],
);
```

That preserves `created_at` and the id, and is a smaller write. If REPLACE must stay for
some reason, read the existing `created_at` first and write it back.

Also thread the injected `now` through line 65.

**Note the good part — do not regress it.** `ingestParsedTxn`
(`transaction_repository.dart:17-71`) wraps the candidate reads *and* both writes in one
`_db.transaction`. The flag-the-existing-row and insert-the-new-row pair cannot
half-apply. That is the hard part of ingest and it is already correct.

---

## Defect 2 — two queries on the unbounded `transactions` table have no supporting index

`lib/data/transaction_repository.dart:148-157` and `:195-218`

**`recentlyAutoAdded`** filters on `review_status` (indexed) but orders by
`auto_added_at DESC`. `auto_added` is the **majority** status for a healthy install, so
this filters to nearly the whole table and then sorts it — to return 50 rows. Cost grows
linearly with history, forever.

**`latestBalanceAnchor`** filters on `instrument`, `account_last4` and
`balance_paise IS NOT NULL` — **none indexed** — ordered by `txn_date DESC LIMIT 1`.
SQLite will likely walk `idx_transactions_txn_date` in reverse and stop at the first match,
which is fast *if* the primary account has a recent balance SMS. If it does not, **this
walks the entire table.** It runs on every snapshot load via
`lib/data/transactions_notifier.dart:35`.

The spec's promised index list
(`docs/2026-07-08-sms-actuals-layer-design/02-data-ingestion-storage-parser.md:66-67`) is
**fully honoured** — this is beyond it, not a gap against it.

### Fix

```sql
CREATE INDEX IF NOT EXISTS idx_transactions_auto_added
  ON transactions(review_status, auto_added_at);
CREATE INDEX IF NOT EXISTS idx_transactions_account_instrument
  ON transactions(account_last4, instrument, txn_date);
```

Add them to `indexStatements`. **If TASK-25 is merged**, that is sufficient — `onUpgrade`
will re-apply them to existing databases. If not, you also need a `migrations[4]` entry.

> **Wrong, corrected 2026-08-04. TASK-25 being merged is *not* sufficient.** `onUpgrade`
> fires only when the stored version is older than the code's. TASK-25 made it converge on
> `indexStatements`, but an install already at v3 opened against a build still declaring
> v3 never calls `onUpgrade` at all — so adding an index to the list without bumping
> `schemaVersion` reaches fresh installs only. That is precisely the drift TASK-25 exists
> to prevent, re-introduced by the instruction meant to rely on it. The device database is
> at v3, so following this literally would have left the phone permanently without both
> indexes.
>
> Done instead: added to `indexStatements` **and** registered as `migrations[4]` with
> `schemaVersion` bumped to 4. Every future index needs both.
>
> A test now guards the direction nothing covered: `schemaVersion` must be at least the
> highest registered migration key. The existing test only checked the opposite direction
> (every version ≤ current has a migration), so a migration added without a bump would
> silently never run.

---

## Defect 3 — the "no full-table scan" test does not test for a full-table scan

`test/transaction_repository_test.dart:164-209`, assertion at `:203-207`

`_CountingDatabase.rowsRead` accumulates `result.length` (line 277) — the number of rows
**returned**, not the number **scanned**.

The three candidate queries in `ingestParsedTxn` are written to match nothing in this
scenario, so `rowsRead` is near zero **regardless of the query plan**.

**Drop every index and this test still passes.** It currently guards nothing.

### Fix

Assert on the **plan**, not the result size:

```dart
final plan = await db.rawQuery(
  'EXPLAIN QUERY PLAN SELECT * FROM transactions WHERE ref_number = ? AND ...',
  [...],
);
expect(plan.first['detail'], contains('USING INDEX'));
expect(plan.first['detail'], isNot(startsWith('SCAN')));
```

Apply the same shape to the two queries in Defect 2 once their indexes exist — that turns
the index work into something a test actually protects.

> **The prescribed assertions would themselves have passed vacuously.** Measured before
> adding the indexes, the two plans were:
>
> | Query | Plan before the fix |
> |---|---|
> | `recentlyAutoAdded` | `SEARCH transactions USING INDEX idx_transactions_review_status (review_status=?) \| USE TEMP B-TREE FOR ORDER BY` |
> | `latestBalanceAnchor` | `SCAN transactions USING INDEX idx_transactions_txn_date` |
>
> `contains('USING INDEX')` is true of both — a full scan *through* an index still says
> "USING INDEX". `isNot(startsWith('SCAN'))` is also true of `recentlyAutoAdded`. So the
> replacement test would have guarded no more than the one it replaced. Defect 3's own
> lesson applied to Defect 3's own fix.
>
> What actually discriminates: **`recentlyAutoAdded` must show no `TEMP B-TREE`** (the
> filter was already indexed; the *sort* was the cost) and **`latestBalanceAnchor` must
> show no `SCAN`**. Both tests also name the specific index, and a third test drops both
> indexes and asserts the plans degrade — proving the assertions bite.

---

## Tests to write first

- [x] Flagging an existing row **preserves** its `created_at` and its `id`.
      RED on `created_at`: `Expected: 2026-01-01  Actual: 2026-08-04 11:44:34.498`.
      RED on `id`: `Expected: <1>  Actual: <3>`.
- [x] ~~Flagging uses the injected `now`, not wall-clock time.~~ Subsumed and **dropped as a
      separate test**: the fix writes no timestamp on this path at all, so there is no
      clock left to inject. The `created_at` test above already fails against wall-clock
      time, and its RED value *is* the wall clock, which is the same evidence.
- [x] Row ordering is stable after a flag operation. Needed a third row to be a real test:
      with only the colliding pair the re-issued id still sorts last, so the assertion
      would have passed either way. Seeding an unrelated row between them makes the
      flagged row jump behind it. RED: order was `[b, a, c]`, expected `[a, b, c]`.
- [x] `EXPLAIN QUERY PLAN` for `recentlyAutoAdded` reports index use, not `SCAN`.
      Rewritten to assert **no `TEMP B-TREE`** — see the correction above. RED:
      `does not contain 'idx_transactions_auto_added'`.
- [x] `EXPLAIN QUERY PLAN` for `latestBalanceAnchor` reports index use, not `SCAN`. RED:
      `Actual: 'SCAN transactions USING INDEX idx_transactions_txn_date'`.
- [x] The rewritten scan test **fails** when an index is dropped (prove it guards
      something — this is the whole point of Defect 3). Written as its own test: drop both
      indexes, assert the plans degrade to `TEMP B-TREE` and `SCAN`.
- [x] `ingestParsedTxn` atomicity still holds. **Labelled a guard** — the reads and both
      writes already shared one `_db.transaction`, so it passed before the fix. Written
      with a wrapper whose insert of one specific `sms_id` throws, asserting the flag is
      rolled back with it.

One more added:

- [x] Only the review columns of the flagged row change. Asserts the exact set
      `{review_status, needs_review, review_reason, collision_set_id, coverage_bucket}` by
      diffing the whole row before and after, so any future widening of the write shows up.
      RED: `Which: larger than expected`.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Flag path uses a targeted `update`, preserving `created_at` and `id`
- [x] Injected `now` threaded through — better: the path no longer writes a timestamp
- [x] Both indexes added to `indexStatements` **and** registered as `migrations[4]` with
      `schemaVersion` bumped to 4 (the "TASK-25 makes this unnecessary" instruction was
      wrong — see the correction above)
- [x] Scan tests assert on `EXPLAIN QUERY PLAN`, and demonstrably fail without the indexes
- [x] All seven tests written failing-first, then passing — six of the eight failed first;
      the atomicity test is labelled a guard, and the version-bump test guards a direction
      nothing covered
- [x] `flutter analyze` clean, `flutter test` green — **876 passing** (868 before)
- [x] Suggested commit: `Preserve transaction audit columns and index the unbounded queries`
