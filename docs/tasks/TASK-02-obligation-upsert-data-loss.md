# TASK-02 — Every scan destroys the user's obligation decisions

**Severity:** Critical · **Phase:** 0 · **Depends on:** nothing

The obligations table's user-intent columns currently have a lifetime of **one scan**.

---

## The defect

`lib/data/obligation_repository.dart:17-32`

```dart
Future<void> upsert(ObligationRecord obligation, {DateTime? now}) async {
  final timestamp = now ?? DateTime.now();
  final existing = await byDedupeKey(obligation.dedupeKey);
  final obligationToUpsert = existing?.id != null
      ? obligation.copyWith(id: existing!.id)      // <-- carries forward ONLY id
      : obligation;
  await _db.insert(
    'obligations',
    _toRow(
      obligationToUpsert,
      createdAt: existing?.createdAt ?? obligation.createdAt,   // <-- and createdAt
      updatedAt: timestamp,
    ),
    conflictAlgorithm: ConflictAlgorithm.replace,               // <-- replaces everything else
  );
}
```

Only `id` and `created_at` survive. **Every other column comes from the incoming record.**

The caller is the scan loop. `lib/services/sms_scan_orchestrator.dart:163` calls
`obliRepo.upsert(candidate)` for each candidate produced by
`recurring_obligation_candidates.dart:_toObligation`, which builds a fresh
`ObligationRecord` from SMS history alone. It never sets the reserve fields (so they
take the model defaults `false` / `0` at `lib/data/obligation_models.dart:90-91`), and
it hardcodes `userCadenceStatus: algorithmDetected` (line 69) and
`reviewStatus: confirmed` (line 71).

---

## Why it matters

**Exact loss path.** The user opens an obligation and sets money aside →
`lib/data/transactions_notifier.dart:94` → `updateReserveProgress` writes
`reserve_enabled=1, reserve_funded_paise=1800000` (`obligation_repository.dart:85-94`).
The next SMS scan re-derives the same `dedupe_key`, and `upsert` REPLACEs the row with
`reserve_enabled=0, reserve_funded_paise=0`.

**The user's ₹18,000 of saved reserve progress is gone. No error, no UI signal.**

The same single line destroys, on every scan:

| Column | Reverts to | Consequence |
|---|---|---|
| `reserve_enabled`, `reserve_funded_paise` | `0`, `0` | Saved reserve progress wiped |
| `user_cadence_status` | `algorithm_detected` | A confirmed or dismissed cadence un-confirms |
| `review_status` | `confirmed` | **A user-dismissed obligation reappears** |
| `payment_status` | `unpaid` | A bill marked paid shows unpaid again |
| `amount_paid_paise`, `outstanding_paise` | `null` | Partial-payment record lost |

These are the only columns in the table that hold **user intent** rather than derived
data. Re-deriving them from SMS on every scan is the bug.

---

## The fix

Make **preserve** the default and overwriting opt-in. When `existing != null`, carry
the user-owned columns forward explicitly:

```dart
Future<void> upsert(ObligationRecord obligation, {DateTime? now}) async {
  final timestamp = now ?? DateTime.now();
  await _db.transaction((txn) async {
    final existing = await _byDedupeKey(txn, obligation.dedupeKey);
    final merged = existing == null
        ? obligation
        : existing.copyWith(
            // derived-from-SMS fields the scan is allowed to refresh:
            amountPaise: obligation.amountPaise,
            dueDay: obligation.dueDay,
            dueDate: obligation.dueDate,
            recurrence: obligation.recurrence,
            confidence: obligation.confidence,
            merchantNorm: obligation.merchantNorm,
            label: obligation.label,
            // everything else — reserve*, userCadenceStatus, reviewStatus,
            // paymentStatus, amountPaidPaise, outstandingPaise — is preserved
            // from `existing` by not being passed.
          );
    await txn.insert(
      'obligations',
      _toRow(merged, createdAt: existing?.createdAt ?? obligation.createdAt,
             updatedAt: timestamp),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  });
}
```

Adjust the "allowed to refresh" list against the real field set in
`lib/data/obligation_models.dart` — the principle is that anything a **user** can change
through the UI must never be sourced from the incoming scan record.

**Note:** `ObligationRecord.copyWith` uses `?? this.x` throughout, so it cannot *clear* a
nullable field. That is a separate finding (TASK-20) but it works in your favour here.

### Also fix in this task — transactionality

`upsert` currently does a read (`byDedupeKey`, line 19) then a write (line 23) as two
independent statements with **no transaction**. The UNIQUE index on `dedupe_key`
prevents an actual duplicate row today, so this is not corruption — but the fix above
turns it into a genuine read-modify-write that *must* be atomic. Wrap it, as shown.

`importLegacyManualEntries` (`obligation_repository.dart:55-70`) loops `upsert` per entry
with no wrapping transaction, so a failure partway leaves a partial import while the
returned count reflects only what completed. It runs once at first launch, migrating the
user's legacy `manualTx` payload, and a partial import is a state the user can neither
see nor retry cleanly. Wrap the whole loop in one transaction.

It also queries `byDedupeKey` twice per entry — once at line 63 and again inside
`upsert` at line 19. Hoist it by giving `upsert` an internal variant that accepts an
already-fetched `existing`.

---

## Tests to write first

`test/obligation_repository_test.dart:220-238` gets within one line of catching this —
it just never re-upserts afterward.

- [x] **The headline test.** `upsert(record)` → `updateReserveProgress(enabled: true,
      fundedPaise: 1800000)` → `upsert` the *same dedupe key* with a default-constructed
      record → assert `reserveEnabled == true` and `reserveFundedPaise == 1800000` survive.
- [x] Same shape for `userCadenceStatus`: set to `userConfirmed`, re-upsert, assert it
      is still `userConfirmed` and not `algorithmDetected`.
- [x] Same shape for `reviewStatus`: set to `dismissed`, re-upsert, assert the
      obligation stays dismissed and does **not** reappear as `confirmed`.
- [x] Same shape for `paymentStatus` + `amountPaidPaise` + `outstandingPaise`.
- [x] Derived fields DO refresh: upsert with `amountPaise: 500000`, re-upsert the same
      dedupe key with `amountPaise: 750000`, assert the stored amount is 750000.
- [x] `importLegacyManualEntries` with a mid-list failure leaves **zero** rows
      committed (inject a failure via a wrapper database or a duplicate-id entry).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `upsert` preserves all user-intent columns when a row already exists
- [x] `upsert` read+write is inside one transaction
- [x] `importLegacyManualEntries` wraps its whole loop in one transaction
- [x] Duplicate `byDedupeKey` lookup removed
- [x] All six tests above written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Preserve user obligation decisions across SMS rescans`
