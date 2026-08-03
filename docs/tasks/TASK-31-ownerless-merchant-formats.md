# TASK-31 — 79 rows (₹12.4L, 34% of value) are stored with no merchant

**Severity:** Important · **Phase:** 1 (parser) · **Depends on:** TASK-30 merged (the fix
must reach already-stored rows, and this is the task that will finally exercise that path)

Not from the audit. Found on 2026-08-02 by installing the Phase-2 build on the device and
measuring the real database, the same way TASK-28 and TASK-29 were found. **Re-measured
2026-08-03** before the fix; see "Corrections to this file".

---

## Measured on live data

386 rows on the author's device. **79 of them (20.5%) have `merchant IS NULL`**, carrying
**₹12,39,544 of the table's ₹36,06,019 — 34.4% of all transaction value.** Both figures
reproduced exactly on re-measurement.

| # | Format | Rows | Value | Payee sits at |
|---|---|---|---|---|
| 1 | HDFC `Info: ACH D- <PAYEE>-<REF>.` | 26 | ₹6,71,320 | between `ACH D- ` and the last `-` |
| 2 | HDFC `PAYMENT ALERT! … towards <PAYEE> UMRN: <id>` | 20 | ₹3,93,075 | between `towards ` and ` UMRN:` |
| 3 | Axis multiline `UPI/P2A\|P2M/<ref>/<PAYEE>` | 5 | ₹59,422 | first segment after the ref |
| 4 | Axis card `Spent … Card no. … <date> <MERCHANT>` | 2 | ₹10,382 | own line after the timestamp line |
| 5 | HDFC ATM `Withdrawn … Card xNNNN At <LOCATION>` | 1 | ₹20,000 | after ` At ` |
| 6 | Kotak `Payment of … received … from Kotak - <PAYEE>` | 2 | ₹2,041 | after `Kotak - ` |
| 7 | residual | 23 | ₹83,304 | — |

The residual 23 breaks down as **17 mandate pre-notices + 5 Axis CC due reminders + 1 IMPS
credit**. The first 22 are all future-tense notices and belong to TASK-32, which stops
them being stored as transactions at all. So the population this task must give owners to
is **57 rows**, and formats 1–6 cover **56** of them.

---

## Corrections to this file (2026-08-03)

**1. "Recurring detection groups by `merchantNorm` … With a null merchant they can never
group, so none of them can ever lock as a commitment." — false, and it misread the
symptom.**

`RecurringDebitDetector._ownerNorm` is `txn.merchant ?? txn.upiVpaNorm ?? txn.sender`.
A null merchant falls back to the **sender**, so the 46 mandate rows always grouped — into
one bucket per bank sender ID, mixing unrelated payees at unrelated amounts. The amount
consistency check then failed, so nothing locked. The rows did not vanish from detection;
they poisoned it. A test now pins the fallback (`a null merchant groups under the sender,
it does not vanish`) so this is not re-derived a third time.

**2. "Confirmed to be a *current* gap, not stale rows" — true for format 1 only, and it
was generalised to all six.** Format 5 (the ATM withdrawal) **already parses correctly**
today: `_merchantAt` matches `At SCIENCE CITY-II On 2025-` and returns `science city-ii`.
Its stored NULL is a **stale row**, not a parser gap, and TASK-30's `refreshParse` is what
will fix it. Written as a test before any change, it was the one of the eight that passed
straight away.

**3. The regex sketch for format 3 was wrong for half its rows.** The file offered
`UPI/P2[AM]/\d+/(.+?)(?:\n|$)` and described the payee as the "last `/`-segment". The P2A
credit shape is `UPI/P2A/154680721130/DHRUVIL U/HDFC/For - Axis Bank`, where the payee is
the **first** segment after the reference and the last segment is `For - Axis Bank`. The
capture has to terminate on `/` as well as the line end. The sketches were correctly
flagged in the brief as "unverified starting points"; this one needed the correction.

**4. An opaque UPI handle outranking a named payee was not in the format table**, though
this file's own prose names it: the device's single obligation was merchant
`xfkxfma537eoyvuzwkvss3vbvbr1oxoo`. That row is *not* ownerless, so it was outside the 79,
but it is the same defect. `Your A/c has been debited towards Google for … <vpa>` says
"Google" in plain words while `_merchant` returned the VPA local part, because the VPA was
checked first. A named payee now outranks the handle.

