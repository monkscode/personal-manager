# TASK-09 — Genuine duplicates silently dropped; collision sets fracture

**Severity:** Important ×2 · **Phase:** 1 · **Depends on:** TASK-04 (redaction changes the dedupe input)

Both defects violate the spec's **no silent exclusion** rule, in the ingestion layer.

---

## Defect 1 — the live normalizer silently drops genuine transactions

`lib/services/sms_live_normalizer.dart:37-62`

The dedupe key is `(amount, direction, localDate, redacted-body-text)`, and colliding rows
are **dropped with no collision set and no review**.

The spec is explicit on this point:

> Two genuine UPI payments of the same amount on the same day are common. Weak duplicates
> are **not** silently discarded — they are surfaced as a collision set for the user to
> resolve.

**Failing scenario.** Two ₹100 payments to the same payee on the same day whose *redacted*
bodies coincide. This is easy to hit: the redacted shape
`[amount] debited [account] Axis Bank` (see `test/merchant_display_test.dart:146`) carries
no distinguishing content at all. The two payments collapse to one and ₹100 of real spend
disappears.

It is mitigated only where a reference number or timestamp happens to survive redaction —
that is **luck, not design**, and TASK-04 changes what survives redaction, which can make
this worse.

### Fix

- Key on `refNumber` when one is present — that is the reliable discriminator.
- When two rows are genuinely indistinguishable, route them to a `dedupCollision` review
  state instead of dropping one.
- Never drop a row silently. If a drop is truly correct (exact same `sms_id`), that is
  deduplication of *the same message*, not of two transactions — keep those paths clearly
  separate in the code and name them differently.

---

## Defect 2 — collision sets fracture at three or more duplicates

`lib/services/sms_ingestion_policy.dart:91-112`

`_collisionSetId` mixes in `collision.first.smsId`. Walk through three duplicates:

1. A is stored. B arrives → both get set id **S1**.
2. C arrives → `collision.first` is A → A and C get set id **S2**, and `copyWith`
   overwrites A's id.
3. **B is now orphaned in a set of one.**

Additionally, only `collision.first` is ever flagged, so a 3rd and 4th stored duplicate
stay `autoAdded` and never surface for review.

### Fix

Derive the set id from the **tuple only** so it is order-independent:

```
amount | date | last4 | direction
```

Hash that. The id is then stable no matter what order messages arrive in, and re-running
ingestion is idempotent.

Then flag **every member** of `collision`, not just `first`.

---

## Tests to write first

Add to `test/sms_live_normalizer_test.dart`:

- [x] Two same-amount, same-day payments with **different** reference numbers both
      survive as separate transactions. — **RED** (collapsed to 1 row)
- [x] Two same-amount, same-day payments with **no** distinguishing content produce a
      collision set for review — and **neither is dropped**. — **RED** (collapsed to 1 row)
- [x] The same message ingested twice (identical `sms_id`) produces exactly one row.
      (This is real dedupe and must keep working.) — **green guard**, passed before the
      fix; it is what stops the new collision path from swallowing true re-deliveries.
- [x] *Added:* a collision the user already confirmed/dismissed is not re-opened on
      reload. Guard proven by deleting the `_undecided` check and watching it fail.

Add to `test/sms_ingestion_policy_test.dart`:

- [x] Three duplicates A, B, C all land in **one** collision set with the same id. — **RED** (2 sets)
- [x] Ingest order A→B→C and C→B→A produce the **same** set id (order independence). — **RED**
- [x] All three members are flagged for review; none stays `autoAdded`. — **green guard**
      (see the correction below)
- [x] Four duplicates: all four flagged, one set. — **RED** (3 sets)
- [x] *Added:* a row distinguishable from `collision.first` but identical to a later
      member still collides. — **RED** (`autoAdded`); this is the reachable form of the
      "3rd and 4th duplicate stay autoAdded" claim.

### Correction to this file's Defect 2 description

> "only `collision.first` is ever flagged, so a 3rd and 4th stored duplicate stay
> `autoAdded` and never surface for review"

Not true for a plain sequential ingest of identical duplicates: every row is `incoming`
at some point, so it flags itself. Verified against the author's own device database —
all 11 rows carrying a `collision_set_id` were flagged, none stayed `autoAdded`.

The leak is real but needs an asymmetry: A has a ref, B has none, C has a *different*
ref. `_hasDistinguishingSignal` only ever consulted `collision.first` (A), so C looked
distinguishable and was auto-added — even though nothing separates C from B. The fix
tests each candidate rather than just the first.

### Verified against live device data

Defect 2 reproduced in the wild before the fix (`adb`, 210 stored rows, 11 with a
`collision_set_id`): the tuple `200000|2026-01-06|1234|debit` held **3 rows across 2
collision sets**, one of them orphaned alone — exactly the A/B/C walkthrough above.
Recomputing with the tuple-only id collapses it to **1 set**, and leaves the four
healthy 2-row tuples at 1 set each.

Defect 1 did **not** lose money on this dataset: the old key dropped 5 rows at read
time, and all 5 carried an intra-body timestamp or RRN, so all 5 were genuine
re-deliveries. That is the "luck, not design" the defect describes — the new key drops
the same 5 for a *provable* reason. Re-running the new read-time pass over all 210 rows
flags **0** additional rows, so the review queue is not disturbed.

No migration is needed for the 11 existing rows: they are all `confirmed`/`dismissed`,
`sms_id` short-circuits re-ingestion, and the review screen only groups rows in the live
queue. Their stale ids are inert. Separately confirmed that TASK-04's salted `sms_id`
orphaned nothing — all 210 rows are `provider:<id>`, zero `synthetic:` rows.

Note `test/sms_ingestion_policy_test.dart:247-259` currently **recomputes
`_collisionSetId`'s exact join-and-hash**, so it passes for any implementation including
a broken one. Replace it: assert *stability* (same inputs → same id) and *set membership*
(all duplicates share one id), not the hash recipe.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Normalizer keys on `refNumber` when present
- [x] Indistinguishable rows go to `dedupCollision` review, never dropped
- [x] Same-message dedupe path kept separate and clearly named
      (`collapseRedeliveries` vs `flagCollisions`)
- [x] `_collisionSetId` derived from the tuple only, order-independent
      (now `SmsIngestionPolicy.collisionSetIdFor`, shared with the normalizer so an
      ingest-time set and a read-time set carry the same id)
- [x] Every collision member flagged — `existingToFlag` is now a `List<ParsedTxn>`
- [x] The implementation-restating test replaced with behavioural assertions
      (also closes the duplicate note at `TASK-11-parser-minors.md:90`)
- [x] All seven tests written failing-first, then passing — 5 genuinely RED, 2 green
      guards, honestly marked above; 2 further tests added, 1 RED and 1 guard
- [x] `flutter analyze` clean, `flutter test` green — 658 passing, 0 failing (was 649)
- [x] Suggested commit: `Surface duplicate SMS as collision sets instead of dropping them`
