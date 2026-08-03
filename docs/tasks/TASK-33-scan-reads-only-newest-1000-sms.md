# TASK-33 — A scan reads only the newest 1,000 inbox messages

**Severity:** Critical (silent exclusion) · **Phase:** 1 (SMS reader) · **Done**

Found on 2026-08-03 while verifying TASK-31 on the device. Not from the audit, and not
visible from the source alone — the read loop looks exhaustive.

---

## The defect

`SmsReaderService.scan` reads the newest 1,000 inbox messages of an 11,596-message inbox
and returns `SmsScanOutcome.success` with no indication that anything was left out.

## Root cause — confirmed, not inferred

The cap is in **`flutter_sms_inbox` 1.0.5's Dart wrapper**, `lib/src/sms.query.dart`. It is
neither the ContentResolver nor the platform.

`SmsQuery.querySms` **never sends `start` to the platform at all**. Its private `_querySms`
builds the argument map from `count`, `address` and `thread_id` only. It emulates paging in
Dart: it asks the native side for `start + count` messages from the newest end and slices
the first `start` off the result — after clamping that request to its own window:

```dart
static const int _maxQueryWindow = 1000;
...
final int requestCount = (remainingCount + remainingStart).clamp(1, _maxQueryWindow);
...
startIndex = remainingStart.clamp(0, fetched.length);
List<SmsMessage> effective = (startIndex == 0) ? fetched : fetched.sublist(startIndex);
```

So the newest 1,000 messages are the entire addressable window, for **any** `(start, count)`
pair. `start >= 1000` slices a 1,000-element list at index 1,000 and yields empty.

The native handler is not the problem. `SmsQueryHandler.java` *does* implement `start` — it
skips that many rows of the provider's newest-first cursor — and clamps `count` to
`MAX_FALLBACK_QUERY_COUNT = 1000` per call. It was simply never being told which offset the
caller wanted.

Measured against a fake provider of 2,500 messages driving the real wrapper
(`querySms(start: S, count: C)` → messages returned, and what the platform was handed):

| start | count | returned | platform saw |
|---|---|---|---|
| 0 | 250 | 250 | `{count: 250}` |
| 750 | 250 | 250 | `{count: 1000}` |
| 1000 | 250 | **0** | `{count: 1000}` |
| 0 | 1000 | 1000 | `{count: 1000}` |
| 1000 | 1000 | **0** | `{count: 1000}` |

`start` never appears in the platform arguments in any row.

## Three premises in the original write-up did not survive the source

Recorded so they are not re-derived:

1. **`count()` did not return 11,596.** The original text annotated
   `final total = await inbox.count(since: since); // 11,596 — correct`. `count()` pages
   with `pageSize = 1000` and is capped by the same 1,000-message window, so it returned
   exactly **1000** for any inbox of 1,000 or more. Measured against a 2,500-message fake
   provider: `adapter.count() = 1000`. The 11,596 figure is a real measurement, but of the
   *provider* (`content query --uri content://sms/inbox | wc -l`), not of `count()`.

2. **`if (batch.isEmpty) break;` never fired.** With `total = 1000` and `batchSize = 250`
   the loop ran offsets 0/250/500/750, collected exactly 1,000, and exited *normally* on
   `offset < total`. The observed count was 1,000 exactly, not "roughly 1,000 then an empty
   page". This is the sharp end of the defect: `collected.length == total`, so the scan was
   internally self-consistent and **a shortfall could not be detected by comparing the read
   against `count()`**. Any fix has to obtain a true total from outside the capped window.

3. **The truncation was not "roughly six weeks".** Measured on the device: the 1,000th
   newest message is dated **2025-12-18**, so the readable window reached back about 7.5
   months, not six. The severity is real but its shape is different — of the **1,962** inbox
   messages inside the 13-month analysis window (`kAnalysisLookbackMonths = 13`), the reader
   could see **1,000**. It was losing **962 messages, 49% of the analysis window**. The
   window also creeps forward: every new SMS pushes one more off the readable tail, so each
   scan saw less history than the one before it.

