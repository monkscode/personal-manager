# TASK-04 — Card tails and balances stored in plaintext

**Severity:** Critical · **Phase:** 0 · **Depends on:** nothing

The stated v1 privacy floor is breached. **This repository is public.**

---

## The promise being broken

`docs/2026-07-08-sms-actuals-layer-design/02-data-ingestion-storage-parser.md` §4, and
the safety plan, both state: *never store plain SMS body text.* The mechanism is
`SmsPrivacy.redactBody` producing `raw_body_redacted`, plus a salted `body_hash`.

SQLCipher is deferred, so **redaction is the only barrier** protecting data at rest.
`allowBackup="false"` is the second and last.

---

## The defect

`lib/services/sms_privacy.dart:10-22`

```dart
static final RegExp _amount = RegExp(
  r'(?:₹|rs\.?|inr)\s*[0-9][0-9,]*(?:\.[0-9]+)?',      // requires a currency token
  caseSensitive: false,
);
static final RegExp _account = RegExp(
  r'\b(?:card|a/c|ac|acct|account)\s+ending\s+\d{2,}'   // alt 1: needs the word "ending"
  r'|\b(?:a/c|ac|acct|account)\s*(?:no\.?\s*)?[*xX]*\d{2,}'   // alt 2: NO "card"
  r'|(?<![A-Za-z0-9])[*xX]{2,}\d{2,4}\b',              // alt 3: needs 2+ x's
  caseSensitive: false,
);
```

Three independent gaps:

1. **Alternative 2 omits `card`.** So `HDFC Bank Card x1111` matches nothing —
   alternative 1 needs the literal word `ending`, alternative 2 doesn't accept `card`.
2. **Alternative 3 requires `[*xX]{2,}`.** A single-`x` tail (`x1111`) or a bare tail
   (`Card 5555`) is missed.
3. **`_amount` requires a `₹|rs|inr` token.** Every un-prefixed number — most
   importantly running balances — is stored in the clear.

### Verified leaking inputs

| Input | Stored `raw_body_redacted` |
|---|---|
| `Rs.20000.00 withdrawn from HDFC Bank Card x1111 at MAIN STREET ATM ... Avl bal: 54321.00` | `[amount] withdrawn from HDFC Bank Card x1111 ... Avl bal: 54321.00` |
| `Paid Rs.500.00 On HDFC Bank Card 5555 at KANDOI ... Bal 12345.67` | `Paid [amount] On HDFC Bank Card 5555 ... Bal 12345.67` |
| `Dear UPI user A/C X3456 debited by 1250.0 ... Refno 501234567890 -SBI` | `... debited by 1250.0 ... Refno 501234567890 -SBI` |

**This is not theoretical.** The repository's own test fixtures — documented as "taken
(redacted) from real device messages" — contain the leak:
`test/merchant_display_test.dart:47` (`Card 5555`), `:111` (`Card x1111`; `Avl bal` reads
`[amount]` there only because the author masked it by hand), and
`test/sms_live_normalizer_test.dart:91-102` (`Card x1111`, `Avl bal: 54321.00`).

Net effect: **card last-4 plus running balance sit in plaintext SQLite.**

---

## The fix

### 1. Close the account-pattern gaps

- Add `card` to alternative 2's keyword group.
- Relax alternative 3 from `[*xX]{2,}\d{2,4}` to accept a single masking character:
  `[*xX]\d{4}`. Keep the `(?<![A-Za-z0-9])` guard so it doesn't fire mid-token.
- Consider a `card\s+\d{4}\b` branch for the bare-tail form.

### 2. Redact bare balances

Add a pass anchored to balance/amount keywords rather than to a currency symbol:

```
bal(?:ance)?[:\s-]+\d[\d,]*(?:\.\d+)?
debited\s+by\s+\d[\d,]*(?:\.\d+)?
credited\s+by\s+\d[\d,]*(?:\.\d+)?
```

Order matters — see fix 3.

### 3. Fix the redaction ordering side effect

`lib/services/sms_privacy.dart:31-37` applies `_reference`, `_vpa`, `_account`, `_amount`
in that order. `HDFC Credit Card ending 4321` becomes `HDFC Credit [account]` — the
redaction swallows the word "Card", degrading the human reviewer's context in the review
screen. Prefer patterns that consume only the identifying digits, keeping the noun.

### 4. Salt the synthetic `sms_id`

`lib/services/sms_privacy.dart:42-54` builds
`synthetic:sha256(sender|timestamp|normalized_body)` with **no salt**.

`lib/data/sms_meta_store.dart:8-12` states the salt exists specifically to stop rainbow
tables over templated bank bodies. But the same row stores `sender` and `txn_date` in
plaintext, so an attacker holding the database can brute-force the redacted amount,
account and reference by recomputing this unsalted hash over candidates — defeating the
salted `body_hash` entirely.

Prefix the same per-install salt into the synthetic identity. It stays deterministic per
device, which is all dedupe requires.

**Migration consideration:** changing the `sms_id` derivation changes existing rows' keys.
Since the layer has never shipped (see TASK-03), there is no installed base to migrate.
Confirm that is still true when you do this; if the layer has shipped by then, this needs
a migration step.

---

## What is already clean — do not "fix" it

The **logging** side of the privacy floor is genuinely sound. Every `print`,
`debugPrint`, `throw` and exception path in `lib/` was grepped: none embeds
`RawSms.body`. The unredacted body lives only in the `parseOne` stack frame. Keep it
that way.

The salt itself is correct: `lib/data/sms_meta_store.dart:27-52` uses `Random.secure()`,
32 bytes, per-install, generated inside a transaction with `INSERT OR IGNORE`.

---

## Tests to write first

Add to `test/sms_privacy_test.dart`:

- [ ] Each of the three leaking inputs in the table above redacts to a string containing
      **no** 4-digit card tail and **no** bare balance number.
- [ ] `Card x1111`, `Card 5555`, `A/C X3456`, `card ending 1234`, `**1234` all redact.
- [ ] `Avl bal: 54321.00`, `Bal 12345.67`, `debited by 1250.0` all redact.
- [ ] `HDFC Credit Card ending 4321` keeps the word `Card` in the output.
- [ ] A property/fuzz test: for a corpus of bodies, the redacted output contains no
      run of 4+ consecutive digits. This is the assertion that catches the *next* gap.
- [ ] Synthetic `sms_id` differs for the same body under two different salts, and is
      stable for the same body under one salt.

Then update the leaking fixtures in `test/merchant_display_test.dart` and
`test/sms_live_normalizer_test.dart` so the corpus itself stops carrying real tails.

## Verification

```bash
flutter analyze
flutter test
```

## Definition of done

- [ ] Account pattern covers `card` + single-masking-char + bare tails
- [ ] Bare balances redacted via keyword-anchored patterns
- [ ] Redaction preserves the noun (`Card`) while removing digits
- [ ] Synthetic `sms_id` salted
- [ ] The no-4-consecutive-digits property test exists and passes
- [ ] Leaking test fixtures scrubbed
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] Suggested commit: `Close redaction gaps leaking card tails and balances`
