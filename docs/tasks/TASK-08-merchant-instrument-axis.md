# TASK-08 — Greedy merchant capture, card-as-bank, Axis stuck in review

**Severity:** Important ×3 · **Phase:** 1 · **Depends on:** nothing (see conflict note)

Three parser defects that share a root cause: patterns that are too loose or windows that
are too narrow. None of the three is asserted by any existing test, so all are invisible.

---

## Defect 1 — the merchant regex captures the rest of the sentence

`lib/services/sms_transaction_parser.dart:293-304`

The character class `[a-z0-9 &._-]{2,40}` includes `.`, `-` and space, so it runs straight
past the merchant name.

On the corpus's own `test/golden/hdfc.json` sample 2:

```
Spent Rs.3,200.00 on HDFC Bank Card XX9012 at AMAZON on 26-06-25. Available Limit Rs.46,800.00.
→ merchant = "amazon on 26-06-25. available limit rs"
```

**Why it matters** — that garbage string then:
- is stored in the `merchant` column,
- grants `+0.1` confidence (`sms_transaction_parser.dart:351`),
- becomes a "distinguishing signal" in `lib/services/sms_ingestion_policy.dart:183-191`,
  which **suppresses legitimate collision review**,
- and is treated as `hasGoodMerchant` by `lib/services/sms_live_normalizer.dart:70-73`,
  so enrichment never repairs it.

**Fix** — a correct lazy, terminator-aware pattern already exists in this codebase at
`lib/services/merchant_display.dart:102-106`. Reuse it. Terminate on ` on `, ` at `,
a date, `Avl`, `Available`, `Ref`, or a period followed by a space.

---

## Defect 2 — credit-card spend classified as `instrument: bank`

`lib/services/sms_transaction_parser.dart:273-279`

The instrument regex requires `credit card` or `card ending`. HDFC writes
`on HDFC Bank Card XX9012`.

On `test/golden/hdfc.json` sample 2: `instrument: bank`.

**Why it matters** — per spec §4, a card purchase misclassified as a bank debit hits cash
flow **immediately**, and then hits it **again** when the card statement payment is
reconciled. The same rupee is subtracted twice, one month apart.

**Fix** — extend the pattern:

```
\bbank card\b | \bcard\s+[*xX]*\d{4}\b | \bavailable limit\b | \bavl lmt\b | \bcredit limit\b
```

The presence of an "available limit" or "credit limit" phrase is by itself strong
evidence of a card, since bank accounts don't have limits.

---

## Defect 3 — real Axis messages are permanently parser-uncertain

`lib/services/sms_transaction_parser.dart:221-230` and `:72-75`

```
Axis Bank Acct XX7788 debited with INR 2750.00 on 28-06-25. Info- UPI/P2A/.../RAHUL. Avl Bal- INR 41000.00
→ non-balance amounts: [INR 2750.00, INR 41000.00]
→ verb-adjacent: []
→ PARSER-UNCERTAIN
```

Two independent bugs combine:

1. **`_balancePrefix` (line 72-75) allows `is` or `:` after the keyword but not `-`.** So
   `Avl Bal-` is not recognised as a balance prefix, and the balance stays in the
   candidate amount pool.
2. **The verb-adjacency window is 12 characters, but `"debited with "` is 13.** So the
   *transaction* amount fails its own adjacency test.

With two candidate amounts and no adjacency winner, every Axis debit lands in review —
forever.

**Fix** — allow `[-–:]` in `_balancePrefix`, and widen the verb window to ~24 characters.

Note TASK-06 depends on this window for its direction fix. Widening it here is safe and
helps that task; just don't narrow it.

---

## Conflict note

TASK-05, TASK-06 and TASK-07 also edit `sms_transaction_parser.dart`. Prefer sequential
work: **05 → 06 → 07 → 08**. The Axis string in Defect 3 is also listed in TASK-07's
corpus table — whoever gets there second should find it already present.

---

## Tests to write first

None of these three defects is currently asserted anywhere. Add to
`test/sms_transaction_parser_test.dart`:

- [x] `test/golden/hdfc.json` sample 2 → `merchant == 'amazon'` exactly (not the trailing
      sentence).
- [x] Merchant extraction terminates correctly for ` at X on <date>`, ` to X Ref Y`, and
      ` at X. Avl Bal Z`.
- [x] `test/golden/hdfc.json` sample 2 → `instrument == card`.
- [x] `Available Limit` alone (no `credit card` phrase) classifies as card.
- [x] A genuine bank debit with no card wording stays `instrument == bank` (regression
      guard).
- [x] The Axis string → parses cleanly, `amountPaise == 275000`, balance
      `41000.00` recognised as balance, and **not** parser-uncertain.
- [x] `Avl Bal:` and `Avl Bal ` (space) still work after the `-` addition.

Then add assertions on `merchant` and `instrument` to `golden_corpus_test.dart` — their
absence is why these went unnoticed.

> Done. `_Sample` gained optional `merchant` and `instrument` labels, asserted where
> present; six rows across the five banks carry them. The Axis row TASK-07 added now
> carries `"autoAdd": true`, which is the handoff that task recorded.
>
> Five of the seven were red. The bank-instrument row and the `Avl Bal` separator row
> passed before the fix — both are the regression guards this task labels as such.
>
> The two new corpus assertions were written after the parser change, so they were
> validated by stashing the parser back to HEAD and re-running: both fail without it —
> `merchant: 'amazon on 26-06-25. available limit rs'` and *a clean sample was held back
> from auto-add* on the Axis row. They are guards that bite, not decoration.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] Merchant pattern is lazy and terminator-aware, reusing the `merchant_display` form
- [x] Instrument detection recognises `bank card`, bare card tails, and limit phrases
- [x] `_balancePrefix` accepts `-`/`–`; verb window widened to ~24 chars
- [x] Golden corpus test asserts `merchant` and `instrument`
- [x] All seven tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Tighten merchant capture, card detection and Axis balance parsing`

The merchant terminator set extends `merchant_display`'s with ` at `, ` to `, ` from `,
` ref ` and ` available `. Without ` from `, `withdrawn at KOTAK ATM from A/c XX7107 on
25-06-25` yields `kotak atm from a/c xx7107` — the old greedy class returned null there
(its character class stops at the `/` in `a/c`), so a plain lazy rewrite would have
replaced *no* merchant with a *wrong* one, and wrong merchants suppress collision review.

`_adjacencyWindow` is now 24, as TASK-06 asked. That fix alone does not resolve the Axis
string — once `_balancePrefix` accepts the dash there is only one candidate amount and
adjacency never runs — but it does move `debited with `, `credited with ` and
`Acct XX#### debited ` onto the adjacency path instead of the whole-message fallback.
All 24 labelled corpus transactions keep their labelled direction either way.
