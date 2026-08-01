# TASK-07 — HDFC and SBI UPI alerts parse to nothing

**Severity:** Critical · **Phase:** 1 · **Depends on:** nothing (see conflict note)

Two of India's highest-volume SMS formats are silently dropped, and the golden corpus
**cannot see it** because every sample is synthetic and uniformly shaped.

---

## Defect 1 — HDFC UPI debit alert dropped

```
Sent Rs.500.00 From HDFC Bank A/C x1234 To rahul@okhdfcbank On 05/01/25 Ref 501234567890
→ direction: null  →  parseOne returns null
```

`_debitVerb` (`lib/services/sms_transaction_parser.dart:61`) requires the literal
`sent to`. HDFC's current UPI debit alert puts `Sent` and `To` far apart, often across a
line break. Amount, account and reference all extract correctly — **the row is discarded
on direction alone.**

### Fix

Add a bare `\bsent\b` to `_debitVerb`, guarded by a proximity check for a following
`to`/`from` so it doesn't fire on unrelated prose.

---

## Defect 2 — SBI UPI alert dropped

```
Dear UPI user A/C X3456 debited by 1250.0 on date 05Jan25 trf to GROCERY STORE Refno 501234567890 -SBI
→ amounts: []  →  parseOne returns null
```

`_amount` (`sms_transaction_parser.dart:37`) requires a `₹|rs|inr` token. SBI's UPI alert
has none.

### Fix

Make the currency token **optional when a debit/credit verb is adjacent**. The pattern
`debited by 1250.0` gives unambiguous context; a bare number with no verb nearby should
still be rejected.

Be careful not to start matching dates (`05Jan25`), reference numbers (`501234567890`) or
years as amounts. Anchor to the verb, require a decimal or a plausible magnitude, and
lean on the existing `_balancePrefix` exclusion.

---

## Defect 3 — the golden gate is vacuous

`test/golden_corpus_test.dart:13-14` gates precision and recall at 0.90. All 25 samples
across `test/golden/{hdfc,icici,sbi,axis,kotak}.json` are synthetic, and **every one**
uses an `Rs.`-prefixed amount and a canonical `debited`/`credited`/`spent` verb.

The gate reports **1.00 precision and recall** while real-world recall on the two formats
above is near zero. The corpus is the weakest link in the whole parser slice.

### What the corpus is missing entirely

Not one sample of: failed/declined · reversal · refund · balance enquiry · EMI due
reminder · AutoPay pre-debit · self-transfer · minimum-balance alert · a promo phrased
with `credited`.

Because of that, `golden_corpus_test.dart:65` (precision) proves almost nothing and
`:104` ("no noise sample is ever auto-added") is near-vacuous.

### Fix

Expand the corpora with every failing string surfaced by this audit. At minimum:

| String | Expected |
|---|---|
| `Sent Rs.500.00 From HDFC Bank A/C x1234 To rahul@okhdfcbank On 05/01/25 Ref 501234567890` | txn, debit, 50000 paise |
| `Dear UPI user A/C X3456 debited by 1250.0 on date 05Jan25 trf to GROCERY STORE Refno 501234567890 -SBI` | txn, debit, 125000 paise |
| `Axis Bank Acct XX7788 debited with INR 2750.00 on 28-06-25. Info- UPI/P2A/.../RAHUL. Avl Bal- INR 41000.00` | txn, debit, 275000 paise, **not** parser-uncertain |
| `Congratulations! Rs. 5,00,000 pre-approved Personal Loan can be credited to your HDFC Bank A/c XX1234 instantly. Apply now.` | **not** a txn |
| `Rs.2,500.00 debited from A/c XX1234 could not be processed...` | **not** a txn |
| `Rs.499.00 will be debited from your A/c XX1234 on 05-Jul-25 for NETFLIX UPI Autopay.` | not a dated actual |
| `HDFC Bank: Rs.15,000.00 debited from A/c XX1234 towards loan repayment.` | txn, **debit** |
| `HDFC Bank: Rs.100.00 credited to A/c XX1234 as cashback for your bill paid on 26-06-25.` | txn, **credit** |
| A self-transfer between the user's own accounts | txn, excluded from spend |
| A minimum-balance alert | **not** a txn |
| A balance-enquiry reply | **not** a txn |

