# TASK-06 — Loan EMI booked as income; cashback booked as spend

**Severity:** Critical · **Phase:** 1 · **Depends on:** nothing (but see conflict note)

Direction is inferred from the **whole message** rather than from the verb governing the
chosen amount. Two common cases invert, at 0.9 confidence, and are auto-added.

---

## The defect

`lib/services/sms_transaction_parser.dart:60-68`

```dart
static final RegExp _debitVerb = RegExp(
  r'\bdebited\b|\bdeducted\b|\bspent\b|\bpaid\b|\bcharged\b|\bpurchased\b|\bsent to\b|\bwithdrawn\b',
);
static final RegExp _creditVerb = RegExp(
  r'\bcredited\b|\bdeposited\b|\breceived\b|\brefund(?:ed)?\b|\breversed\b|\brepayment\b',
);
static final RegExp _explicitInflow = RegExp(
  r'\brefund(?:ed)?\b|\breversed\b|\brepayment\b',
);
```

The stated rule (comment at lines 57-59) is: *debit wins when both appear, unless the
credit verb is an explicit inflow.* But `repayment` is in `_explicitInflow`.

### Case A — EMI inverted to income

```
HDFC Bank: Rs.15,000.00 debited from A/c XX1234 towards loan repayment. Avl Bal Rs.5,000.00.
→ direction: credit
```

A ₹15,000 **outflow** is booked as ₹15,000 of **income** and auto-added. The forecast
gains ₹30,000 of error in one message.

In Indian bank SMS, "repayment" almost always means *the customer paying*. It belongs in
`_debitVerb`, not `_explicitInflow`.

### Case B — genuine inflow swallowed by debit precedence

```
HDFC Bank: Rs.100.00 credited to A/c XX1234 as cashback for your bill paid on 26-06-25.
→ direction: debit
```

`paid` appears (describing the *original* bill), debit precedence fires, and a ₹100
credit is recorded as a ₹100 debit.

---

## The fix

**Move `repayment` out of `_explicitInflow` and into `_debitVerb`.** That alone fixes
Case A. Keep `refund` and `reversed` as explicit inflows — those genuinely are money
returning.

Case B needs the structural fix: **decide direction from the verb governing the chosen
amount**, not from a global scan.

The machinery already exists. `_verbAdjacent` (`sms_transaction_parser.dart:221`) already
computes a window around each candidate amount to decide *which* amount is the
transaction value. Reuse that same window to classify the *nearest* verb, and fall back
to the current global rule only when no verb is adjacent to the chosen amount.

Note the window is currently 12 characters, which is shorter than `"debited with "`
(13) — TASK-08 widens it to ~24. If you do TASK-08 first, this fix inherits the wider
window. Either order works; just don't narrow it.

Keep the global rule as the documented fallback and say so in a comment, so the
precedence story stays legible.

---

## Conflict note

TASK-05 and TASK-07 also edit `sms_transaction_parser.dart`, and TASK-08 edits the
`_verbAdjacent` window this fix depends on. Prefer sequential work: **05 → 06 → 07 → 08**,
or coordinate regions explicitly.

---

## Tests to write first

Add to `test/sms_transaction_parser_test.dart`:

- [x] The loan-repayment string → `direction == debit`, amount 1500000 paise.
- [x] `Rs.5,000.00 credited to A/c XX1234 as refund for order #123` → `direction == credit`
      (refund must stay an inflow — guard against over-correcting).
- [x] `Rs.2,000.00 reversed to your A/c XX1234` → `direction == credit`.
- [x] The cashback string → `direction == credit`, amount 10000 paise.
- [x] `Rs.1,250.00 debited from a/c XX1234 to swiggy@okhdfcbank` → `direction == debit`
      (regression guard on the common case).
- [x] A message with **no** verb adjacent to the amount still resolves via the global
      fallback and does not crash or return null unexpectedly.

Add the repayment and cashback strings to the golden corpora — coordinate with TASK-07.

> Deferred to TASK-07 as written: `test/golden/*.json` untouched here.
>
> Two of the six were red — the EMI (`credit`, wanted `debit`) and the cashback (`debit`,
> wanted `credit`). The other four are the guards this task asks for and passed before the
> fix, which is what a guard should do.
>
> The fallback test uses `debited with an amount of Rs.750.00`: at the current 12-char
> window `"debited with "` (13) does not reach the amount, so it exercises the documented
> whole-message fallback. When TASK-08 widens the window the adjacent rule resolves it
> directly and the expectation is unchanged either way.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `repayment` reclassified as a debit verb
- [x] Direction decided from the verb adjacent to the chosen amount, with the global
      rule as a documented fallback
- [x] All six tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Infer transaction direction from the verb governing the amount`

`_AmountResult` now carries the chosen `RegExpMatch`, so direction reads the same window
`_verbAdjacent` already used to pick the amount. That window is the named constant
`_adjacencyWindow` (still 12) — TASK-08 widens it in one place, and both the amount choice
and the direction rule inherit it.
