# TASK-31 — 79 rows (₹12.4L, 34% of value) are stored with no merchant

**Severity:** Important · **Phase:** 1 (parser) · **Depends on:** TASK-30 merged (the fix
must reach already-stored rows, and this is the task that will finally exercise that path)

Not from the audit. Found on 2026-08-02 by installing the Phase-2 build on the device and
measuring the real database, the same way TASK-28 and TASK-29 were found.

---

## Measured on live data

386 rows on the author's device. **79 of them (20.5%) have `merchant IS NULL`**, carrying
**₹12,39,544 of the table's ₹36,06,019 — 34.4% of all transaction value.**

Every one of these bodies *contains the payee name*. The parser simply has no pattern for
the format, so the row is typed `other` / `payeeType=unknown` and stored ownerless.

| # | Format | Rows | Value | Payee sits at |
|---|---|---|---|---|
| 1 | HDFC `Info: ACH D- <PAYEE>-<REF>.` | 26 | ₹6,71,320 | between `ACH D- ` and the last `-` |
| 2 | HDFC `PAYMENT ALERT! … towards <PAYEE> UMRN: <id>` | 20 | ₹3,93,075 | between `towards ` and ` UMRN:` |
| 3 | Axis multiline `UPI/P2A|P2M/<ref>/<PAYEE>` | 5 | ₹59,422 | last `/`-segment |
| 4 | Axis card `Spent … Card no. … <date> <MERCHANT>` | 2 | ₹10,382 | own line after the date |
| 5 | HDFC ATM `Withdrawn … From HDFC Bank Card xNNNN At <LOCATION>` | 1 | ₹20,000 | after ` At ` |
| 6 | Kotak `Payment of … received for Customer ID … from Kotak - <PAYEE>` | 2 | ₹2,041 | after `Kotak - ` |
| 7 | residual (mandate pre-notifications — see TASK-32, Axis CC due reminders, IMPS credits) | 23 | ₹83,304 | — |

Sample bodies, as redacted on the device:

```
UPDATE: [amount] debited from HDFC Bank [account] on 05-JUL-26.
  Info: ACH D- GROWW INVEST TECH PR-HK7R5VFDNFHO. Avl bal:[amount]
PAYMENT ALERT!
  [amount] deducted from HDFC Bank [account] towards Indian Clearing Corporation Lt UMRN: HDFC70…
[amount] debited / [account] / 01-12-25, 10:58:24 / UPI/P2M/568843434007/CHEQ DIGITAL PRIVAT
Spent [amount] / Axis Bank Card no. [account] / 07-12-25 19:31:06 IST / Google / Avl Limit: [amount]
Withdrawn [amount] From HDFC Bank Card x7102 At SCIENCE CITY-II On 2025-12-07:14:18:33
```

### Confirmed to be a *current* gap, not stale rows

This was checked rather than assumed. Feeding the three `ACH D-` bodies above to the
**current** `SmsTransactionParser.parseOne` returns:

```
parsed=true merchant=null type=other dir=debit payee=unknown   (×3)
```

— byte-identical to what is stored. So `hasSameParseAs` is right to return true and
TASK-30's `refreshParse` is right not to fire. There is nothing wrong with the refresh
machinery; the parser genuinely cannot read these formats today. `grep -rn "ACH" lib/`
returns no parser hit at all.

---

## Why it matters more than the row count suggests

**Recurring detection groups by `merchantNorm`** (`recurring_debit_detector.dart`). Formats
1 and 2 are NACH/ACH mandate auto-debits — 46 rows and ₹10,64,395, 29.5% of all value —
which is *exactly* the recurring-commitment population the forecast exists to detect. With
a null merchant they can never group, so none of them can ever lock as a commitment.

The device bears this out: the `obligations` table holds **one** row, and its merchant is
`xfkxfma537eoyvuzwkvss3vbvbr1oxoo` — a reference number captured as a payee name. The
forecast's entire "Recurring payments" line is ₹1,999 built on that one record, while ₹10L
of genuine mandate debits sit unattributed.

Formats 3–5 are ordinary discretionary spend (Google, Flipkart, an ATM withdrawal at
SCIENCE CITY-II) that lands in the forecast with no owner to explain it, which is the
"no number without a traceable reason" promise failing in the why-log.

---

## Fix

Add a pattern per format to the parser's merchant extraction. Each is a bounded capture
with an unambiguous anchor — none needs the greedy matching TASK-08 removed:

- `ACH D-\s*(.+?)-[A-Z0-9]+\.` → group 1, trimmed
- `towards\s+(.+?)\s+UMRN:` → group 1
- `UPI/P2[AM]/\d+/(.+?)(?:\n|$)` → group 1
- the line following the timestamp line in the Axis `Spent` layout
- `\bAt\s+(.+?)\s+On\s+\d{4}-` → group 1

Watch two things the existing tasks already established:

- **TASK-08's rule** — capture must stop at the first delimiter, not run to end of body.
- **The payer-key caveat in `salary_income_detector`** — a merchant that is really the
  *bank* (`HDFC BANK LTD`, `Indian Clearing Corporation Lt`) is not a useful payee. Decide
  whether to map those to a `bankMandate` payee type rather than a merchant, or the
  recurring detector will lock a commitment named "HDFC BANK LTD".

## Tests to write first

`test/sms_transaction_parser_test.dart` — one per format above, asserting the extracted
merchant and that the capture stops at the delimiter. Add the bank-name case explicitly.

`test/recurring_debit_detector_test.dart` — three monthly `ACH D- GROWW INVEST TECH PR`
debits at a stable amount lock as a monthly commitment. This is the outcome the whole task
is for; it fails today because the merchant is null.

## Verification

```bash
flutter analyze
flutter test
```

Then on the device — and note this task is the one that finally exercises TASK-30:

```bash
flutter build apk --debug && adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Pull-to-refresh on Home, then re-measure. Because these 79 rows are already stored, the
only way they gain merchants is through TASK-30's `refreshParse`. So this verification
closes TASK-30's open on-device box at the same time — see the note recorded there.

## Definition of done

- [ ] A pattern per format, each with a parser test
- [ ] Bank-as-payee decision recorded
- [ ] ACH mandate debits lock as recurring commitments
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] On device: ownerless rows fall from 79, and the count is recorded here
- [ ] On device: the refreshed rows keep their `review_status` and `created_at`
- [ ] Suggested commit: `Extract payees from ACH, NACH, Axis UPI and ATM formats`
