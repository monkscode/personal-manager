# TASK-33 — A scan reads only the newest ~1,000 inbox messages

**Severity:** Critical (silent exclusion) · **Phase:** 1 (SMS reader) · **Not started**

Found on 2026-08-03 while verifying TASK-31 on the device. Not from the audit, and not
visible from the source alone — the read loop looks exhaustive.

---

## The defect

`SmsReaderService.scan` pages the inbox and stops on the first empty batch:

```dart
final total = await inbox.count(since: since);   // 11,596 — correct
var offset = 0;
while (offset < total) {
  final batch = await inbox.read(since: since, offset: offset, limit: batchSize);
  if (batch.isEmpty) break;                      // <-- fires at ~1,000
  collected.addAll(batch);
  offset += batch.length;
}
```

`count()` pages with `pageSize = 1000` and correctly totals **11,596**. `read()` calls
`SmsQuery.querySms(start: offset, count: 250)` directly, and past roughly the first 1,000
messages that call returns an empty page, so the loop breaks and `scan()` reports success
with a partial result. Nothing anywhere says the read was truncated.

## Measured on live data

One pull-to-refresh on 2026-08-03, SM-G781B, inbox of **11,596** messages reaching back to
2018:

- Lowest `provider:` id re-read by the scan: **11,403**.
- Inbox messages at or above `_id = 11433`: **967**.
- 11 stored rows at provider ids **11,243–11,347** (dated 1–10 Dec 2025) were never
  re-read, so TASK-31's new payee patterns never reached them. Their messages are still in
  the inbox — confirmed by querying the provider — so this is not deletion or ageing.

Those 11 rows are the entire gap between TASK-31's parser coverage (56 rows) and its
on-device result (45 rows).

## Why it is Critical rather than Important

The refresh shortfall is the mild consequence. The severe one is the **first scan**: a user
with more than ~1,000 SMS in their inbox has their transaction history silently truncated
to whatever the newest ~1,000 messages contain, and the scan reports success. On this
device that is roughly six weeks of inbox, against 13 months the analysis window expects
(`kAnalysisLookbackMonths = 13`).

That is a direct breach of the spec invariant:

> **No silent exclusion.** The forecast may not silently drop a material known amount and
> still show a confident surplus. Anything excluded must produce a coverage line naming
> what was excluded and why.

It also silently degrades every downstream detector that needs history depth: the recurring
detector needs 3 occurrences, the seasonal estimator needs 6 distinct months for anything
better than `kSeasonalConfidenceThin`, and salary detection needs a cadence.

## Investigate first

The empty page at ~1,000 has **not** been root-caused. Check, in order:

1. Whether `flutter_sms_inbox`'s `querySms` caps `start`, or caps `start + count`, or
   whether the underlying `ContentResolver` query is capped by the platform.
2. Whether `count()` succeeds only because it always calls with `count: pageSize = 1000`
   while `read()` calls with `count: 250` — i.e. whether the cap is on `start` in units of
   the *previous* page size.

Do not assume the cause from the symptom. The fix depends on which it is: a paging-cursor
change, a different plugin call, or a native query.

## Required fix

1. The reader must read the whole inbox, or the range the caller asked for.
2. A truncated read may never be reported as a plain success. If a limit is unavoidable,
   `SmsScanOutcome` must carry how many messages were skipped so the coverage line can name
   it — the invariant above requires the exclusion to be visible.

## Tests to write first

`test/sms_reader_service_test.dart`:

- [ ] A fake `SmsInboxPort` holding 2,500 messages is read in full — `scan()` returns 2,500,
      not ~1,000. This is the direct regression test and it must fail first.
- [ ] A port that returns an empty page *before* `total` is reached does not report a plain
      success: the outcome names the shortfall.
- [ ] `count()` and the read loop agree on the same population for a given `since`.

## Definition of done

- [ ] Root cause identified and recorded here (not inferred from the symptom)
- [ ] A scan reads the full inbox, or reports the shortfall explicitly
- [ ] `flutter analyze` clean, `flutter test` green
- [ ] On device: re-scan and confirm the 11 Dec-2025 rows finally gain their payees, which
      is the cheapest available end-to-end proof
- [ ] Suggested commit: `Read the whole SMS inbox, or say what was skipped`
