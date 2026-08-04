# TASK-37 — One commitment, three stored obligations

**Severity:** Critical (measured double count) · **Phase:** 5 · **Depends on:** TASK-36

**Status: specified and reproduced, NOT implemented.** The reproduction is committed and
green as a characterisation test; the fix is a schema migration that rewrites rows holding
the user's own review decisions, and that is deliberately not being done as a tail-end
change. Read "Why this is not implemented yet" before starting.

---

## The defect

Obligations are derived from transactions and **never retired**.
`ObligationRepository` (`lib/data/obligation_repository.dart`) exposes `upsert`,
`allActive` and `updateReserveProgress` — there is no `delete`, no `retire`, no prune. The
scan orchestrator (`sms_scan_orchestrator.dart:192-216`) calls `derive` and then `upsert`s
each candidate. An obligation whose dedupe key stops being derived is simply never
mentioned again, and stays in the forecast forever.

Two things then compound:

1. **A parser fix orphans the obligation it created.** The dedupe key embeds the merchant:
   `'sms_recurring:${commitment.merchantNorm}:${commitment.cadence.name}'`
   (`recurring_obligation_candidates.dart:53-54`). When a parser fix changes what a body
   parses to, the next scan derives a *different* key. The old row cannot be refreshed by
   any future scan, because nothing will ever derive its key again.

2. **Mandate notices and detected commitments mint separate keys for the same payee** —
   `sms_mandate:<merchantNorm>` (`mandate_notice_obligations.dart:39`) versus
   `sms_recurring:<merchantNorm>:<cadence>`. Both are `ObligationSourceType.smsRecurring`.
   *This half is already on file as a TASK-32 finding* ("a `sms_mandate:<payee>` obligation
   is never retired once a commitment locks for that payee"); TASK-37 measures it.

The horizon dedupe cannot save it. `_projectCanonicalObligations`
(`forecast_adapter.dart:582-586`) collapses on `'${obl.dedupeKey}:${monthKey}'` — exact key
identity. Three different keys are three different events, by construction.

---

## Measured on the device, 2026-08-04

Nine stored obligations. Two commitments are stored more than once:

| Real commitment | Stored obligations | `review_status` |
|---|---|---|
| Google ₹1,999/mo | `sms_recurring:xfkxfma537eoyvuzwkvss3vbvbr1oxoo:monthly` | **confirmed** |
| | `sms_mandate:google` | needs_review |
| | `sms_mandate:google asia pacific pte.ltd` | needs_review |
| PhonePe ₹120.07/mo | `sms_recurring:ece9ae70c53842d58abf92660f4698af:monthly` | needs_review |
| | `sms_mandate:phonepe` | needs_review |

`xfkxfma537eoyvuzwkvss3vbvbr1oxoo` is unre-derivable: its five transactions
(ids 711, 752, 791, 827, 877) **already parse to `merchant = 'google'`**, fixed by an
earlier session — the comment at `sms_transaction_parser.dart:644-647` names this exact
token. The obligation was created 2026-08-02, before that fix and before TASK-33's reparse
took the store from 387 rows to 2,058. It has been stranded ever since, and it is the one
the user (or something) marked **confirmed**, so it is the copy that counts as a *hard*
commitment.

`ece9ae70c53842d58abf92660f4698af@ybl` is PhonePe (`@ybl`). **TASK-36 will strand this one
the same way**: from the next scan those 22 rows parse to
`bharat connect postpaid bill payment`, so `sms_recurring:ece9ae70…:monthly` joins the
orphan list. Fixing the parser without fixing retirement converts a bad label into a
permanent duplicate — which is exactly why these are two task files and not one.

### The double count, reproduced

`test/forecast_adapter_test.dart`, group `TASK-37`, feeding the three real Google
obligations through the real adapter:

```
Expected: <1>
  Actual: <3>
```

One ₹1,999 subscription, three September lines. The companion guard —
one obligation in, one line out — passes, so the fixture is sound and the 3 is the defect
rather than an artefact.

> **A premise I got wrong, recorded because it cost a cycle.** The first version of this
> measurement counted `outlook.months[1].events` and reported `Actual: <0>` for a single
> obligation. `months[].events` holds **hard events only** — a `needs_review` obligation at
> 0.7 confidence is partitioned into `riskLines` and never appears there. The count is only
> meaningful across *both* partitions, because the user sees both. The failing guard is
> what exposed it; had only the headline assertion been written it would have "passed" at
> 3-vs-3 for the wrong reason.

---

## The fix

**Retire, do not delete.** Add `retired_at` to `obligations` (**schema v5**, plus an
`indexStatements` entry per the Phase-4 rule that every index needs both a statement and a
version bump).

1. `RecurringObligationCandidates.derive` already computes the complete set of
   `sms_recurring:` keys it can currently derive. Any **stored** obligation whose key
   carries that prefix and is absent from that set cannot ever be refreshed → stamp
   `retired_at`.
   - Scope the sweep to the `sms_recurring:` prefix only. `sms_mandate:` keys come from a
     different generator that did not just run; retiring them on a recurring-scan would be
     unsound.
2. `upsert` clears `retired_at` when a key reappears, so a commitment that pauses and
   resumes is restored rather than lost.
3. `_projectCanonicalObligations` skips obligations with a non-null `retired_at`.
4. **The row and its `review_status` survive.** Nothing is deleted. This is the whole
   reason for a column rather than a `DELETE`: TASK-02 is a Critical about a scan
   destroying the user's obligation decisions, and a sweep that removed a *confirmed* row
   would be that defect wearing a different hat.
5. Emit a coverage line naming the retirement, so a commitment leaving the forecast is
   never silent.

### What this fix does and does not reach

It reaches **the stale half** — obligation #1, and #2 once TASK-36 strands it. That is the
half where "this key can never be derived again" is *provable* rather than inferred.

It does **not** merge `sms_mandate:google` with
`sms_mandate:google asia pacific pte.ltd`. Both are live, both are re-derivable, and
collapsing them needs merchant-identity resolution — the same unsolved problem as
TASK-34's `hdfc ltd` / `hdfc bank ltd` pair. So the Google triple becomes a *double*, not a
single. **Say so in the commit rather than claiming the duplicate is fixed.**

### Rejected: dedupe the horizon on amount + cadence + category

It would collapse all three today with no schema change, and it is wrong: two genuinely
different ₹1,999 monthly subscriptions in one category would be silently merged, losing
₹1,999 of real commitment. TASK-23 deliberately keyed its dedupe on label for this reason.
Trading a double count for an under-count is not an improvement.

---

## Why this is not implemented yet

Deliberate, and the reason is not effort:

- The sweep **writes to rows holding the user's own review decisions** (187 confirmed /
  109 needs_review / 6 dismissed on this device). TASK-02 is the Critical that already
  happened here once.
