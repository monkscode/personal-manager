# TASK-10 — Dead bank-pattern module; Paytm QR misclassified

**Severity:** Important ×2 · **Phase:** 1 · **Depends on:** nothing

---

## Defect 1 — `bank_pattern_library.dart` is dead code whose docstring claims otherwise

`lib/services/bank_pattern_library.dart:92-136`

The file's own header states that the parser uses `bankPatternForSender` to disambiguate
bank-specific formats. **It does not.** `sms_transaction_parser.dart` never imports the
module. Grep confirms `normalizeSenderHeader` is the only symbol in the file with a
production caller, and that call comes from `lib/services/merchant_display.dart:164`.

Worse, all five banks currently share **identical** `_debitVerbs`, `_creditVerbs` and
`_balancePhrase` values — so the per-bank layer carries no information even if it were
wired up.

Meanwhile `test/bank_pattern_library_test.dart` spends 145 lines on it, **inflating the
apparent test coverage** of the parser slice.

### Decide one of two, then do it fully

**Option A — wire it up.** This is the better outcome, because it resolves TASK-08's Axis
defect cleanly and structurally: per-bank balance prefixes and verb sets are exactly the
right shape for that problem. If you choose this:
- Give each bank its genuinely distinct patterns (Axis `Avl Bal-`, SBI's currency-less
  `debited by`, HDFC's split `Sent ... To`).
- Have `sms_transaction_parser` consult `bankPatternForSender` before falling back to the
  generic patterns.
- Keep the generic path as the fallback for unknown senders.

**Option B — delete it**, along with `test/bank_pattern_library_test.dart`, keeping only
`normalizeSenderHeader` (move it to `merchant_display.dart`, its only caller).

**Do not leave it as-is.** A docstring asserting behaviour that does not exist is worse
than either outcome. If you pick A, note it overlaps TASK-08 Defect 3 — coordinate.

### Chosen: Option B — delete

TASK-07 and TASK-08 had already landed all three formats Option A cites as its
justification, and landed them in the *generic* path:

| Option A's motivating case | Already handled by | Where |
|---|---|---|
| Axis `Avl Bal-` | TASK-08 widened the separator to `(?:is\|[:\-–])?` | `sms_transaction_parser._balancePrefix` |
| SBI currency-less `debited by` | TASK-07 added `_verbAnchoredAmount` | `sms_transaction_parser._verbAnchoredAmount` |
| HDFC split `Sent … To` | TASK-06/07 added bare `\bsent\b` + lookahead | `sms_transaction_parser._debitVerb` |

Wiring the registry up would therefore have added no coverage and **removed** some:
those generic patterns fire for any sender, whereas `bankPatternForSender` fires only
for the 15 hard-coded DLT headers. Indian DLT headers churn constantly, and the parser
already keeps a second sender list in `_knownBankFragments` — a third registry that has
to agree with both is exactly the drift this audit is removing. TASK-29 has since given
`_merchant` a second extractor (`_merchantTo`), widening the generic path further.

Done: `bank_pattern_library.dart` and `test/bank_pattern_library_test.dart` deleted,
`normalizeSenderHeader` moved to `merchant_display.dart` (its only caller) with its four
behaviour tests rehomed to `test/merchant_display_test.dart`, and the `BankPatternLibrary`
bullet in `docs/2026-07-08-sms-actuals-layer-design/01-product-scope-architecture.md`
rewritten to say the component was removed and why.

---

## Defect 2 — Paytm QR merchants classified as wallet top-ups

`lib/services/payee_classifier.dart:10-16` and `:80-85`

`kWalletVpaHandles` contains `paytm`, and `_isWalletVpa` matches on the **handle alone**.

But every shop QR code in India is `paytmqr<digits>@paytm`. So ordinary merchant spend at
a kirana store, a chai stall, a petrol pump — anything with a Paytm QR — is classified as
a wallet top-up.

**Why it matters** — wallet top-ups get `untrackedCashCaveat: true` and are excluded from
tracked coverage. So a user who pays for most things by Paytm QR sees their real,
perfectly trackable spending reported as untracked cash, and the coverage metrics that
drive confidence messaging are wrong.

### Fix

- Exclude payee prefixes matching `^paytmqr` and `^merchant` from the wallet
  classification.
- Prefer the `UPI/P2M` tag when the SMS body carries it — `P2M` (person-to-merchant) is
  unambiguous and is present in many Axis and ICICI formats.
- A genuine wallet top-up (`<phone>@paytm`, or a body saying "added to wallet") must still
  classify as wallet.

---

## Tests to write first

For Defect 1, tests depend on the option chosen:
- **Option A:** each bank's distinct pattern parses its real-world format; an unknown
  sender falls back to the generic patterns.
- **Option B:** `flutter analyze` is clean after deletion and no import breaks;
  `normalizeSenderHeader` still behaves identically from its new home.

For Defect 2, add to `test/payee_classifier_test.dart`:

- [x] `paytmqr2810050501011o5m8fftqhqd@paytm` → merchant, **not** wallet;
      `untrackedCashCaveat == false`. **Genuinely red** — returned `wallet`.
- [x] `merchant123@paytm` → merchant, not wallet. **Genuinely red** — returned `wallet`.
- [x] `9876543210@paytm` → wallet (genuine top-up still detected). *Green guard.*
- [x] A body containing `UPI/P2M` → merchant regardless of handle. **Genuinely red** —
      returned `wallet`.
- [x] A body containing `UPI/P2A` with a personal VPA → person-to-person, unchanged.
      *Green guard.*

Three of the five failed for the stated reason (`Actual: PayeeType.wallet` where
`merchant` was expected); two were regression guards that passed before the fix.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [x] `bank_pattern_library` is either genuinely wired in or deleted — with its docstring
      matching reality either way — **deleted; architecture doc corrected too**
- [x] If deleted, its test file goes too and `normalizeSenderHeader` is rehomed
- [x] Paytm QR VPAs classify as merchant spend, not wallet top-ups
- [x] `UPI/P2M` respected when present
- [x] All five payee tests written failing-first, then passing
- [x] `flutter analyze` clean, `flutter test` green
- [x] Suggested commit: `Classify Paytm QR spend as merchant and resolve the bank-pattern module`

**Test count moves 664 → 658, and that is the intended effect.** Deleting
`test/bank_pattern_library_test.dart` removed 15 tests that exercised a module with no
production caller — the "inflated apparent coverage" Defect 1 names. Added back: 4
rehomed `normalizeSenderHeader` tests + 5 new payee tests. `664 − 15 + 4 + 5 = 658`,
0 failing.
