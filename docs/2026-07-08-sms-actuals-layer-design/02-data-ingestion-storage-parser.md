# SMS Actuals Layer - Data, Ingestion, Storage, and Parser

> Split from docs\2026-07-08-sms-actuals-layer-design.md on 2026-07-09.
> Approximate context budget target: keep each implementation file under 300k characters.
> Read docs\2026-07-08-sms-actuals-layer-design.md first for the split index and implementation order.

**Original line range:** 269-479
**Contains:** Data model, transactions table, obligations table, dedup, scan flow, parser, Indian SMS parsing techniques

---

## 4. Data model

Transactions and confirmed obligation identities live in **SQLite** (new). User preferences and
configured plan settings can stay in `shared_preferences`, but forecast math must read canonical
obligations from the durable obligation store. The current `ExpenseEntry` shape can remain as a UI
adapter during migration; it is **not** sufficient as the canonical model because it lacks source
IDs, dedupe keys, amount status, and review status.

**Money boundary.** Database and forecast-ledger math use integer paise only. A shared
`MoneyParser` converts every rupee source to paise at ingest or at the single forecast-boundary
adapter using decimal parsing, not floating-point arithmetic: normalize currency symbols/commas,
split rupees/paise as strings, round only a third decimal digit when present, reject negative or
ambiguous text, and return `int` paise. Legacy fields that arrive as rupee strings/doubles
(`salary`, `currentBalance`, `ExpenseEntry.amount`, `ContribPlan.amountValue`, Gmail amount
numbers) pass through this same adapter; legacy `double` values are converted from a fixed decimal
string at the boundary and never summed directly. After conversion, all sums/comparisons use
integers; UI formatting converts paise back to rupees for display.

### Table `transactions`

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | autoincrement |
| `sms_id` | TEXT **UNIQUE** | stable dedup anchor — `provider:<android_sms_id>` when available, otherwise `synthetic:<sha256(sender|timestamp|normalized_body)>`; re-scans never double-import |
| `sender` | TEXT | e.g. `VM-HDFCBK` |
| `direction` | TEXT | `debit` \| `credit` (expense vs income) |
| `instrument` | TEXT | `bank` \| `card` — bank spend can affect cash-flow directly; card spend feeds card-cycle/category insight and is paid once via statement |
| `type` | TEXT | `upi` \| `atm` \| `pos` \| `transfer` \| `other` |
| `amount_paise` | INTEGER | INR stored as **paise** (integer) — money is never a float; sums stay exact, the UI divides by 100 for display |
| `txn_date` | INTEGER | epoch ms; falls back to SMS timestamp |
| `txn_local_date` | TEXT | `YYYY-MM-DD` in device local time, captured at ingest for day-level dedup/review |
| `txn_month` | TEXT | `YYYY-MM` in device local time, indexed for month/category queries |
| `effective_month` | TEXT? | `YYYY-MM` budget/economic month for salary/date-drift cases; cash timing still uses `txn_date` |
| `account_last4` | TEXT? | when present |
| `merchant` | TEXT? | cleaned payee |
| `upi_vpa_norm` | TEXT? | normalized VPA/payee handle when present; signal only, not a sole identity key |
| `payee_type` | TEXT | `merchant` \| `p2p_individual` \| `self_transfer` \| `wallet` \| `unknown` |
| `category_key` | TEXT | reuses existing keys: insurance/housing/utilities/subscriptions/transport/groceries/other |
| `confidence` | REAL | 0..1 |
| `needs_review` | INTEGER | 0/1 convenience flag; true for low confidence, first-scan review-all rows, collision sets, or parser uncertainty |
| `review_status` | TEXT | `confirmed` \| `auto_added` \| `needs_review` \| `dismissed` |
| `review_reason` | TEXT? | machine-readable reason: `first_scan`, `low_confidence`, `dedup_collision`, `parser_uncertain`, `user_flagged`, etc. |
| `auto_added_at` | INTEGER? | epoch ms when a later-scan high-confidence row was auto-added; null otherwise |
| `scan_batch_id` | TEXT | id shared by all rows from one scan run, for audit and rollback/correction UI |
| `collision_set_id` | TEXT? | shared id for weak duplicate candidates routed to review together |
| `source` | TEXT | `sms` \| `manual` |
| `ref_number` | TEXT? | UPI/txn reference |
| `balance_paise` | INTEGER? | post-txn balance in **paise** if the SMS reports it |
| `owner_key` | TEXT? | reconciliation owner assigned before totals; null until analysis |
| `coverage_bucket` | TEXT | `anchor_included` \| `dated_event` \| `quantified_excluded` \| `review_pending` |
| `raw_body_redacted` | TEXT | redacted SMS text (masked accounts/balances/refs as needed) — v1 privacy floor |
| `body_hash` | TEXT | hash of normalized original body for re-scan/audit without storing full plain text |
| `created_at` | INTEGER | epoch ms |

