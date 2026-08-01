# TASK-03 — A version rollback permanently bricks the database

**Severity:** Critical · **Phase:** 0 · **Depends on:** nothing

Unrecoverable, total loss of the user's transaction history. Must be fixed before v3
reaches any device.

---

## Timing — you have a free window

`git ls-files` returns nothing for the entire SMS layer: it has **never been committed**,
so no v1 or v2 install exists in the wild today. That lowers the blast radius *right
now*. It does not lower the severity — the moment v3 ships, this becomes live and
unrecoverable.

---

## The defect

Two facts combine.

**Fact 1 — the v3 migration is not idempotent.** SQLite has no
`ALTER TABLE ... ADD COLUMN IF NOT EXISTS`. `lib/data/sms_storage_schema.dart:143-148`
contains the only two non-idempotent statements in the whole migration set (every
`CREATE TABLE` / `CREATE INDEX` correctly uses `IF NOT EXISTS`):

```sql
ALTER TABLE obligations ADD COLUMN reserve_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE obligations ADD COLUMN reserve_funded_paise INTEGER NOT NULL DEFAULT 0;
```

**Fact 2 — there is no `onDowngrade`.** `lib/data/sms_database.dart:24-51` sets
`version`, `onCreate` and `onUpgrade` — and nothing else. Because this code calls
`databaseFactory.openDatabase(path, options: ...)` **directly**, it bypasses the
`onDowngrade ??= onDatabaseVersionChangeError` normalisation that the top-level
`openDatabase()` helper applies.

What sqflite actually does with a null `onDowngrade`
(`sqflite_common-2.5.11/lib/src/database_mixin.dart:1155-1170`):

```dart
} else if (options.version! < oldVersion) {
  if (options.onDowngrade != null) { ... }   // null -> nothing happens
}
if (oldVersion != options.version) {
  await setVersion(options.version!);        // ...but the version is written DOWN anyway
}
```

---

## Why it matters — the exact break

1. Install is on **v3**. `obligations` physically has `reserve_enabled` and
   `reserve_funded_paise`.
2. User gets an older build — staged-rollout halt, rollback, or a sideloaded older APK.
   It opens with `version: 2`. Since `2 < 3` and `onDowngrade` is null, **no schema
   change happens, but `setVersion(2)` still runs.** The database now *reports* v2 while
   *physically* being v3.
3. User updates forward again. `onUpgrade(db, 2, 3)` runs `migrations[3]` →
   `ALTER TABLE obligations ADD COLUMN reserve_enabled ...` →
   `DatabaseException: duplicate column name: reserve_enabled`.
4. `database_mixin.dart:1186-1190` closes the database and rethrows. **Every subsequent
   open repeats it. The app can never open its database again.**

The only recovery is "clear app data" — and this database is deliberately excluded from
Android backup (`allowBackup="false"` plus the backup-rules exclusion, per
`docs/2026-07-08-sms-actuals-layer-design/02-data-ingestion-storage-parser.md:81-82`).
**There is no backup to restore from.** The user loses their entire transaction history
permanently.

---

## The fix — three parts, all required

### 1. Set an explicit `onDowngrade`

Never leave it null. Two acceptable choices:

- `onDatabaseDowngradeDelete` — documented and destructive, but at least recoverable.
- A custom handler that **throws a clear, named error**, so the failure is loud at
  rollback time rather than silent-then-fatal one update later.

Prefer the custom throw: a user who rolls back deserves a comprehensible failure, not a
silently wiped database. Whichever you choose, document the reasoning in a comment.

### 2. Make the v3 ALTERs idempotent

Guard them by reading the current columns first:

```dart
Future<void> _addColumnIfMissing(
  Database db, String table, String column, String ddl,
) async {
  final info = await db.rawQuery('PRAGMA table_info($table)');
  final existing = info.map((r) => r['name'] as String).toSet();
  if (!existing.contains(column)) {
    await db.execute(ddl);
  }
}
```

This makes the entire migration set idempotent and self-healing, so even a database
that already reached the bad state in step 2 above can recover.

Note `PRAGMA table_info` cannot take a `?` placeholder for the table name, so the table
name must be interpolated — that is safe here because it is a compile-time literal, never
user input. Add a comment saying so.

### 3. Fix the stale doc comment

`lib/data/sms_storage_schema.dart:130` — the v2 doc comment is truncated mid-word:

```
All statements are idempotent (`IF NOT
```

No closing paren, no following text. The claim is also **false as written** once v3 is
included, since `migrations[3]`'s two ALTERs are the exception. Finish the sentence and
scope the idempotency claim accurately (after fix 2, it becomes true again — say so).

---

## Tests to write first

Add to `test/sms_migration_test.dart`:

- [x] **The regression test.** Open at v3 → close → reopen forcing `version: 2` → close
      → reopen at v3. Assert it succeeds and the `obligations` table has exactly one
      `reserve_enabled` column.
- [x] Running `migrations[3]` twice against the same database succeeds (idempotency,
      directly).
- [x] A genuine downgrade attempt surfaces the chosen behaviour: either the named error
      is thrown, or (if you chose delete) the database is recreated empty at v2.
- [x] `_addColumnIfMissing` adds the column when absent and is a no-op when present.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `onDowngrade` explicitly set in `_openOptions`, with a comment explaining the choice
- [x] Both v3 ALTERs guarded by a column-existence check
- [x] `sms_storage_schema.dart:130` doc comment completed and accurate
- [x] All four tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Guard schema migrations against rollback and re-application`
