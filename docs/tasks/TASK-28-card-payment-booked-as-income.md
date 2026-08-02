# TASK-28 — A credit-card bill payment is treated as a refund

**Severity:** Important · **Phase:** 2 · **Depends on:** nothing

Violates the spec's **one owner per rupee** rule. Found by running the Phase-1 build
against a real device on 2026-08-02, not by code reading.

> **This file originally claimed the defect was "card payments booked as income".**
> That was wrong and is corrected below. Income was never affected — both income paths
> already exclude card credits (`salary_income_detector._isSalaryCandidate` requires
> `instrument == bank`; `real_insights._isIncomeCredit` returns false for cards). The
> real defect is in the card-cycle estimator and is documented from here down.

---

## The defect

`lib/services/card_cycle_estimator.dart:31-39`

```dart
final cardRefunds = cardTxns
    .where((t) => t.instrument == PaymentInstrument.card &&
                  t.direction == TransactionDirection.credit)
    .fold<int>(0, (sum, t) => sum + t.amountPaise);

final cycleSpendSeen = observedPurchases - cardRefunds;
```

**Every** card credit is summed as a refund. But a card receives credits for two quite
different reasons, and the bank writes both from the card's point of view:

| body | meaning | effect on spend |
|---|---|---|
| `Refund of Rs.1000 processed to your HDFC Bank Card XX12 by AMAZON` | merchant returns money | **cancels** spend |
| `PAYMENT OF Rs.5000 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 1234` | holder pays the bill | **settles** spend |

A refund cancels spend. A payment settles it. Subtracting the payment makes paying the
bill look like the holder spent less — so `cycleSpendSeen` collapses, the statement is
understated, and the bank cash outflow forecast from it is too small.

### Measured on live data

26 card-side credit rows totalling roughly **₹1.2 lakh** on the author's device, all of which
were being subtracted from observed card spend. On one day alone the device held a
bank debit paired with a card credit a few rupees larger — the two legs of one bill
payment.

**Why this surfaced now.** The card-side alerts were always parsed. The *bank-side* UPI
debits were not, until TASK-07 landed, so before Phase 1 only half the pair was visible.

---

## Fix

`isCardBillPayment` identifies the payment wording and excludes those credits from
`cardRefunds`. Deliberately narrow: only a credit that *positively identifies itself* as
a payment is excluded, so an unlabelled card credit still counts as a refund exactly as
before — which is what keeps the existing estimator tests honest.

## Tests to write first

- [x] A bill payment (HDFC `PAYMENT OF … RECEIVED TOWARDS YOUR CREDIT CARD` wording) does
      not reduce `cycleSpendSeenPaise`. — **RED** (`cardRefundsPaise` was 100000, want 0)
- [x] The ICICI/BBPS wording (`Payment of … has been received on your … Credit Card …
      through Bharat Bill Payment System`) behaves the same. — **RED** (same)
- [x] A genuine refund still cancels spend. — **green guard**; this is what stops an
      over-broad fix silently disabling refund handling.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] A card bill payment no longer cancels card spend
- [x] A genuine refund still does
- [x] An unlabelled card credit keeps its previous meaning
- [x] `flutter analyze` clean, `flutter test` green — **679 passing** (was 676)
- [x] Suggested commit: `Stop a card bill payment cancelling the card spend it settles`

---

## Deliberately left for later — do not re-report as new

1. **The bill payment is not routed into `amountPaidPaise`.** `CardCycleEstimator.estimate`
   already accepts that parameter, but nothing feeds these rows into it, so a payment
   still does not mark the statement paid. That is **TASK-13** (card-cycle payments) and
   **TASK-15** (the transfer bridge that pairs the bank leg with the card leg). This task
   deliberately stops at "a payment is not a refund".
2. **The display category is still `income`.** `merchant_display._category`
   (`lib/services/merchant_display.dart:226`) labels any non-refund credit `income`, so a
   card payment renders as "Income" in the transaction list. Cosmetic — it feeds no
   forecast maths — but it is visible and worth a minor item. Not fixed here because the
   honest category for a bill payment is `transfer`, and introducing that key touches
   `seed_data.dart`, the category label map and the insights grouping.
