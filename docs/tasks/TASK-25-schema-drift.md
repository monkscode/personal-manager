# TASK-25 — Fresh-create and migrated schemas differ

**Severity:** Important ×3 · **Phase:** 4 · **Depends on:** TASK-03 (same files)

Three findings that collapse into roughly **one change plus one test**. The test is the
valuable part — it catches all three and every future drift.

---

## Defect 1 — `onCreate` and `onUpgrade` produce different index sets

`lib/data/sms_database.dart:26-35` vs `:36-50`;
`lib/data/sms_storage_schema.dart:110-121` vs `:147`

- `onCreate` applies `indexStatements` — 10 entries, **none** touching
  `forecast_risk_decisions`.
- `migrations[3]` creates `idx_forecast_risk_target_month` (line 147), but it was **never
  added to `indexStatements`**.

Result:

| Path | Has `idx_forecast_risk_target_month`? |
|---|---|
| v1 → v3, or v2 → v3 | **Yes** |
| Fresh v3 install | **No** |

Functional impact today is small — `ForecastRiskDecisionStore.all()`
(`lib/data/forecast_risk_decision_store.dart:10-16`) sorts a table bounded by
owners × months. The reason this matters is **structural**: there is no shared source of
truth and no test comparing the two paths, so the *next* migration drifts the same way —
and next time it may be a UNIQUE index.

### The second, worse half

**`onUpgrade` never re-applies `indexStatements` at all**, so a database missing an index
can never self-heal — including `idx_obligations_dedupe_key`
(`sms_storage_schema.dart:118`), which is the **only** DB-level guard behind
`ObligationRepository`'s read-then-write.

`test/sms_migration_test.dart:47-59` proves the exposure: its v1 fixture creates only
`idx_transactions_txn_month`, and after upgrading to v3 that database **still has no
unique index on `obligations.dedupe_key`** — and the test does not notice.

> **Scoped 2026-08-04.** That demonstration is about the *fixture*, and the file reads as
> though it also describes real v1 installs. It cannot: `sms_storage_schema.dart` has only
> ever existed at v3 in this repo (`04bef7a`, then `02e330a`), so what a real v1 `onCreate`
> applied is unknowable from here — v1 and v2 are reconstructions. The structural claim is
> untouched by that and is the reason the fix is right: `onUpgrade` never applied
> `indexStatements`, so **any** index added to that list rather than to a migration reaches
> fresh installs only, forever. Confirmed against the source.
>
> **The prescribed fix was checked, not just the defect.** Re-running
> `CREATE UNIQUE INDEX ... ON obligations(dedupe_key)` over existing rows throws if
> duplicates are present, which would brick the app at open — worse than the drift it
> fixes. It cannot arise here: `ObligationRepository._toRow` writes `id`
> (`obligation_repository.dart:232`) and `_merge` preserves `existing.id` (`:74`), so the
> `ConflictAlgorithm.replace` insert replaces by primary key and cannot leave two rows
> sharing a dedupe key even on a database that never had the index. The exposure is
> theoretical, and the loud failure it would produce matches how TASK-03 chose to handle
> a rollback.

### Fix (closes both halves)

1. Add `idx_forecast_risk_target_month` to `indexStatements`.
2. In `onUpgrade`, **after** the migration loop, iterate `indexStatements` and execute
   each. Every statement is already `IF NOT EXISTS`, so this is idempotent and cheap.

---

## Defect 2 — `obligations` column order differs between paths

`lib/data/sms_storage_schema.dart:67-70` vs `:144-145`

The DDL declares `reserve_enabled` / `reserve_funded_paise` **before** `created_at` /
`updated_at`. But `ALTER TABLE ADD COLUMN` **appends** them after `updated_at`.

So fresh and migrated installs have different **physical column ordering**.

No functional break today — sqflite returns name-keyed maps, and nothing in scope does
positional access or a bare `INSERT INTO obligations VALUES (...)`.

**But it is a live landmine.** The standard SQLite 12-step table rebuild uses
`INSERT INTO obligations_new SELECT * FROM obligations`, which **is positional**. On
migrated installs that would silently write `created_at` into `reserve_enabled`.
Corruption with no exception.

`test/sms_migration_test.dart:167-169` cannot catch it — it asserts column **presence**
via a `Set`, which is order-insensitive by construction.

### Fix

Move the two reserve columns to the **end** of `createObligationsTable` so both paths
agree. One line, and it removes the landmine entirely.

---

## Defect 3 — the "v1" transactions fixture is the live v3 schema

`test/sms_migration_test.dart:52` and `:151`

The **obligations** fixtures were correctly frozen as literal constants
(`_createV1ObligationsTable:179`, `_createV2ObligationsTable:211`) — that is exactly the
right pattern.

