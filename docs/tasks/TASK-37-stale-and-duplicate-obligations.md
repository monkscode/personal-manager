# TASK-37 — One commitment, three stored obligations

**Severity:** Critical · **Phase:** 5 · **Depends on:** TASK-36

**Status: implemented.** Reproduced first, then fixed by retiring keys nothing can derive.
The remaining `sms_mandate:` duplicate is explicitly *not* fixed — see "What this does not
reach".

---

## The defect

Obligations were derived from transactions and **never retired**.
`ObligationRepository` exposed `upsert`, `allActive` and `updateReserveProgress` — no
`delete`, no prune. The scan orchestrator called `derive` then `upsert`ed each candidate.
An obligation whose dedupe key stopped being derived was simply never mentioned again, and
projected into the forecast forever.

Two things compounded it:

1. **A parser fix orphans the obligation it created.** The dedupe key embeds the merchant:
   `'sms_recurring:${commitment.merchantNorm}:${commitment.cadence.name}'`
   (`recurring_obligation_candidates.dart:53-54`). When a parser fix changes what a body
   parses to, the next scan derives a *different* key. The old row can never be refreshed,
   because nothing will ever derive its key again.

2. **Mandate notices and detected commitments mint separate keys for one payee** —
   `sms_mandate:<merchantNorm>` versus `sms_recurring:<merchantNorm>:<cadence>`, both
   `ObligationSourceType.smsRecurring`. *Already on file as a TASK-32 finding*; TASK-37
   measured it.

The horizon dedupe cannot help. `_projectCanonicalObligations` collapses on
`'${obl.dedupeKey}:${monthKey}'` — exact key identity. Three keys are three events by
construction, and that is correct for three genuinely different commitments.

---

## Measured on the device, 2026-08-04

Nine stored obligations; two commitments stored more than once:

| Real commitment | Stored obligations | `review_status` |
|---|---|---|
| Google ₹1,999/mo | `sms_recurring:xfkxfma537eoyvuzwkvss3vbvbr1oxoo:monthly` | **confirmed** |
| | `sms_mandate:google` | needs_review |
| | `sms_mandate:google asia pacific pte.ltd` | needs_review |
| PhonePe ₹120.07/mo | `sms_recurring:ece9ae70c53842d58abf92660f4698af:monthly` | needs_review |
| | `sms_mandate:phonepe` | needs_review |

`xfkxfma537eoyvuzwkvss3vbvbr1oxoo` is unre-derivable: its five transactions (ids 711, 752,
791, 827, 877) **already parse to `merchant = 'google'`**, fixed by an earlier session —
`sms_transaction_parser.dart:644-647` names this exact token. The obligation was created
2026-08-02, before that fix. It is the copy marked **confirmed**, so it is the one that
counts as a *hard* commitment.

**Rendered on the device** in the why-log's RECURRING section: `phonepe ₹120` and
`ece9ae70… ₹120` both dated 29 Aug, plus three separate ₹1,999 Google lines.

### The double count, reproduced

```
Expected: <1>
  Actual: <3>
```

> **A premise I got wrong, recorded because it cost a cycle.** The first version counted
> `outlook.months[1].events` and reported `Actual: <0>` for a single obligation.
> `months[].events` holds **hard events only** — a `needs_review` obligation at 0.7
> confidence is partitioned into `riskLines` and never appears there. The count is only
> meaningful across *both* partitions. A **guard** — one obligation in, one line out —
> is what exposed it; without it the headline would have read 3-vs-3 and "passed" for
> entirely the wrong reason.

---

## The fix — retire, never delete

**Schema v5** adds `retired_at INTEGER` to `obligations`, declared last in
`createObligationsTable` so a fresh install matches a migrated one (TASK-25), and added by
`MigrationStep.addColumn` so re-running is safe.

1. **`ObligationCandidateSource.sweptKeyPrefixes`** — the prefixes a source enumerates
   *exhaustively* on every `derive`, and therefore authorises retirement within.
   `RecurringObligationCandidates` returns `{'sms_recurring:'}`; `NoObligationCandidates`
   returns `{}`.
   Deliberately **abstract with no default**: a retirement sweep is destructive enough that
   every source should have to state its answer, and `implements` makes the compiler ask.
   It did — the test stub failed to compile until it declared one.
2. **`ObligationRepository.retireUnderivable`** stamps rows under a swept prefix that the
   caller did not return. Rows already retired keep their original timestamp.
3. **`_merge` treats `retiredAt` as derived**, so an upsert on the same key clears it — a
   commitment that pauses for a cycle and resumes comes back rather than staying dead.
   This is why `_merge` constructs explicitly instead of using `copyWith`: `copyWith`
   resolves with `?? this.x` and cannot carry a null across. `copyWith` deliberately does
   **not** accept `retiredAt` at all, so it can never set a retirement it cannot clear.
