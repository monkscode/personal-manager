# TASK-29 — HDFC's `Sent … To <PAYEE>` UPI alert yields no merchant

**Severity:** Critical · **Phase:** 1 · **Depends on:** TASK-07 (which made these rows
exist in the first place)

Filed from a live-device run on 2026-08-02. **Sequencing note:** this is a parser change,
so it belongs in Phase 1 next to TASK-10/11 rather than Phase 2 — but it *gates* Phase 2's
value, because reconciliation has nothing to reconcile while these rows carry no owner
key. Do it before the Phase 2 reconciliation tasks regardless of which phase it is filed
under.

---

## The defect

`lib/services/sms_transaction_parser.dart:65-67` — `_merchantAt` only ever matches a
payee introduced by the word **`at`**:

```dart
RegExp(r'\bat\s+(.{2,40}?)(?:\s+on\s+\d|\s+at\s|\s+to\s|…)')
```

HDFC's UPI debit — India's highest-volume alert format, and the one TASK-07 taught the
parser to read — introduces the payee with **`To`**, on its own line, and carries **no
VPA at all**:

```
Sent [amount]
From HDFC Bank A/C [account]
To ACME DIGITAL PRIVATE LIMI
On 01/08/26
[ref]
Not You?
Call [number]/SMS BLOCK UPI to [number]
```

So `_merchantAt` never fires, `upiVpaNorm` is null, and `MerchantDisplay` falls back to
the bank name — which `SmsLiveNormalizer.enrich` deliberately refuses to persist as a
merchant. The row ends up with **no owner key at all**.

### Measured on live data

Of the 173 rows the Phase-1 parser recovered on the author's device:

| | count |
|---|---|
| rows with a merchant | **2** |
| rows with **no** merchant | **171** |
| rows carrying a UPI VPA | **0** |

That last row matters: **TASK-11 M1 (`_upiHandles` is missing bank handles) does not cover
this.** There is no VPA in the body to normalise — the payee is a plain name. Do not close
this by widening `_upiHandles`.

### Why it matters

Recurring-obligation detection keys on the merchant owner key. With 171 of 173 rows
ownerless, roughly ₹4.3 lakh of newly-visible spend cannot form obligations. The device showed
**0 obligations** despite a populated forecast — the mechanism that is supposed to make
the forecast explainable has nothing to work with.

The payees are real and useful: `CRED Club`, `ACME DIGITAL PRIVATE LIMI` (merchants) and
`PAYEE FULL NAME` (a person — P2P, which `payee_classifier` should treat
differently from a merchant).

---

## Fix

- Capture the payee from a `To <PAYEE>` introducer as well as `at <PAYEE>`, terminating on
  the next line or on ` on <digit>` / ` ref ` — the same terminator set TASK-08 established,
  and note the body is multi-line so the pattern needs `dotAll` handling consistent with
  TASK-07's `\bsent\b` lookahead.
- Mirror the change in `merchant_display._merchantFromBody`
  (`lib/services/merchant_display.dart:92`), which TASK-08 already keeps in step with
  `_merchantAt`. These two must not drift.
- Do **not** capture `HDFC Bank A/C` from the `From` line as a merchant. The `From` leg is
  the user's own account; only the `To` leg names a payee.

## Tests to write first

Add to `test/sms_transaction_parser_test.dart`:

- [ ] The multi-line HDFC body above yields merchant `acme digital private limi`.
- [ ] `To CRED Club` yields `cred club`, not `hdfc bank`.
- [ ] The `From HDFC Bank A/C [account]` line never becomes the merchant (guard — this is
      the failure mode a careless `To|From` alternation introduces).
- [ ] A person payee (`To PAYEE FULL NAME`) is classified P2P, not merchant.

Add to `test/golden/`:

- [ ] The real multi-line body with a `merchant` label, per the corpus conventions.

Add to `test/sms_live_normalizer_test.dart`:

- [ ] Two months of `To CRED Club` debits produce the **same** owner key, so recurring
      detection can group them. This is the assertion that proves the defect is actually
      fixed for its purpose, rather than just the regex matching.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] `To <PAYEE>` captured as merchant in both the parser and `merchant_display`
- [ ] `From …` never captured as merchant
- [ ] P2P payees classified as people, not merchants
- [ ] Same payee across months yields one stable owner key
- [ ] Golden corpus carries the real multi-line body with a `merchant` label
- [ ] `flutter analyze` clean, `flutter test` green, count up
- [ ] Suggested commit: `Capture the UPI payee from HDFC's To line`
