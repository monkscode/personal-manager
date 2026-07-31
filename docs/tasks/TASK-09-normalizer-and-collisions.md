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

- [ ] Two same-amount, same-day payments with **different** reference numbers both
      survive as separate transactions.
- [ ] Two same-amount, same-day payments with **no** distinguishing content produce a
      collision set for review — and **neither is dropped**.
- [ ] The same message ingested twice (identical `sms_id`) produces exactly one row.
      (This is real dedupe and must keep working.)

Add to `test/sms_ingestion_policy_test.dart`:

- [ ] Three duplicates A, B, C all land in **one** collision set with the same id.
- [ ] Ingest order A→B→C and C→B→A produce the **same** set id (order independence).
- [ ] All three members are flagged for review; none stays `autoAdded`.
- [ ] Four duplicates: all four flagged, one set.

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

- [ ] Normalizer keys on `refNumber` when present
- [ ] Indistinguishable rows go to `dedupCollision` review, never dropped
- [ ] Same-message dedupe path kept separate and clearly named
- [ ] `_collisionSetId` derived from the tuple only, order-independent
- [ ] Every collision member flagged
- [ ] The implementation-restating test replaced with behavioural assertions
- [ ] All seven tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Surface duplicate SMS as collision sets instead of dropping them`
