# TASK-28 — Credit-card bill payments are booked as income

**Severity:** Critical · **Phase:** 2 · **Depends on:** TASK-15 (the bridge that nets the
two legs must have a production caller first)

Violates the spec's **one owner per rupee** rule. Found by running the Phase-1 build
against the author's live device on 2026-08-02, not by code reading.

---

## The defect

`lib/services/sms_transaction_parser.dart:87` — `_creditVerb` contains `\breceived\b`.

A credit-card bill payment produces **two** SMS, and the bank writes the card-side one
from the *card's* point of view:

```
DEAR HDFCBANK CARDMEMBER, PAYMENT OF [amount] RECEIVED TOWARDS YOUR CREDIT CARD
ENDING WITH [number] ON 1-8-[number]. YOUR AVAILABLE LIMIT IS [amount]

Payment of [amount] has been received on your ICICI Bank Credit Card [account]
through Bharat Bill Payment System on 01-AUG-26.
```

`received` is a credit verb, so the row books as **income**. Paying down your own card is
not income — it is the second leg of a transfer between two accounts the user owns.

### Measured on live data

On 2026-08-01 the device held, on the same day:

| direction | amount | type/instrument |
|---|---|---|
| debit | ₹4,990 | upi/bank |
| **credit** | **₹5,000** | pos/card |
| debit | ₹2,282 | upi/bank |
| **credit** | **₹2,307** | pos/card |

Across the table: **26 card-side credit rows totalling roughly ₹1.2 lakh counted as income.**

The bank debit leg is the real outflow. The card credit leg is the same rupee arriving
where it was owed. Counting the second as income inflates income and, once these feed
salary/surplus detection, inflates the forecast's confidence in money that does not exist.

**Why this surfaced now.** The card-side alerts were always parsed. The *bank-side* UPI
debits were not, until TASK-07 landed — so before Phase 1 the double-count was half
invisible. Recovering the debit leg made it measurable.

---

## Required outcome

A card-payment confirmation must never contribute income. Pick one and do it fully:

**Option A — classify it as a transfer leg.** Detect "payment received … towards/on your
… card" and type it so `TransferBridgeMatcher` (TASK-15) can pair it with the bank debit
and let exactly one leg own the rupee. Best outcome, and the reason this task depends on
TASK-15 — without a production caller for the bridge there is nothing to pair against.

**Option B — suppress the card-side leg from income.** Cheaper. The row stays visible for
audit (no silent exclusion — it must still produce a coverage line) but contributes no
inflow.

Do **not** simply drop `received` from `_creditVerb`: genuine inflows ("Rs 5000 credited
… received from …") depend on it. The signal is *payment received **towards/on** a card*,
not `received` alone.

---

## Tests to write first

Add to `test/sms_transaction_parser_test.dart`:

- [ ] `PAYMENT OF Rs.5000 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 1234` does not
      produce a `credit` that counts as income.
- [ ] `Payment of Rs.2500 has been received on your ICICI Bank Credit Card XX12 through
      Bharat Bill Payment System` — same.
- [ ] Regression guard: `Rs.5000 credited to your account, received from ACME PAYROLL`
      **is** still income. This is what stops an over-broad fix.

Add to the reconciliation suite:

- [ ] A bank debit of ₹4,990 and a card credit of ₹5,000 on the same day net to **one**
      owner, not two, and total income does not rise.
- [ ] Rupee-conservation assertion (see TASK-14) holds across the pair.

Add to `test/golden/`:

- [ ] Both card-payment bodies above, labelled with the direction they must **not** get.
      Per the corpus conventions, add labels rather than bare rows.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Card-payment confirmations contribute no income
- [ ] Genuine `received` inflows still book as income (guard test green)
- [ ] The two legs resolve to one owner per rupee
- [ ] Golden corpus carries both real bodies with labels
- [ ] `flutter analyze` clean, `flutter test` green, count up
- [ ] Suggested commit: `Stop credit-card bill payments counting as income`
