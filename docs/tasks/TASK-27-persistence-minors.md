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

- [ ] Finish the sentence and scope the claim accurately.

**Note:** TASK-03 also fixes this as part of making the ALTERs idempotent. If TASK-03 is
merged, verify rather than redo — and after TASK-03 the idempotency claim becomes true
again, so say so.

---

## M2 — `updated_at` written but never read

`lib/data/forecast_risk_decision_store.dart:57` writes `updated_at`, but `_fromRow`
(lines 61-75) never reads it, and `ForecastRiskDecision` has no field for it.

- [ ] Either surface it on the model, or drop the column. Prefer surfacing — an audit
      timestamp on a user risk decision is worth having.

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

- [ ] Merge identifiers into the existing row rather than returning early.
- [ ] Add the combined-identifier test.
- [ ] Consider a UNIQUE constraint (needs a migration — coordinate with TASK-25).

---

## M4 — `singleInstance` defaults to true with an in-memory path

`lib/data/sms_database.dart:24`

`singleInstance` is not set, so it defaults to `true`. Every test opens
`inMemoryDatabasePath` (`:memory:`), so two databases opened concurrently under that path
would silently be the **same** database.

Nothing does that today, but `test/transaction_repository_test.dart:165` and
`test/sms_analysis_snapshot_test.dart:261/319` open second handles and are one refactor
away from it.

- [ ] Pass `singleInstance: false` in `openWithFactory`, or use unique temp files in tests.

---

## M5 — `updateReviewStatus` nulls `review_reason` when omitted

`lib/data/transaction_repository.dart:169-173`

It unconditionally writes `review_reason`, so **omitting** the named argument *nulls* it.
`test/transaction_review_queries_test.dart:138-142` relies on this for confirm, but it
makes "update only the coverage bucket" impossible without also wiping the reason.

Also untested either way: `updateReviewStatus('a', dismissed)` at line 126 of that test
leaves `coverage_bucket` at `review_pending`. Probably fine — but nothing asserts it.

- [ ] Only include the key when the caller passes it (sentinel or separate method).
- [ ] Add the missing `coverage_bucket`-after-dismiss assertion.

---

## M6 — no `onConfigure`, so foreign keys stay off

`lib/data/sms_database.dart`

`PRAGMA foreign_keys` is never enabled. There are **no** foreign keys in this schema, so
this is informational only.

- [ ] Add `onConfigure` enabling foreign keys **if** any FK is ever introduced. Record the
      decision here either way so the next person doesn't re-investigate.

---

## M7 — pin `libsqlite3` in CI

Not a code defect — an environmental risk worth closing.

`sqflite_common_ffi` resolves `libsqlite3.so.0` at runtime via `dart:ffi`. It is normally
present on `ubuntu-latest`, but a base-image change would surface as a confusing
`Invalid argument(s): Failed to load dynamic library` rather than a clear setup failure.

14 test files depend on this and **have never run on Linux**.

- [ ] Add an `apt-get install -y libsqlite3-0` step to `.github/workflows/build-apk.yml`
      before `flutter test`.

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

- [ ] All seven items addressed, or explicitly closed with a reason recorded here
- [ ] Tests added for M3 and M5 — the ones with observable behaviour change
- [ ] CI installs `libsqlite3-0` before running tests
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Tidy persistence edge cases and pin libsqlite3 in CI`
