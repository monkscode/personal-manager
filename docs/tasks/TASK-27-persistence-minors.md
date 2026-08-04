# TASK-27 — Persistence minors (7 items)

**Severity:** Minor · **Phase:** 4 · **Depends on:** TASK-25 and TASK-26 merged first

Seven small items in the persistence slice. Independent; any order.

---

## M1 — truncated and now-false doc comment

`lib/data/sms_storage_schema.dart:130`

The v2 doc comment is cut off mid-word:

```
All statements are idempotent (`IF NOT
```

No closing paren, no following text. The claim is also **false as written** once v3 is
included, since `migrations[3]`'s two ALTERs are the exception.

- [x] Finish the sentence and scope the claim accurately.

**Note:** TASK-03 also fixes this as part of making the ALTERs idempotent. If TASK-03 is
merged, verify rather than redo — and after TASK-03 the idempotency claim becomes true
again, so say so.

> **Closed as already done, 2026-08-04.** Verified rather than redone, as the note directs.
> The comment now reads in full and its claim is accurate: *"Every step is idempotent: plain
> statements all use `IF NOT EXISTS`, and the two column additions — which SQLite cannot
> express that way — go through `MigrationStep.addColumn` so `applyMigration` skips them
> when the column is already present."* No change needed.

---

## M2 — `updated_at` written but never read

`lib/data/forecast_risk_decision_store.dart:57` writes `updated_at`, but `_fromRow`
(lines 61-75) never reads it, and `ForecastRiskDecision` has no field for it.

- [x] Either surface it on the model, or drop the column. Prefer surfacing — an audit
      timestamp on a user risk decision is worth having.

Surfaced as a nullable `ForecastRiskDecision.updatedAt`: null for a decision that has never
been stored, set from the row otherwise. The test was compile-blocked by the missing field,
so the field was added inert first and the RED captured behaviourally —
`which has 'updatedAt' with value <null>` — rather than asserted to have failed.

---

## M3 — `known_accounts_store` silently drops a VPA

`lib/data/known_accounts_store.dart:126-131`

`_matchWhere` joins its conditions with **`OR`**.

**Failing scenario:** adding an account with **both** a `last4` and a `vpaNorm`, when a row
already exists with only that `last4`, matches → returns early at line 98 → **the VPA is
never recorded.** The classifier then won't recognise that VPA as the user's own, so
self-transfers to it are misclassified as spend.

No test covers the combined-identifier case — `test/known_accounts_store_test.dart` only
ever passes one of the two.

Also: nothing at the DB level prevents duplicates. There is no UNIQUE constraint on `last4`
or `vpa_norm`, only the application-level check.

- [x] Merge identifiers into the existing row rather than returning early.
- [x] Add the combined-identifier test.
- [x] ~~Consider a UNIQUE constraint (needs a migration — coordinate with TASK-25).~~
      **Considered and rejected, with reason.** A UNIQUE constraint on `last4` or on
      `vpa_norm` alone would forbid a case that is legitimate and now tested: one bank
      account with two UPI handles needs two rows sharing a `last4`. A composite
      `UNIQUE(last4, vpa_norm)` would enforce nothing useful either, because SQLite treats
      NULLs as distinct in a UNIQUE index, so any number of `(NULL, x)` rows still pass.
      The merge logic is what makes duplicates not arise; a constraint would only convert a
      legitimate insert into a crash.

**Fixed:** the match is still an `OR` — that part is right, since either identifier
identifies the account — but a match no longer ends the call. Identifiers the matched rows
already hold are counted; anything missing is merged into a row whose corresponding column
is empty, and if every matched row already names a *different* account on that column, the
new identifier gets its own row. Overwriting would lose the first, returning early lost the
second. Five tests, four of which failed first (`Expected: true  Actual: <false>`, and
`Expected: 'me@ybl'  Actual: <null>`); the fifth — a repeat of an already-complete account
changing nothing — is a **guard**.

---

## M4 — `singleInstance` defaults to true with an in-memory path

`lib/data/sms_database.dart:24`

`singleInstance` is not set, so it defaults to `true`. Every test opens
`inMemoryDatabasePath` (`:memory:`), so two databases opened concurrently under that path
would silently be the **same** database.

Nothing does that today, but `test/transaction_repository_test.dart:165` and
`test/sms_analysis_snapshot_test.dart:261/319` open second handles and are one refactor
away from it.

- [x] Pass `singleInstance: false` in `openWithFactory`, or use unique temp files in tests.

Done in `openWithFactory`, which is **test-only** — grepped: nothing in `lib/` calls it
outside its own declaration, so production still opens through `open()` with sqflite's
default. RED: `Expected: empty  Actual: [{'key': 'probe', 'value': 'first'}]` — a row
written through one handle was visible through the other, because they were the same
database.

---

## M5 — `updateReviewStatus` nulls `review_reason` when omitted

`lib/data/transaction_repository.dart:169-173`

It unconditionally writes `review_reason`, so **omitting** the named argument *nulls* it.
`test/transaction_review_queries_test.dart:138-142` relies on this for confirm, but it
makes "update only the coverage bucket" impossible without also wiping the reason.

Also untested either way: `updateReviewStatus('a', dismissed)` at line 126 of that test
leaves `coverage_bucket` at `review_pending`. Probably fine — but nothing asserts it.

- [x] Only include the key when the caller passes it (sentinel or separate method).
- [x] Add the missing `coverage_bucket`-after-dismiss assertion.

`reviewReason` is now a three-state argument via a private sentinel: omitted preserves,
`null` clears, a value replaces. RED: `Expected: ReviewReason.dedupCollision  Actual:
<null>`.

The cost is that the parameter is typed `Object?`, so a wrong type is caught by an assert
rather than the compiler — consistent with TASK-20 M10's recorded decision that asserts in
this codebase are development-only. The alternatives were a wrapper class for one call site
or a second `bool clearReviewReason` parameter; both add more surface than the sentinel.

**Production behaviour is unchanged**: both call sites in `scan_review_page.dart` now pass
`reviewReason: null` explicitly, which is what they were getting implicitly. That is the
point — the clearing is now stated rather than being a side effect of leaving an argument
out. The `coverage_bucket`-after-dismiss assertion is a **guard**; it was already true.

---

## M6 — no `onConfigure`, so foreign keys stay off

`lib/data/sms_database.dart`

`PRAGMA foreign_keys` is never enabled. There are **no** foreign keys in this schema, so
this is informational only.

- [x] Add `onConfigure` enabling foreign keys **if** any FK is ever introduced. Record the
      decision here either way so the next person doesn't re-investigate.

**Decision: no `onConfigure`, and no test.** Confirmed by grep that `lib/data/` contains no
`REFERENCES` clause anywhere — every cross-table link (`dedupe_key`, `owner_key`, `sms_id`)
is a logical key resolved in Dart. The pragma would have nothing to enforce, and a test
asserting it is off would only pin an accident. The requirement is now recorded in the
`openOptions` doc comment, where someone adding a real foreign key will see it, rather than
only here.

---

## M7 — pin `libsqlite3` in CI

Not a code defect — an environmental risk worth closing.

`sqflite_common_ffi` resolves `libsqlite3.so.0` at runtime via `dart:ffi`. It is normally
present on `ubuntu-latest`, but a base-image change would surface as a confusing
`Invalid argument(s): Failed to load dynamic library` rather than a clear setup failure.

14 test files depend on this and **have never run on Linux**.

- [x] Add an `apt-get install -y libsqlite3-0` step to `.github/workflows/build-apk.yml`
      before `flutter test`.

> **One claim scoped:** "14 test files depend on this and have never run on Linux" is not
> verifiable from the working tree, and is probably wrong. The workflow triggers on push to
> this branch and runs `flutter test` on `ubuntu-latest`, and the sqflite-ffi tests arrived
> in `04bef7a`, which is an ancestor of the pushed remote head — so they have almost
> certainly run there and passed, meaning the library was present. That does not weaken the
> item: the step converts an invisible dependency on the base image into an explicit one,
> and a future image change into a clear setup failure rather than
> `Failed to load dynamic library` thrown from inside a test.

**Everything else in this slice is Linux-clean** — verified: all table and column names are
lowercase, `p.join` is used for every path (`sms_database.dart:13`,
`sms_migration_test.dart:42/145`), temp dirs go through `Directory.systemTemp.createTemp`,
and teardown ordering is LIFO-correct so the Windows-only "delete open file" hazard does
not exist on Linux either.

---

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] All seven items addressed, or explicitly closed with a reason recorded here —
      M1 closed as already fixed by TASK-03, M6 closed as a recorded decision, M3's UNIQUE
      sub-item rejected with reason; M2, M3, M4, M5, M7 implemented
- [x] Tests added for M3 and M5 — the ones with observable behaviour change (and for M2 and
      M4, which also change observable behaviour)
- [x] CI installs `libsqlite3-0` before running tests
- [x] `flutter analyze` clean, `flutter test` green — **888 passing** (876 before)
- [x] Suggested commit: `Tidy persistence edge cases and pin libsqlite3 in CI`

**Twelve tests added, nine of which failed first.** The three guards are named where they
appear: the repeat-of-a-complete-account no-op (M3), the coverage-bucket-after-dismiss
assertion (M5), and the never-stored-decision-has-no-timestamp case (M2).