The first test the original write-up asked for — a fake `SmsInboxPort` of 2,500 messages
read through `scan()` — would have **passed** unchanged. The existing `_FakeInbox` is a
faithful port; the entire defect lived in `FlutterSmsInboxAdapter`, which had no test
coverage at all. The regression test has to drive the adapter against a mocked platform
channel.

## Measured on live data (2026-08-03, SM-G781B)

Inbox of **11,596** messages reaching back to 2018, verified against the provider.

- Lowest `provider:` id re-read by the pre-fix scan: **11,403**.
- 11 stored rows at provider ids **11,243–11,347** (dated 1–10 Dec 2025) were never re-read,
  so TASK-31's new payee patterns never reached them. Their messages are still in the inbox.
- Those 11 rows are the entire gap between TASK-31's parser coverage (56 rows) and its
  on-device result (45 rows).

## Why it is Critical rather than Important

The refresh shortfall is the mild consequence. The severe one is the **first scan**: a user
with more than 1,000 SMS in their inbox has their transaction history silently truncated to
whatever the newest 1,000 messages contain, and the scan reports success — here, half the
analysis window.

That is a direct breach of the spec invariant:

> **No silent exclusion.** The forecast may not silently drop a material known amount and
> still show a confident surplus. Anything excluded must produce a coverage line naming
> what was excluded and why.

It also silently degrades every downstream detector that needs history depth: the recurring
detector needs 3 occurrences, the seasonal estimator needs 6 distinct months for anything
better than `kSeasonalConfidenceThin`, and salary detection needs a cadence.

## The fix

`FlutterSmsInboxAdapter` now talks to the plugin's **platform channel** directly
(`plugins.juliusgithaiga.com/querySMS`, `JSONMethodCodec`, method `getInbox`), passing both
`start` and `count`, and bypasses `SmsQuery` entirely. The native handler honours `start`,
so real paging is restored; pages are capped at `kSmsNativePageLimit = 1000` because the
native side clamps there anyway.

The channel name and argument shape are `flutter_sms_inbox` internals. The package is pinned
in `pubspec.lock`, and a rename would raise `MissingPluginException` → `SmsScanStatus.failed`
— a loud failure, not another silent truncation.

Two consequences of un-capping the loop, both handled:

- `count()`'s paging loop is now unbounded, so a platform that stopped honouring `start`
  would spin forever. It detects a page that reopens on the same message id as the previous
  one and throws `PlatformException('paging_unsupported')`, which surfaces as a failed scan.
- A truncated read is no longer representable as a plain success. `SmsScanOutcome` carries
  `skippedCount` (`isComplete`), `ScanRunResult` carries `skippedMessages` (`isComplete`),
  and `scanShortfallMessage` turns a non-zero value into a sentence the pull-to-refresh
  snackbar shows before anything else. A cancelled scan names its unread remainder the same
  way.

## Tests

`test/flutter_sms_inbox_adapter_test.dart` (new — the adapter had none). A `FakeSmsProvider`
reproduces `SmsQueryHandler.java` faithfully, including the 1,000-row clamp, so the ceiling
is reachable from a test at all:

- [x] `count()` reports the whole inbox, not the newest 1,000 — **RED: expected 2500, got 1000**
- [x] `read()` reaches past offset 1,000 — **RED: expected 250 messages, got []**
- [x] paging `read()` to exhaustion yields every message exactly once — **RED: 1000 of 2500**
- [x] `count()` and a full paged read agree on the same population for a `since` — **RED: expected 1500, got 1000**
- [x] the adapter tells the platform which offset it wants — **RED: expected start 1000, got null** (the root cause, asserted directly)
- [x] `scan()` through the real adapter returns all 2,500 — **RED: got exactly 1000**
- [x] a platform that ignores `start` fails loudly — **RED: the suite hung; the loop never terminated and the per-test `Timeout` did not interrupt it**
- [x] guards (pass either way, not regression coverage): an inbox under the page size; an
      empty inbox

