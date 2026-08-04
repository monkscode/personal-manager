# TASK-39 — The `at`/`to` merchant fallbacks never tidied what they captured

**Severity:** Important · **Phase:** 5 · **Depends on:** TASK-36

Found on the device on 2026-08-04 while verifying TASK-35, as a "Drivers" row on the Home
screen reading **`autopay  bharat connec`** — with the boilerplate prefix and the double
space intact.

---

## The defect

`_merchant` (`sms_transaction_parser.dart:639-664`) tries `_namedPayee` first, then the
UPI handle, then two generic fallbacks. `_namedPayee` runs **every** capture through
`_tidyPayee` (`:678`), but the two fallbacks below it did not:

```dart
final at = _merchantAt.firstMatch(lower)?.group(1)?.trim();
if (at != null && at.length >= 2) return at;
for (final match in _merchantTo.allMatches(lower)) {
  final to = match.group(1)?.trim();
  if (to != null && to.length >= 2 && !_bareDigits.hasMatch(to)) return to;
}
```

A bare `.trim()`. So everything `_tidyPayee` exists to remove — collapsed whitespace, a
leading `AutoPay`, a trailing `no.` / `a/c` — survived on any row that reached a fallback.

The device's body, an HDFC UPI mandate debit with no VPA and no `towards`:

```
UPI Mandate:
Sent Rs.118.00
from HDFC Bank A/c XX1234
To AutoPay  Bharat Connec
03/08/26
```

No `_namedPayee` pattern matches it and there is no handle, so it falls to `_merchantTo`
and stores `autopay  bharat connec` verbatim. HDFC truncates the payee in the message
itself — `Bharat Connec` is the bank's doing and is not recoverable — but **the prefix and
the double space are ours**.

## Why it matters more than a scruffy label

It mints a *fourth* stored identity for one commitment. Bharat Connect is already
fragmented across:

| Identity | Where | Rows |
|---|---|---|
| `bharat connect postpaid bill payment` | obligation #4 | — |
| `ece9ae70c53842d58abf92660f4698af` | obligation #2, and transactions | 22 |
| `77d1cc47c9de4e9c8e351a8077d60879` | transactions (a UMN) | 7 |
| **`autopay  bharat connec`** | transactions | **8** (₹1,054.99) |

Every extra spelling is another `merchantNorm`, and `merchantNorm` is what the obligation
dedupe key is built from (`recurring_obligation_candidates.dart:53-54`). So each one is a
candidate for its own obligation — which is TASK-37's double count, fed from upstream.

---

## The fix

Route both fallbacks through the same tidier `_namedPayee` already uses:

```dart
final at = _tidyPayee(_merchantAt.firstMatch(lower)?.group(1));
if (at != null) return at;
for (final match in _merchantTo.allMatches(lower)) {
  final to = _tidyPayee(match.group(1));
  if (to != null) return to;
}
```

The hand-written guards go with it: `_tidyPayee` already rejects a bare run of digits and
anything shorter than two characters (`:342`), which is exactly what the loop was checking
inline. Strictly less code and strictly more normalisation.

`autopay  bharat connec` → `bharat connec`.

---

## Tests

One added to `test/sms_transaction_parser_test.dart`. Regression coverage; RED captured on
the unfixed tree.

| Test | Kind | RED symptom |
|---|---|---|
| `the \`To <payee>\` fallback tidies the name it captures` | Regression | `Expected: 'bharat connec'` / `Actual: 'autopay  bharat connec'` |

The full suite passed unchanged afterwards, so no existing `at`/`to` capture depended on
keeping its boilerplate.

---

## Definition of done

- [x] Both fallbacks call `_tidyPayee`; the duplicated inline guards removed
- [x] 1 regression test, RED recorded against the real device body
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — 904 passing, 0 failing (was 903)
- [ ] The 8 stored rows keep `autopay  bharat connec` until a rescan re-derives them —
      and per TASK-37 a rescan should wait for the retirement path

---

## Not fixed here

- **`Bharat Connec` stays truncated**, because the SMS is truncated. Joining it to
  `bharat connect postpaid bill payment` is merchant-identity resolution — the same
  unsolved problem as `hdfc ltd` / `hdfc bank ltd` (TASK-34) and
  `google` / `google asia pacific pte.ltd` (TASK-37). Recorded, not attempted.
- **`_merchantAt`'s tidying is now untested.** The new test covers the `to` path only;
  the `at` path changed identically but has no case of its own, because no device body
  exercised it. Worth one when a real example turns up.