4. **`_projectCanonicalObligations` skips retired rows.**
5. **`CoverageReason.retiredObligation`** names each one, so a commitment leaving the
   forecast is never silent — the "no silent exclusion" invariant. Dismissed rows are
   excluded from the coverage line: the user already said they did not want it.
6. **Nothing is deleted.** The row keeps its id, `review_status`, reserve progress and
   `created_at`. A sweep that discarded those would be TASK-02 — the Critical this
   repository already had once — wearing a new hat.

### What this does not reach

It fixes **the stale half**, where "this key can never be derived again" is *provable*.

It does **not** merge `sms_mandate:google` with `sms_mandate:google asia pacific pte.ltd`.
Both are live and both re-derivable, so both survive retirement. **The Google triple
becomes a double, not a single.** Merging them needs merchant-identity resolution — the
same unsolved problem as `hdfc ltd` / `hdfc bank ltd` (TASK-34) and `Bharat Connec`
(TASK-39).

### Rejected: dedupe the horizon on amount + cadence + category

It would collapse all three with no schema change, and it is wrong: two genuinely different
₹1,999 monthly subscriptions in one category would be silently merged, losing ₹1,999 of
real commitment. TASK-23 keyed its dedupe on label for this reason. Trading a double count
for an under-count is not an improvement.

---

## Tests — 12 added

**A TDD deviation, stated rather than hidden.** The schema and repository plumbing was
written before its tests. RED was therefore established the same way TASK-35's unit tests
were: by reverting the mechanism (an early `return 0` in `retireUnderivable`) and
re-running. That produces the same evidence as writing the test first, and the split below
is measured, not asserted.

`test/obligation_repository_test.dart` — group `TASK-37`:

| Test | Kind |
|---|---|
| `stamps a stored key the scan did not derive` | Regression |
| `never touches a key outside the swept prefixes` | **Guard** (passes either way) |
| `an empty prefix set retires nothing at all` | **Guard** (passes either way) |
| `keeps the review status and the row id` | Regression |
| `an upsert on the same key clears the stamp` | Regression |
| `a second sweep keeps the original timestamp` | Regression |

`test/sms_scan_orchestrator_test.dart` — group `TASK-37`: a stored key the source stopped
deriving is retired; a source that sweeps nothing retires nothing (**guard**); deriving the
key again brings it back.

`test/forecast_adapter_test.dart` — group `TASK-37`: retiring the stranded one takes it out
of the forecast (3 lines → 2); and names it in a `retiredObligation` coverage line.

`test/sms_migration_test.dart`: a v2 obligation upgrades to v5 keeping its data, with
`retired_at` **null** — a migration that defaulted it to a timestamp would drop every
obligation out of the forecast at once.

The pre-existing fresh-vs-migrated drift tests (TASK-25) cover v5 unchanged, because
`retired_at` is declared last and `ALTER TABLE` appends.

---

## Definition of done

- [x] Double count reproduced end-to-end against the device's real obligation set
- [x] Root cause traced to a missing retirement path, not to the dedupe
- [x] The `months[].events` measurement error found and recorded
- [x] `retired_at` column added, schema v5, drift tests still green
- [x] `sweptKeyPrefixes` declared per source, abstract so it cannot be forgotten
- [x] Sweep retires unre-derivable `sms_recurring:` keys; `upsert` clears the stamp
- [x] `_projectCanonicalObligations` skips retired obligations
- [x] `CoverageReason.retiredObligation` names each retirement
- [x] 12 tests, 3 honestly labelled guards, RED established by reverting the mechanism
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 916 passing, 0 failing (was 904)
- [x] Migration verified on the device against real data (below)
- [ ] **The device sweep has not run.** Installing migrates v4 → v5 and nothing else; the
      retirement only happens on the next scan, which is the user's call. Until then the
      device still holds all nine obligations and still shows the ₹1,999 triple.

---

## Device migration, 2026-08-04

Samsung SM-G781B. Built, `adb install -r`, launched to trigger `onUpgrade`. **No scan**, so
no retirement ran — this verifies the migration alone.

| | Before | After |
|---|---|---|
| `user_version` | 4 | **5** |
| transactions / `MAX(id)` / `MIN(id)` | 2061 / 2716 / 14 | 2061 / 2716 / 14 |
| auto_added / confirmed / needs_review / dismissed | 1759 / 187 / 109 / 6 | 1759 / 187 / 109 / 6 |
| obligations / risk decisions | 9 / 3 | 9 / 3 |
| `idx_*` indexes | 13 | 13 |
| rows with `retired_at IS NOT NULL` | — | **0** |

The last three columns read `reserve_enabled, reserve_funded_paise, retired_at` — the same
order as `createObligationsTable` produces on a fresh install, so the drift the TASK-25
tests guard against did not occur on real data either. All 187 confirmed decisions intact.

**One-way door, stated plainly:** the stored version is now 5, and `refuseDowngrade` means
a build older than this branch will refuse to open the database rather than wipe it. That
is the intended behaviour (TASK-03), not a side effect to fix.