- It needs a **schema migration to v5**, which under this repo's rules means a fresh-create
  path, a migration path, and a drift test proving they are identical (TASK-25) — plus the
  `schemaVersion >= max(migrations.keys)` assertion added in Phase 4.
- It must be **device-verified against real data**, with row counts reconciled before and
  after, and the first run of a retirement sweep against a real store is exactly the
  operation that should not be rushed at the end of a long session.

The reproduction is committed and green, so nothing is lost by picking this up cold.

---

## Tests

Two added to `test/forecast_adapter_test.dart`, group `TASK-37`.

| Test | Kind | Note |
|---|---|---|
| `one stored obligation yields one September line (guard)` | **Guard** | Proves the fixture, so the 3 below is the defect and not the setup |
| `three stored obligations yield THREE September lines — documents the open defect, not the desired behaviour` | **Characterisation** | Asserts the current wrong number **on purpose**, so the suite stays honest and green. When the fix lands this test *should* fail — change 3 to 1 and move it out of the group. |

Neither is regression coverage and neither is claimed as such.

---

## Definition of done

- [x] Double count reproduced end-to-end against the device's real obligation set
- [x] Root cause traced to a missing retirement path, not to the dedupe
- [x] The `months[].events` measurement error found and recorded
- [ ] `retired_at` column added, schema v5, with fresh-vs-migrated drift test
- [ ] `derive` sweep retires unre-derivable `sms_recurring:` keys; `upsert` clears the stamp
- [ ] `_projectCanonicalObligations` skips retired obligations
- [ ] Coverage line names each retirement
- [ ] Device verification with row counts reconciled before and after
