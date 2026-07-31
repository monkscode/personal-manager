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

- [ ] `paytmqr2810050501011o5m8fftqhqd@paytm` → merchant, **not** wallet;
      `untrackedCashCaveat == false`.
- [ ] `merchant123@paytm` → merchant, not wallet.
- [ ] `9876543210@paytm` → wallet (genuine top-up still detected).
- [ ] A body containing `UPI/P2M` → merchant regardless of handle.
- [ ] A body containing `UPI/P2A` with a personal VPA → person-to-person, unchanged.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `bank_pattern_library` is either genuinely wired in or deleted — with its docstring
      matching reality either way
- [ ] If deleted, its test file goes too and `normalizeSenderHeader` is rehomed
- [ ] Paytm QR VPAs classify as merchant spend, not wallet top-ups
- [ ] `UPI/P2M` respected when present
- [ ] All five payee tests written failing-first, then passing
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Classify Paytm QR spend as merchant and resolve the bank-pattern module`