The **transactions** fixture was not. Lines 52 and 151 seed the "v1" and "v2" databases
from `SmsStorageSchema.createTransactionsTable` — the **current** constant.

The instant anyone adds a column to `transactions`, the v1 fixture will already contain it
and the migration test will **pass vacuously** while real v1 installs break.

### Fix

Freeze the v1 (and v2) transactions DDL as literal constants alongside the obligations
ones.

---

## The test that catches all three

There is currently **no test** asserting that a fresh v3 database and a v1→v3 migrated
database have the same schema. That is precisely why Defects 1 and 2 are both live.

```dart
Future<Set<String>> schemaObjects(Database db) async {
  final rows = await db.rawQuery(
    "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
  );
  return rows.map((r) => '${r['type']}:${r['name']}:${_normalise(r['sql'])}').toSet();
}
```

Build both databases — one via fresh `onCreate` at v3, one by seeding the frozen v1 DDL
and upgrading — then assert the normalised `sqlite_master` contents are **equal**.

Normalise whitespace before comparing, since the two paths format DDL differently.

**This single test catches Defects 1, 2 and every future drift.** Write it first.

---

## Tests to write first

- [x] **The drift test above.** Expect it to fail on both the missing index and the column
      order — that is the point. Written for v1→v3 and v2→v3. RED on both: the migrated
      `sqlite_master` set was missing seven indexes the fresh one had, and its `obligations`
      DDL put `reserve_enabled` after `updated_at` while the fresh one put it before
      `created_at`.
- [x] v1 → v3 produces a database with a unique index on `obligations.dedupe_key`.
      RED: the migrated index set was
      `[sqlite_autoindex_transactions_1, sqlite_autoindex_meta_1, idx_transactions_ref,
      idx_known_accounts_last4, idx_known_accounts_vpa_norm,
      sqlite_autoindex_forecast_risk_decisions_1, idx_forecast_risk_target_month]` —
      no `idx_obligations_dedupe_key`.
- [x] A database artificially missing an index self-heals on the next open. Folded into the
      test above rather than duplicated: a v1 fixture that creates *no* indexes at all is
      the same assertion in its strongest form.
- [x] ~~The frozen v1 transactions DDL differs from the current constant.~~
      **Unimplementable as stated, and dropped.** No migration has ever altered
      `transactions`, so a correctly frozen v1 constant is byte-identical to the current one
      *today* — asserting they differ would fail immediately. Dart cannot assert at runtime
      that a fixture does not *reference* a constant when the strings are equal. Freezing
      the literal plus the drift test is what actually closes the hole: add a column to
      `transactions` without a migration and the fresh database gains it while the migrated
      one does not, so the drift test fails. That is the protection Defect 3 asked for.

Two more added, each failing first:

- [x] Every index created by a migration also appears in `indexStatements` — a pure-Dart
      check needing no database, which catches Defect 1 directly. RED:
      `Expected: empty  Actual: Set:['idx_forecast_risk_target_month']`.
- [x] The reserve columns land at the same *ordinal position* on both paths, asserted as an
      ordered list rather than a set, because the positional table rebuild is the actual
      hazard. RED: `at location [24] is 'created_at' instead of 'reserve_enabled'`.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `idx_forecast_risk_target_month` added to `indexStatements`
- [x] `onUpgrade` re-applies all `indexStatements` after migrating
- [x] Reserve columns moved to the end of the obligations DDL
- [x] v1 and v2 transactions DDL frozen as literal test constants
- [x] The fresh-vs-migrated `sqlite_master` equality test exists and passes
- [x] `flutter analyze` clean, `flutter test` green — **868 passing** (863 before)
- [x] Suggested commit: `Make fresh and migrated schemas identical and prove it with a drift test`

## Notes for the next person

- **SQLite persists `--` comments written inside a `CREATE TABLE` into `sqlite_master`.**
  The explanation for the column reordering was first written inside the DDL, and the drift
  test failed on it: the fresh schema text carried the comment and the migrated one did not.
  It now lives in a Dart doc comment above the constant. Anything explaining a table belongs
  outside the SQL string, or it becomes part of the stored schema and of every comparison
  against it.
- **Existing installs are unaffected by the column reorder.** Changing the DDL cannot move
  columns in a database that already exists; it only changes what *new* fresh installs
  create. The reorder moves fresh installs onto the order migrated installs — including the
  device — already have, so the two converge rather than diverge.
- The drift test normalises by removing whitespace entirely rather than collapsing it.
  `ALTER TABLE ADD COLUMN` splices the new column into the stored statement inline, so the
  two paths differ in spacing around commas and the closing paren. SQLite also strips
  `IF NOT EXISTS` when storing DDL, which is why both sides read `CREATE TABLE obligations`.
