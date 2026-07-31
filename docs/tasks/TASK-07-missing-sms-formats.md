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

- [ ] Both dropped formats parse: correct amount in paise, correct direction, correct
      account tail, correct reference.
- [ ] A bare number with **no** adjacent verb is still rejected as an amount.
- [ ] `05Jan25` and `501234567890` are never selected as the transaction amount.
- [ ] The expanded corpora pass the 0.90 precision/recall gate.
- [ ] `golden_corpus_test.dart`'s "no noise sample is ever auto-added" assertion now runs
      against genuinely hard negatives (promo-with-credit, failed, balance enquiry).

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `sent` accepted as a debit verb with a proximity guard
- [ ] Currency token optional when a verb is adjacent, with dates/refs still excluded
- [ ] All 11 corpus rows above added with expected outcomes
- [ ] Corpus passes the 0.90 gate **after** the parser fixes, not by weakening the gate
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Parse HDFC and SBI UPI alert formats and harden the golden corpus`