---

## Fix (as landed)

Five patterns added to the parser, each with an unambiguous anchor and a bounded capture
(TASK-08's rule — none may run to the end of the body):

| pattern | covers |
|---|---|
| `\btowards\s+(.{2,40}?)(?:\s+for\b\|\s+umrn\b\|\s+on\s+\d\|,\|\.(?:\s\|$)\|\n\|$)` | format 2, and the `towards`-vs-VPA case |
| `\bach\s+d-\s*(.+?)-[a-z0-9]+\.` | format 1 |
| `\bupi/p2[am]/\d+/([^/\n]{2,})` | format 3, both P2M and P2A |
| `\bcard no\.[^\n]*\n[^\n]*\d{1,2}:\d{2}:\d{2}[^\n]*\n\s*([^\n]{2,40})` | format 4 |
| `\bfrom\s+kotak\s*-\s*([^\n]{2,40})` | format 6 |

Format 5 needed no pattern. Ordering matters in one place: the UPI-rail pattern is tried
before the Axis card-line pattern, because in the Axis UPI layout the line after the
timestamp *is* the `UPI/…` line. A named payee is resolved before the VPA fallback.

### Bank-as-payee decision (required by this task): **extract, then classify**

The payee is always captured, so the rupee gets an owner — that is the whole point of the
task, and leaving ₹10.6L unattributed to avoid an ugly label would be the wrong trade. But
a bank or clearing house is not a merchant, so:

- New `PayeeType.bankMandate` (stored as `bank_mandate`), set when the extracted payee
  matches `\bbank\s+(?:ltd|limited)\b|\bclearing\s+corp|\biccl\b|\bnse\s+clearing\b|\bbse\s+star\b`.
  Deliberately narrow: **`HDFC LTD` is the housing-finance lender, a genuine EMI payee, and
  must not match** — only `HDFC BANK LTD` does. Both appear on the device.
- `RecurringCommitment` carries the group's payee type, and
  `RecurringObligationCandidates` labels a bank-mandate commitment
  `"Indian Clearing Corporation Lt mandate"` while leaving `merchantNorm` — the grouping
  and matching key — untouched. The forecast never shows a line that reads like a shop.
- A body that names its payee outright now yields `PayeeType.merchant` instead of
  `unknown`, which is what it always meant.

## Tests written first

`test/sms_transaction_parser_test.dart` — one per format, all RED before the fix except
where noted:

- [x] format 1 `ACH D-` → `groww invest tech pr`. **RED:** `Expected: 'groww invest tech
      pr' / Actual: <null>`
- [x] format 2 `towards … UMRN:` → `hdfc ltd`. **RED:** `Actual: <null>`
- [x] format 3 P2M → `cheq digital privat`. **RED:** `Actual: <null>`
- [x] format 3 P2A stops at the next slash → `dhruvil u`. **RED:** `Actual: <null>`
- [x] format 4 Axis card line → `google`. **RED:** `Actual: 'card purchase'`
- [x] format 5 ATM → `science city-ii`. **PASSED WITHOUT CHANGE** — a guard, not
      regression coverage. See correction 2.
- [x] format 6 Kotak → `adani total gas`. **RED:** `Actual: <null>`
- [x] a named payee beats an opaque handle. **RED:** `Actual:
      'xfkxfma537eoyvuzwkvss3vbvbr1oxoo'`
- [x] bank-as-payee: clearing house and `HDFC BANK LTD` are `bankMandate`; `HDFC LTD` and
      `GROWW INVEST TECH PR` stay `merchant`. **RED:** all four were `PayeeType.unknown`.

`test/recurring_debit_detector_test.dart`:

- [x] Three monthly `ACH D- GROWW INVEST TECH PR` debits, parsed from real bodies end to
      end, lock as a monthly commitment. This is the outcome the task exists for. Written
      after the unit-level cycles, so it is an **acceptance** test — but it is genuine
      coverage, not a guard: it fails without the format-1 pattern.
- [x] A null merchant groups under the sender (correction 1).

`test/recurring_obligation_candidates_test.dart`:

- [x] A bank-mandate commitment keeps `merchantNorm` and is labelled
      `"Indian Clearing Corporation Lt mandate"`. **RED:** `Expected:
      PayeeType.bankMandate / Actual: PayeeType.merchant`.

## Verification

```bash
flutter analyze
flutter test
```

`No issues found!` · **787 passing, 0 failing** (764 before TASK-32 and TASK-31).

## Definition of done

- [x] A pattern per format, each with a parser test
- [x] Bank-as-payee decision recorded
- [x] ACH mandate debits lock as recurring commitments
- [x] `flutter analyze` clean, `flutter test` green
- [x] On device: ownerless rows fell **79 → 34** — see below
- [x] On device: the refreshed rows kept their `review_status` and `created_at`
- [x] Suggested commit: `Extract payees from ACH, NACH, Axis UPI and ATM formats`

## On-device result (2026-08-03, SM-G781B, after one pull-to-refresh)

This is the task that finally exercised TASK-30's `refreshParse` at population scale, on
rows that went stale for real. **304 of 387 rows were rewritten in place.**

| | before | after |
|---|---|---|
| rows | 386 | 387 (one new SMS arrived) |
| `merchant IS NULL` | 79 (₹12,39,544) | **34** (₹2,49,940) |
| rows typed `bank_mandate` | 0 | 35 |
| obligations | 2 | 8 |

**`created_at` and `review_status` survive the rewrite**, verified on a specific row: the
28-07-26 Google debit was `id=400, created=1785415878118, auto_added` before and
`id=711, created=1785415878118, auto_added` after. Table-wide, 187 confirmed and 6
dismissed are unchanged. The `id` change is TASK-30's already-recorded benign
REPLACE + AUTOINCREMENT behaviour.

The device's garbage-named obligation is fixed at the source: the Axis rows that stored
merchant `xfkxfma537eoyvuzwkvss3vbvbr1oxoo` now store `google`, and a new commitment
`Hdfc Bank Ltd mandate` (`merchant_norm=hdfc bank ltd`, `payee_type=bank_mandate`) locked
from the ACH history — the bank-as-payee decision working end to end.

### The 34 that remain, and why 45 rather than 56 gained a payee

| bucket | rows | status |
|---|---|---|
| notice rows kept by TASK-32's fix-forward decision | 22 | **as designed** — not deleted, and excluded at read time |
| Dec-2025 rows the scan never re-read | 11 | **blocked by the reader, not the parser** — see below |
| the IMPS credit | 1 | out of this task's format list, as stated above |

45 + 11 = 56, the full format-1..6 population, so the parser's coverage is complete. The
11 were never handed to it.

**New defect found while verifying this: the scan reads only the newest ~1,000 inbox
messages.** `SmsReaderService.scan` computes `total = 11,596` correctly, then its read loop
breaks on the first empty batch. In this run it stopped at provider id ≈ 11,403 — 967 inbox
messages sit at or above 11,433 — and every one of the 11 stragglers is below that boundary
(provider ids 11,243–11,347, dated 1–10 Dec 2025). Their messages are still in the inbox;
they were simply never read. Filed as **[TASK-33](TASK-33-scan-reads-only-newest-1000-sms.md)**,
because it caps TASK-30's refresh reach and, worse, would silently truncate a first scan.

## Findings opened by this task, not fixed here

- **Format 6 is booked as income.** Both Kotak rows are stored `direction=credit`: the
  body reads "Payment of ₹X … is received … from Kotak - Adani Total Gas", which is the
  *biller* confirming it received the user's money. Money left the user. `_isIncomeCredit`
  has nothing to exclude it with, so ₹2,041 of outflow is counted as income. Direction
  inference — TASK-06's area, not merchant extraction.
- **Format 4 is booked as a bank debit, not a card purchase.** `_cardMarker` lists
  `avl lmt` and `available limit`, but the Axis body says **`Avl Limit`**, and
  `card\s+[*x]*\d{4}` does not match `Card no. XX7111` because of the intervening `no.`.
  So Axis card spend lands in bank consumption and will double-count against the card bill
  payment — TASK-28's shape, at ₹10,382 measured.
- **The same alert arrives from several sender IDs.** Rows 23 (`JM-HDFCBK-S`) and 71
  (`AD-HDFCBK-S`) are byte-identical `UMRN: HDFC7020208251013841` debits. Distinct
  `sms_id`s and no shared `ref_number`, so neither dedup path fires. Now that both carry
  the same merchant they will also group as two occurrences of one commitment.
