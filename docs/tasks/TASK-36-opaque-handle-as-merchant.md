# TASK-36 — A UPI handle's local part is stored as the merchant name

**Severity:** Important · **Phase:** 5 · **Depends on:** TASK-34

Recorded as finding 2 at the end of TASK-34 and promoted to its own file on 2026-08-04.
The device shows `ece9ae70c53842d58abf92660f4698af` where a payee name belongs — in the
why-log, and as September's top "Driver".

> **The premise recorded in TASK-34 was wrong on both counts.** It called these
> *"an internal identifier surfacing as a user-facing name"* and *"distinct from TASK-33's
> merchant-capture family"*. Neither survives the source. The obligation dedupe key is
> built from `commitment.merchantNorm` (`recurring_obligation_candidates.dart:54`), so the
> string is a **stored merchant value**, and it entered through the parser — which places
> it squarely *inside* the merchant-capture family. Nothing in `lib/` generates it. It is
> the local part of a real UPI VPA the bank put in the SMS.

---

## The defect

`sms_transaction_parser.dart:648-650` prefers a named payee and falls back to the handle:

```dart
final named = _namedPayee(lower);
if (named != null) return named;
if (upiVpa != null) return upiVpa.split('@').first;
```

The intent is already right, and the comment above it already names this exact class of
bug. The fallback fires only when `_namedPayee` returns null — and for one real body it
does, for a reason that has nothing to do with the payee being unnamed.

`_payeeTowards` (`:220-222`) capped the name at **40 characters**:

```dart
r'\btowards\s+(.{2,60}?)(?:\s+for\b|\s+umrn\b|\s+on\s+\d|,|\.(?:\s|$)|\n|$)'
//              ^^^^^^ was {2,40}
```

The device's body is:

```
Your A/c has been debited towards AutoPay  Bharat Connect PostPaid Bill Payment
for Rs.120.07 on 29-07-26. ece9ae70c53842d58abf92660f4698af@ybl - Axis Bank
```

`AutoPay  Bharat Connect PostPaid Bill Payment` is **45 characters**. The lazy capture
could not reach the `\s+for\b` terminator inside 40, no other terminator falls within 40,
so the pattern did not match at all — and the row fell through to the handle.

The same sentence with a short payee parses correctly:

```
Your A/c has been debited towards Google for Rs.1999.00 on 28-07-26. ...
```

→ `merchant = 'google'`. **That contrast is the whole diagnosis**: the failure is a
function of the payee's length, not of the format, the bank or the handle.

## Measured on the device, 2026-08-04

| | |
|---|---|
| Rows whose `merchant` is exactly the local part of their own `upi_vpa_norm` | **41** |
| Value carried by those rows | **₹63,743.62** |
| `ece9ae70c53842d58abf92660f4698af@ybl` (PhonePe — `@ybl`) | 22 rows |
| `77d1cc47c9de4e9c8e351a8077d60879@ybl` | 7 rows |

---

## The fix

**One number.** `_payeeTowards`'s cap goes from 40 to 60, matching `_payeeForMandate`
(`:223-225`), which has always used 60 for the same kind of name.

Nothing else was needed. `_tidyPayee` (`:334-344`) already collapses the double space and
strips the leading `AutoPay`, so a successful capture lands on
`bharat connect postpaid bill payment` — **character-for-character the `merchant_norm` of
obligation #4 already on the device**. Had it normalised to anything else, the fix would
have created a second obligation for a commitment that already has one, trading a bad
label for a double count.

The cap is only a runaway backstop; the capture is lazy and still stops at the first
terminator. So its only real requirement is to be wider than the longest genuine payee,
and 40 was not.

## What was *not* a defect

`77d1cc47c9de4e9c8e351a8077d60879` is a **UMN** — a mandate reference — not a payee handle,
carried by HDFC's `E-Mandate!` notice under the literal word `UMN`. Its 7 stored rows look
like the same bug, and are not:

- The body is a future notice (`will be deducted`), so it routes to `_parseNotice`, which
  returns a `FutureDebitNotice` and **no transaction at all**.
- `_noticePayee` (`:325-329`) tries `_payeeForMandate`, which matches
  `for <payee> mandate` at a 60-cap and yields `bharat connect postpaid bill payment`.

Both are pinned by guards below. **The 7 stored rows are therefore stale storage written
before TASK-32 routed notices away from actuals — not a live parser defect.** Re-deriving
them is TASK-37's problem, not this one. Recording this distinction is the point: fixing
the parser here would not have removed those rows, and a device re-measurement that
expected it to would have been read as a failed fix.

---

## Tests

Six added to `test/sms_transaction_parser_test.dart`, group `TASK-36`. **Two are regression
coverage, four are guards** — established by reverting the cap to 40 and re-running, not by
assertion. All bodies are verbatim from the device with the redaction tokens substituted
back.

| Test | Kind | RED symptom at cap 40 |
|---|---|---|
| `a short named payee is read from the body (guard)` | **Guard** | Passes either way. The control that localises the defect to length. |
| `a long named payee is read from the body too` | Regression | `Expected: not a string starting with 'ece9ae70'` / `Actual: 'ece9ae70c53842d58abf92660f4698af'` |
| `and it normalises to the name the obligation is already stored under` | Regression | Same cause; asserts the exact string `bharat connect postpaid bill payment` |
| `the VPA is still captured even when the payee is named (guard)` | **Guard** | `upi_vpa_norm` was never the problem; the handle keeps its own column |
| `a UMN mandate notice is a notice, not a completed debit (guard)` | **Guard** | Already true |
| `and it names the payee, not the UMN (guard)` | **Guard** | Already true — see "What was not a defect" |

---

## Definition of done

- [x] `_payeeTowards` cap raised 40 → 60 with the reason recorded at the pattern
- [x] The captured name normalises to the existing obligation's `merchant_norm`
- [x] The UMN notice path confirmed already-correct and pinned by guards
- [x] 6 tests added, RED confirmed by reverting the cap; 4 honestly labelled guards
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 899 passing, 0 failing (was 893)
- [ ] Device verification — deferred to the end of the batch with TASK-35/37/38

---

## Not fixed here

- **The 41 stored rows keep their handle merchants until a rescan re-derives them**, and
  the 9 stored obligations keep theirs regardless. That is TASK-37.
- **No general guard against a handle reaching `merchant`.** The fallback at `:650` is
  still reachable for a body that genuinely names no payee, which is the correct behaviour
  — a handle beats nothing. But there is no assertion anywhere that a *32-character
  hex-or-base32 token* is implausible as a merchant name, so the next format whose payee
  overruns a cap will fail the same way and be just as invisible. A cheap
  `_looksLikeOpaqueToken` check at the fallback would convert a silent bad name into a
  null merchant, which the ownerless-value metric already tracks. Deliberately out of
  scope: it changes `payee_type` classification for every UPI row and needs its own
  measurement.
- **`_payeeType` still classifies these as `p2p_individual`** (`:700-706`) by testing the
  handle's local part against a fixed merchant word-list. `ece9ae70…@ybl` is PhonePe, a
  merchant, and was stored as an individual. Out of scope; noted for the next pass.
