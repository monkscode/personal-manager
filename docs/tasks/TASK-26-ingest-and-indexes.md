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

---

## Tests to write first

- [ ] Flagging an existing row **preserves** its `created_at` and its `id`.
- [ ] Flagging uses the injected `now`, not wall-clock time (assert determinism).
- [ ] Row ordering is stable after a flag operation.
- [ ] `EXPLAIN QUERY PLAN` for `recentlyAutoAdded` reports index use, not `SCAN`.
- [ ] `EXPLAIN QUERY PLAN` for `latestBalanceAnchor` reports index use, not `SCAN`.
- [ ] The rewritten scan test **fails** when an index is dropped (prove it guards
      something — this is the whole point of Defect 3).
- [ ] `ingestParsedTxn` atomicity still holds (regression guard on the good behaviour).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Flag path uses a targeted `update`, preserving `created_at` and `id`
- [ ] Injected `now` threaded through
- [ ] Both indexes added to `indexStatements` (plus `migrations[4]` if TASK-25 is not merged)
- [ ] Scan tests assert on `EXPLAIN QUERY PLAN`, and demonstrably fail without the indexes
- [ ] All seven tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Preserve transaction audit columns and index the unbounded queries`