**Then re-gate.** Expect precision/recall to drop below 0.90 initially — that is the
point. Fix the parser until the expanded corpus passes, rather than trimming the corpus.

---

## Conflict note

TASK-05, TASK-06 and TASK-08 also edit `sms_transaction_parser.dart`, and TASK-05/06 add
strings to the same corpora. **This task owns `test/golden/*.json`** — if worked in
parallel, let the other tasks list their strings here rather than editing the JSON
directly. Prefer sequential: **05 → 06 → 07 → 08**.

---

## Tests to write first

- [x] Both dropped formats parse: correct amount in paise, correct direction, correct
      account tail, correct reference.
- [x] A bare number with **no** adjacent verb is still rejected as an amount.
- [x] `05Jan25` and `501234567890` are never selected as the transaction amount.
- [x] The expanded corpora pass the 0.90 precision/recall gate.
- [x] `golden_corpus_test.dart`'s "no noise sample is ever auto-added" assertion now runs
      against genuinely hard negatives (promo-with-credit, failed, balance enquiry).

> **Defect 3 measured.** With *both* dropped formats still broken, the expanded corpus
> reported **precision 1.00, recall 0.917** — it passed the 0.90 gate. Two of India's
> highest-volume UPI formats returning null is not enough to move a 24-positive corpus
> past a 10% tolerance, so the gate cannot be the thing that catches this class of bug.
> The unit tests in `sms_transaction_parser_test.dart` are the real red; the corpus value
> is in the hard negatives and the new `autoAdd` label. Post-fix: 38 samples,
> precision 1.00, recall 1.00, 0 false positives, 0 false negatives.
>
> `_Sample` gained an optional `autoAdd` field. Set to `false` it asserts a genuine
> transaction is never auto-added — the AutoPay pre-notice uses it. Absent, the sample
> makes no claim.
>
> **Correct reference** required widening `_ref`: SBI writes `Refno 501234567890`, and the
> old pattern consumed `Ref` then failed the 6-char group on `no`, capturing nothing.
>
> **Not added: an EMI-due reminder row.** `Your EMI of Rs.8,500.00 is due on 05-Jul-25`
> carries no debit or credit verb, so `_direction` returns null and the row is dropped.
> Labelling it `isTxn: true` would fail; labelling it `isTxn: false` would bake in
> "obligation reminders are not signal", which contradicts TASK-05's decision to keep
> AutoPay pre-notices. It is a real gap, it is not in this task's required table, and no
> other task file covers it — left for a future task rather than mislabelled here.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `sent` accepted as a debit verb with a proximity guard
- [x] Currency token optional when a verb is adjacent, with dates/refs still excluded
- [x] All 11 corpus rows above added with expected outcomes
- [x] Corpus passes the 0.90 gate **after** the parser fixes, not by weakening the gate
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Parse HDFC and SBI UPI alert formats and harden the golden corpus`

13 rows added, not 11: a refund and a reversal were included from the "missing entirely"
list above, since both parse cleanly and neither was represented.

The bare-number fallback runs **only** when the body names no currency at all. A body that
does carry an `Rs.`/`INR` amount but hides it behind a balance keyword still yields no
amount, rather than falling through to guess at some other number.

The Axis row is present as this task's table requires. It parses with the right amount and
direction but is still `parserUncertain` — that is TASK-08 Defect 3 (`Avl Bal-` and the
12-char window), so the row deliberately carries no `autoAdd` label. **TASK-08 should set
`"autoAdd": true` on it** once its fix lands, which turns that row into the regression
guard for the Axis review-loop bug.
