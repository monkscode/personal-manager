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

- [ ] **The drift test above.** Expect it to fail on both the missing index and the column
      order — that is the point.
- [ ] v1 → v3 produces a database with a unique index on `obligations.dedupe_key`.
- [ ] A database artificially missing an index self-heals on the next open.
- [ ] The frozen v1 transactions DDL differs from the current constant (a guard that the
      fixture really is frozen).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `idx_forecast_risk_target_month` added to `indexStatements`
- [ ] `onUpgrade` re-applies all `indexStatements` after migrating
- [ ] Reserve columns moved to the end of the obligations DDL
- [ ] v1 and v2 transactions DDL frozen as literal test constants
- [ ] The fresh-vs-migrated `sqlite_master` equality test exists and passes
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Make fresh and migrated schemas identical and prove it with a drift test`