**Indexes:** unique on `sms_id`; non-unique on `txn_date`, `txn_local_date`, `txn_month`,
`category_key`, `review_status`, and `scan_batch_id`.

**Decision — raw body:** v1 stores a **redacted** body, not full plain SMS. The goal is enough
context for review/re-parse without retaining balances/account identifiers in plain text. Full raw
text may be added later only with an explicit SQLCipher + Android Keystore key-management design.
The unredacted body may exist only in memory inside the scan/parser call stack; app logs, analytics,
exceptions, SQLite rows, and UI diagnostics use `raw_body_redacted` plus `body_hash`, never the full
plain SMS.

**Decision — at-rest protection (security-critical).** The DB holds SMS-derived sensitive data
(account last4s, balances, merchants, redacted source text), so "never uploaded" is **not** true by
default — Android
auto-backup and `adb backup` can exfiltrate an unprotected SQLite file to Google Drive / a
connected host. Required, treated as an OWASP-MASVS (M9/M2) obligation, not a nicety:
- set `android:allowBackup="false"` and a `data_extraction_rules` / `backup_rules` set that
  excludes the transactions DB **and shared preferences** (§8);
- v1 uses the redaction floor (`raw_body_redacted`). SQLCipher is **not** part of v1 unless the
  dependency and Android-Keystore-backed key management are designed explicitly; storing an
  encryption key in `shared_preferences` is not acceptable.

### Table `obligations`

Confirmed Gmail bills, manual entries, configured contributions that participate in forecast math,
and SMS-detected recurring commitments are stored as durable obligations.

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | autoincrement |
| `source_type` | TEXT | `gmail` \| `sms_recurring` \| `manual` \| `configured_plan` |
| `source_id` | TEXT? | Gmail message id / SMS-derived commitment id / manual uuid |
| `dedupe_key` | TEXT | normalized stable identity; unique for active equivalent obligations |
| `merchant` | TEXT | display merchant |
| `merchant_norm` | TEXT | normalized merchant for matching |
| `category_key` | TEXT | app category key |
| `amount_paise` | INTEGER? | null when amount is missing and requires review |
| `amount_status` | TEXT | `known` \| `missing` \| `estimated` |
| `recurrence` | TEXT | `onetime` \| `monthly` \| `quarterly` \| `annual` |
| `due_date` | INTEGER? | epoch ms when exact date is known |
| `due_day` | INTEGER? | day-of-month for monthly/quarterly cadence |
| `due_month` | INTEGER? | 1..12; required for annual/quarterly forecast inclusion |
| `payment_account_hint_last4` | TEXT? | account historically used to pay; advisory, never a hard exclusion by itself |
| `payment_account_scope` | TEXT | `primary` \| `secondary` \| `unknown` |
| `amount_paid_paise` | INTEGER? | amount already paid for partial bills/card statements |
| `outstanding_paise` | INTEGER? | unpaid remainder when known; becomes dated event or quantified risk |
| `payment_status` | TEXT | `unpaid` \| `paid` \| `partial` \| `possibly_paid` \| `out_of_primary_scope` |
| `next_expected_source` | TEXT | `explicit_due_date` \| `locked_cadence` \| `user_entered` \| `unknown` |
| `upi_vpa_norm` | TEXT? | VPA/payee handle for recurring UPI/P2P candidates; one signal among several |
| `payee_type` | TEXT | `merchant` \| `p2p_individual` \| `self_transfer` \| `wallet` \| `unknown` |
| `user_cadence_status` | TEXT | `algorithm_detected` \| `user_confirmed` \| `user_dismissed` |
| `confidence` | REAL | 0..1 |
| `review_status` | TEXT | `confirmed` \| `needs_review` \| `dismissed` |
| `created_at` | INTEGER | epoch ms |
| `updated_at` | INTEGER | epoch ms |

**No guessed due month:** annual/quarterly obligations with missing `due_month` are stored as
`needs_review` and excluded from dated monthly forecast totals until the user or a reliable source
sets the due month. A **locked cadence** from sufficient SMS history is a reliable source; a single
old annual SMS is not. Excluded known amounts still appear as quantified unscheduled obligations
beside the headline (§7), not as silent omissions.