`test/sms_reader_service_test.dart`:

- [x] a page that goes empty before `total` reports the shortfall — **RED: expected 1500, got 0**
- [x] a cancelled scan names the messages it never read — **RED: expected 4, got 0**
- [x] guards: a complete read reports no shortfall; a failure carries no shortfall

`test/sms_scan_orchestrator_test.dart`:

- [x] the run reports how many messages the reader never saw — **RED: `skippedMessages` undefined**
- [x] guards: a complete read reports nothing skipped; a no-op claims no coverage

`test/home_screen_test.dart`:

- [x] a truncated scan names how many messages went unread — **RED: `scanShortfallMessage` undefined**
- [x] guards: a complete scan says nothing about coverage; a failed scan makes no coverage claim

## Definition of done

- [x] Root cause identified and recorded here (not inferred from the symptom)
- [x] A scan reads the full inbox, or reports the shortfall explicitly
- [x] `flutter analyze` clean, `flutter test` green — **807 passing** (was 787)
- [x] On device: re-scan and confirm the 11 Dec-2025 rows finally gain their payees
- [x] Suggested commit: `Read the whole SMS inbox, or say what was skipped`

## On-device result (2026-08-03, SM-G781B, after the fix)

One pull-to-refresh, under 25 seconds:

| | before | after |
|---|---|---|
| stored rows | 387 | **2,058** |
| lowest provider id | 11,229 | **1** (the oldest message in the inbox) |
| stored history | 2025-11-29 → 2026-08-03 | **2018-10-21** → 2026-08-03 |
| rows written above the old `MAX(id)` 996 | — | 1,684 |
| confirmed / dismissed | 187 / 6 | **187 / 6** |

Reaching provider id 1 is the conclusive proof: the reader now walks the inbox to its end.
The 187 confirmed and 6 dismissed decisions survived a scan that rewrote 1,684 rows, so
TASK-02's and TASK-30's protections held at this scale. `needs_review` went 2 → 109; the 107
additions are newly-visible history, not a defect. The shortfall snackbar did not appear,
which is correct — nothing was skipped.

The 11 named rows, all of which gained a payee (12 of the 14 rows in that provider range
did, and one row — 11,335, `raj associates` — had never been stored at all):

| provider id | before | after |
|---|---|---|
| 11,243 | *(none)* | cheq digital privat |
| 11,268 | *(none)* | flipkart |
| 11,279 / 11,280 / 11,288 | *(none)* | indian clearing corporation lt |
| 11,282 | *(none)* | hdfc bank ltd |
| 11,285 | *(none)* | hdfc ltd |
| 11,300 | *(none)* | science city-ii |
| 11,303 | `6df1c437707d453884b7f9803b9cf72a` | google |
| 11,304 | *(none)* | google |
| 11,347 | *(none)* | pradip suryakant sa |

Row 11,303 is worth noting separately: its stored merchant was a 32-hex-character string —
a hash written into the merchant column — and the re-parse replaced it with `google`.

## Findings for later tasks — not fixed here

Newly-readable history exposes payee-extraction defects on older message formats. Ownerless
value is down from TASK-31's 34% to **15.1%** (236 of 2,058 rows, ₹44,56,109 of ₹2,49,69,373),
but the remaining tail has a clear shape:

- **The user's own address is captured as a merchant.** `1dhruvilvyas@gmail.com` appears as
  the payee on many review rows. A self-addressed VPA/email is a self-transfer, not a shop —
  TASK-31's `PayeeType.selfTransfer` exists for exactly this and is not being reached.
- **Card and balance descriptors captured as payees**: `your card a/c xxxx7105`,
  `your amazon pay balance`, and on row 11,244 `your axis bank credit card xx7114`. Greedy
  merchant capture (TASK-08's shape) on formats that were never visible before.
- **`card purchase` is stored as a merchant** (row 11,245) rather than as "no payee found".
  A generic placeholder in the merchant column is worse than null: it forms an owner key
  that groups unrelated transactions.
