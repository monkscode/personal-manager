# TASK-05 — Marketing SMS auto-added as ₹5,00,000 income

**Severity:** Critical + Important · **Phase:** 1 · **Depends on:** nothing

The parser invents money that does not exist, and adds it **without review**.

---

## Defect 1 (Critical) — promotional SMS parses as a real transaction

`lib/services/sms_transaction_parser.dart:173-183`

The promo filter is **disabled by the presence of any debit/credit verb** (lines
179-181) — which is exactly the vocabulary marketing copy uses.

Failing input, sender `VM-HDFCBK`:

```
Congratulations! Rs. 5,00,000 pre-approved Personal Loan can be credited to your HDFC Bank A/c XX1234 instantly. Apply now.
```

Parses as: amount `Rs. 5,00,000`, account `1234`, direction `credit`. Signals = 3.
Confidence = `0.5 + 0.3` (known sender) `+ 0.1` (line 349) = **0.90** →
`ReviewStatus.autoAdded`, `CoverageBucket.datedEvent`. On any non-first scan,
`lib/services/sms_ingestion_policy.dart:137` upserts it.

**A phantom ₹5,00,000 income lands in the forecast with no review prompt.**

Same class:
```
You've spent Rs.50,000 on your card this year — check your rewards offer!
```

This is precisely the failure the spec calls out: *a mis-parsed auto-add silently
inflates the seasonal training signal for up to a year.*

### Fix

Make the promo signal set **additive rather than vetoed**, and never auto-add when a
promo marker is present regardless of verb. Marker vocabulary to detect:

```
pre-approved | apply now | t&c apply | click | limited period | eligible for
| loan offer | know more | rewards offer | exclusive | congratulations
```

Two separate behaviours, both needed:
- A strong promo marker → reject the message entirely (not a transaction).
- A weak/ambiguous marker → parse but force `ReviewStatus.needsReview` regardless of
  confidence.

---

## Defect 2 (Important) — failed and future-tense messages booked as real spend

Both parse at confidence 0.9 → auto-added:

```
Rs.2,500.00 debited from A/c XX1234 could not be processed. The amount will be credited back in 3 days.
→ direction: debit
```

```
Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25 for NETFLIX UPI Autopay. Ref 512345678901.
→ direction: debit, dated today
```

The AutoPay pre-debit notice **double-counts** when the actual debit SMS arrives days
later. There is no `failed|declined|unsuccessful|not processed|will be debited` handling
anywhere in the parser.

### Fix

- **Failure markers** → reject the message: `failed`, `declined`, `unsuccessful`,
  `not processed`, `could not be processed`, `reversed due to`, `has been declined`.
- **Future tense** → either reject, or parse and force review with the *stated* future
  date rather than today. Do not auto-add. Detect `will be debited`, `will be credited`,
  `is due on`, `scheduled for`, `due for payment`.

Prefer force-review over reject for future tense: an AutoPay notice is genuinely useful
signal for obligation detection, it just must not become a dated actual.

---

## Interaction with other tasks

TASK-06 changes direction inference and TASK-07 adds new accepted formats. All three
touch `sms_transaction_parser.dart`. **Expect merge conflicts if worked in parallel** —
prefer doing 05, 06, 07 in sequence, or coordinate on which regions each edits.

---

## Tests to write first

Add to `test/sms_transaction_parser_test.dart`:

- [x] The `pre-approved Personal Loan` string → either `parseOne` returns null, or the
      result is `needsReview` and never `autoAdded`. Assert on `reviewStatus` explicitly.
- [x] The `rewards offer` string → same.
- [x] A **genuine** credit that happens to contain a promo-adjacent word still parses as
      a real transaction (guard against over-blocking). E.g.
      `Rs.50,000.00 credited to a/c XX1234 by IMPS Ref 112233445566. Avl Bal Rs.75,000.00.`
- [x] `could not be processed` → rejected.
- [x] `will be debited ... on 05-Jul-25` → not auto-added; if parsed, dated 05-Jul-25 and
      flagged for review, not dated today.
- [x] An AutoPay pre-notice followed by the real debit SMS produces **one** transaction,
      not two.

Add these six strings to the golden corpora (see TASK-07, which owns corpus expansion —
coordinate so you don't both edit `test/golden/*.json`).

> Deferred to TASK-07 as written: `test/golden/*.json` was left untouched here. A seventh
> test was added alongside the six — a real debit carrying a marketing tail
> (`... exclusive offer ... click here`) must be kept and reviewed, not rejected. That is
> the case which proves the promo signal is *additive* rather than vetoed; the listed
> over-blocking guard does not, because its example string contains no promo vocabulary.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Promo markers are additive and block auto-add unconditionally
- [x] Failure markers reject the message
- [x] Future-tense messages never become dated actuals
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Stop marketing and failed SMS becoming auto-added transactions`

Auto-add is blocked by routing the row to `ReviewReason.parserUncertain`, which
`SmsIngestionPolicy` already honours on every later scan and which
`sms_review_screen._preChecked` already excludes from the pre-ticked bulk-confirm set. No
new `ReviewReason` value was introduced, so no schema, repository or UI change was needed.