**Existing data migration:** on first schema introduction, persisted `manualTx` entries from
`shared_preferences` are imported into `obligations`. Current `ExpenseEntry` payloads have already
lost reliable Gmail provenance, so legacy rows import as `source_type=manual` with
`source_id=legacy:<stable-dedupe-hash>`, `amount_status=known`, and a stable dedupe key. From this
migration forward, Gmail confirmations write directly to `obligations` with `source_type=gmail` and
the Gmail message id as `source_id`. The old payload remains readable during migration, but the
forecast reads the canonical obligation store after import.

### Dedup strategy
- Primary: `sms_id` UNIQUE (a re-scan of the same inbox message is a no-op upsert). `sms_id` is
  provider-backed when Android exposes a message id; otherwise it is synthetic from sender,
  timestamp, and normalized body hash. The synthetic id is deterministic across re-runs but still
  tied to the specific observed SMS, not just amount/date.
- Strong secondary: `ref_number` when present and tied to the same account/instrument.
- Heuristic secondary (guards duplicate/re-sent alerts with different SMS ids) is allowed **only**
  when there is a real disambiguator: all of
  `(amount_paise, txn_local_date, account_last4, direction)` or an equivalent account-backed tuple.
  **Amount + day + direction alone never auto-drops a row** because two genuine UPI payments of the
  same amount on the same day are common. Weak duplicates are not silently discarded.
- **No-ref collision rule (decided):** if two new candidates collide on
  `(amount_paise, txn_local_date, account_last4, direction)` and neither has a distinguishing
  reference/balance/merchant signal, both are routed to review as a collision set. They are **not**
  auto-added together even if confidence is ≥0.8. This preserves genuine same-amount payments while
  blocking duplicate resend double-counts.

## 5. Data flow — on-demand scan

1. User taps **Scan messages** (or first-run prompt after Gmail connect).
2. Runtime `READ_SMS` permission requested with a plain-language rationale.
3. `SmsReaderService` returns a typed `SmsScanOutcome`: `success`, `unsupportedPlatform`,
   `permissionDenied`, `permissionPermanentlyDenied`, or `failed`. Only `success` proceeds to
   parsing; all other outcomes surface actionable UI and are never treated as "zero SMS found."
4. On `success`, `SmsReaderService` reads inbox → strict bank filter.
5. `SmsTransactionParser` parses each → `ParsedTxn?` with integer paise, stable `sms_id`,
   redacted body, confidence, review reason, and category.
6. Dedup against stored `sms_id`s and the secondary heuristic.
7. **Confirm flow:**
   - First scan ever → **review all** (high-confidence pre-checked).
   - Later scans → confidence ≥ 0.8 **auto-added**; the rest go to a **review queue**.
   - Collision sets and parser-uncertain rows always go to review, even when confidence is ≥0.8.
   - **Auto-add audit (decided):** auto-added rows are flagged and surfaced in a "recently
     auto-added" view the user can correct — a mis-parsed auto-add silently inflates the seasonal
     training signal for up to a year. The 0.8 threshold and the confidence deltas (§6) are
     **calibrated against the golden corpus** (§10), not hand-asserted.
8. Confirmed or auto-added rows `upsert` into SQLite with `review_status`, `scan_batch_id`, and
   `review_reason`; dismissed rows remain queryable for audit but do not train forecasts.
9. SMS-derived recurring candidates become obligation
   candidates with source/dedupe metadata, not bare `ExpenseEntry` rows.
10. `TransactionsNotifier` reloads and emits a reduced `SmsAnalysisSnapshot`.
11. Home + Insights recompute because `insightsProvider` watches both `AppState` and the snapshot.

## 6. Parser — explicit improvements over the reference

The reference works but has flaws we will not copy:

| Reference flaw | Our approach |
|---|---|
| **Two** `filterBankSms` impls, one leaky (matches "payment"/"amount"/"account") | **One** strict filter; reject OTP/promo like we did for the email parser |
| Incremental sync ignores its `since` (timestamp "plugin issue") → re-imports, no dedup | Real dedup via `sms_id` UNIQUE + strong-evidence secondary checks |
| Global mutable `static` pattern list (`addCustomPattern`) | Immutable built-in library; DB-backed custom patterns is a clean future add |
| Loose regexes — UPI-id `\w+@\w+` also matches emails; hard-requires trailing `\d{4}` | Tighter UPI-id (dots/hyphens, not bare email); account group optional |
| Inconsistent thresholds (`<0.8` vs `<0.6`) | Single source of truth: `needs_review = confidence < 0.8` |
| Naive category map, merchant often null | Reuse our category keys; keyword rules + sender-based fallback |

Confidence model (kept, tuned): base 0.5; +0.3 known bank sender; +0.1 debit/credit keyword;
+0.05 UPI/IMPS/NEFT; +0.1 merchant captured; −0.1 very short body. Clamp [0,1].

### Proven Indian-parsing techniques (adopted from `transaction-sms-parser`, MIT)

Researched the mature [`transaction-sms-parser`](https://github.com/saurabhgupta050890/transaction-sms-parser)
(MIT © Saurabh Gupta; tested across 9 banks, 10 cards, 5 wallets). Its **normalize-then-tokenize**
approach is more robust than per-bank regex and is adopted for `SmsTransactionParser` (and partly
for email amount recovery). We port the *technique*, not code verbatim, and credit the MIT source
in-file.

1. **Normalize first.** Lowercase; strip masking (`x`, `*`, "ending"); canonicalize currency
   (`rs`, `rs.`, `inr`, `₹` → a standalone `rs.` token) and account words (`ac`/`acct`/`account`
   → `ac`); pad `debited`/`credited`; collapse multi-word tokens (`credit card` → `c_card`).
   Downstream extraction runs on clean tokens — the biggest robustness win.
2. **Token-adjacency extraction, not greedy regex.** Amount = the numeric token immediately after
   `rs.` (look one token further on a false positive). Avoids grabbing an unrelated number
   (e.g. "₹10 Lakhs" inside a loan promo).
3. **2-of-N validity guardrail — the "no false data" filter.** Treat a message as a real
   transaction only if **≥2 of {amount, masked account-number, balance, UPI reference, known bank
   sender}** are present. The reference library's strict 2-of-3 (amount/account/balance)
   **over-rejects modern UPI debits**, which frequently carry only **amount + UPI-ref** (no
   account last4, no balance) — and those dominate Indian spending. Widening the signal set keeps
   that recall while promos/OTPs/newsletters still rarely reach two. Transaction type is computed
   only for valid messages.
4. **Balance extraction:** locate a balance keyword (`avl bal`, `available balance`, `a/c bal`,
   `updated balance`, …) then read the following `rs.` amount digit-by-digit (commas + one
   decimal). → feeds the rolling-balance anchor (§7, `latestBalanceAnchor`) **only if** the SMS has
   positive bank-account evidence and no credit-card/available-limit signals.
5. **Merchant/UPI:** `vpa`/`upi ref` keywords + a comprehensive **Indian UPI-handle list**
   (`@okhdfcbank`, `@oksbi`, `@okicici`, `@ybl`, `@paytm`, `@axl`, …) for payee/reference.
6. **Transaction-type keyword groups:** credit = credited|deposited|received|refund|repayment;
   debit = debited|deducted; spend = spent|paid|charged|purchased|sent to → debit.

**Balance-anchor extraction rule.** The parser may store a transaction balance for display/review,
but the forecast anchor is emitted only when all are true:
- bank-account sender or bank-account wording is present;
- a bank-balance keyword is present (`avl bal`, `available balance`, `a/c bal`, etc.);
- no card-limit wording is present (`available credit`, `available limit`, `credit limit`,
  `card limit`);
- the account is the primary salary account, or the user has explicitly selected it.

A card SMS can never become a cash-balance anchor by default.

**Mapping to our goals**
- **SMS layer:** these become the core of `SmsTransactionParser` — normalization pipeline +
  **2-of-N validity** + UPI-handle list. This *replaces* the reference repo's brittle per-bank
  regex as the primary path (bank-specific patterns become an optional refinement, not the base).
- **Email amount recovery (immediate):** apply the same normalization + token-adjacency amount
  extraction to the rule backstop, improving on the current greedy regex.
- **Architecture confirmation:** the reliable trio (amount + account + balance) lives in **bank
  SMS**, not reminder emails — reinforcing SMS as the amount source, with Gmail for
  classification + due dates.

**Related false-positive / dedup practices** (from Gmail-based trackers surveyed): classify with
an `isBill`/`isTransaction` flag *before* extracting (we already do via AI), and use
message-level dedup + a "processed" marker for safe re-runs (we use `sms_id` UNIQUE for SMS;
Gmail can dedup on message-id).
