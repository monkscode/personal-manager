# TASK-45 — A payee capture has terminators but no idea what a payee is

**Phase 7 · Severity: Important (privacy floor + labelling) · State: In progress**

Opened 2026-08-05 while checking Phase 7's open item 4, which recorded a redaction
placeholder reaching the user as a payee name and explicitly gated it as *observed
symptom, no diagnosed mechanism*. Checking it found the mechanism, and the mechanism
turned out to be shared with two larger defects nobody had counted.

---

## The premise that did not survive

Item 4 named TASK-30's reparse as the suspect: the parser re-run over
`raw_body_redacted` seeing `[number]` where digits had been.

**The reparse is not involved and no stored row is wrong for this symptom.** The
`[number]` never touches the database. It is computed at render time:
[real_insights.dart:566-569](../../lib/data/real_insights.dart#L566-L569) builds every
activity row through `MerchantDisplay.resolve`, and
[merchant_display.dart:89-99](../../lib/services/merchant_display.dart#L89-L99) tries a
body-derived merchant **before** the stored column. The stored `card purchase` is never
consulted, so it never had to be wrong.

Reproduced against real ICICI shapes run through the production redactor:

| Redacted body fragment | Rendered payee |
|---|---|
| `… on 05-Aug-26 at [number]. Avl Lmt: [amount]` | `[number]` — the reported symptom, exactly |
| `… To dispute, call [number] or SMS BLOCK [number] to [number]` | `Dispute, Call [number] Or Sm` |

`SmsPrivacy.redactBody` emits five tokens — `[ref]`, `[vpa]`, `[account]`, `[amount]`,
`[number]`. [merchant_display.dart:153](../../lib/services/merchant_display.dart#L153)
rejects three of them, and only when the token is the **entire** capture (`^…$`). So
`[number]` and `[ref]` survive outright, and any placeholder embedded in a longer capture
survives regardless.

---

## A correction to this task's own first measurement

The first pass reported **393 rows** storing an un-redacted digit run in `merchant`. That
number is real but misleading: **157 of them carry nothing but a public bank helpline or
DLT shortcode** (`18605005555`, `919951860002`) picked up out of a footer. A helpline is
not the user's data.

The honest figure is **236 rows / ₹21,15,005.86 whose stored `merchant` carries a
non-public identifier**, across 61 distinct values. Quote that one.

Counting a public phone number as leaked PII would have inflated the severity of this task
by two thirds. **Strip the known-public values before counting a leak.**

---

## The defect

Four capture shapes, each verified against a real device body, each returning something
that is not a payee. All four funnel through `_tidyPayee`, which today rejects only a
capture that is *entirely* digits.

### A — `_merchantUpiRail` runs to the end of the line

[sms_transaction_parser.dart:122-124](../../lib/services/sms_transaction_parser.dart#L122-L124)

```dart
static final RegExp _merchantUpiRail = RegExp(
  r'\bupi/p2[am]/\d+/([^/\n]{2,})',
);
```

`[^/\n]{2,}` is greedy and unbounded. The comment says it is "terminated by the next `/`
as well as the line end", which is true of the **Axis multiline** layout it was written
for. ICICI puts the whole message on one line:

> `Hello! Your A/c no. [account] has been debited by [amount] on 16Nov18. The A/c balance
> is [amount].Info: UPI/P2A/[number]/AKSHAT AMRISHBHAI D. Call 18605005555 (if in India)
> if you have not done this transaction.`

Stored merchant, 90 characters:
`akshat amrishbhai d. call 18605005555 (if in india) if you have not done this transaction.`

The real payee **is** captured — it is the first 19 characters. Everything after the
sentence end is footer. **77 rows** carry a merchant longer than 40 characters; 45 exceed
60. Every one was written **2026-08-03 15:53:51**, which is TASK-33's full-history rescan —
so this is the *current* parser's output, not stale pre-TASK-08 data.

### B — `_payeeTowards` captures the user's own card as the payee

[sms_transaction_parser.dart:226-228](../../lib/services/sms_transaction_parser.dart#L226-L228)

> `Dear Customer, Payment of [amount] has been received towards your ICICI Bank Credit Card
> [account] on 17-JUN-24 through UPI. Thank you.`

Stored merchant: `your icici bank credit card xx7117`.

The terminator works — `\s+on\s+\d` fires correctly. The capture is still not a payee: it
is the user's own instrument, and a payment *towards your own card* has no external payee
at all.

**This is a redaction leak.** On that same row `raw_body_redacted` reads
`Credit Card [account]` — the redactor removed the tail from the body. `merchant` kept
`xx7117` in plaintext. The privacy floor states redaction is the only barrier at rest;
TASK-04 applied it to bodies and balances, and this column was never classified as a body.

Roughly **124 rows** carry a card tail this way (`xx7117` ×44+6, `xx7114` ×16, `xxxx7114`
×13, `xx7111` ×12, `7115` ×10+8, `xx7105` ×7, `xxxx7105` ×8).

### C — `_merchantAt` keeps a reference-bearing rail string

> `[amount] debited from A/c no. [account] on 28-10-21 14:15:16 IST at
> ECS/RAZORPAY SOFTW/[number]. Avl Bal- [amount]. Call [number] if not done by you - Axis Bank`

Stored merchant: `ecs/razorpay softw/111120218042703` (21 rows). The payee is `Razorpay`;
the rest is a rail prefix and a transaction reference the body redacts as `[number]`.

### D — `_merchantTo` captures the counterparty's account number

> `HDFC Bank:[amount] debited from a/c [account] on 07/04/26 to a/c [account]
> (UPI Ref No. [number]). Not you? Call on [number] to report`

Stored merchant: `a/c **7103 (upi`. Again `[account]` in the body, plaintext in `merchant`.

---

## Why it is one task and not four

Every capture reaches the database through **`_tidyPayee`**
([sms_transaction_parser.dart:340](../../lib/services/sms_transaction_parser.dart#L340)) —
`_merchantAt`, `_merchantTo` and all five `_namedPayee` patterns call it. It is the one
place in the parser where a captured string *becomes* a payee, and it currently asks only
one question: is this entirely digits?

That is TASK-41's lesson in its original form. **A rule applied at call sites is not a
rule; only one applied where the set is defined is.** `_tidyPayee` is where the set is
defined. `MerchantDisplay._clean` is its read-time twin — the same rule against the
redaction vocabulary instead of the raw one, and
[merchant_display.dart:136](../../lib/services/merchant_display.dart#L136) already records
that the two must not drift.

---

## Required fix

**Scope decided with the owner 2026-08-05: the capture boundary only.** The 236 rows
already on disk are **not** rewritten — see *Still open*.

1. **Teach `_tidyPayee` what disqualifies a payee**, in one place:
   - cut the capture at a sentence end or at footer vocabulary (`call …`, `if not you`,
     `not you?`, `for dispute`, `has been received`, `if you have not done this`);
   - reject a self-referential instrument phrase (`your <bank> credit card <tail>`,
     a bare `a/c <tail>`);
   - reject or strip an embedded identifier — a 4+ digit run, a masked tail (`xx7117`).
2. **Bound `_merchantUpiRail`** so it cannot run past a sentence end, matching the
   terminator vocabulary the other two captures already use.
3. **Give `SmsPrivacy` the placeholder set as one exported constant**, and have
   `MerchantDisplay._clean` consult it instead of hardcoding three of the five — so a token
   added to the redactor can never silently become a payee name again.
4. **Apply the same disqualification in `MerchantDisplay`**, against the redaction
   vocabulary.

A rejected capture returns `null` and the row falls through to its existing fallbacks. That
is the designed behaviour, not a silent exclusion — no amount changes and no rupee moves.

---

## Tests to write first

- `_tidyPayee` cuts an ICICI single-line UPI body at the sentence end, keeping
  `akshat amrishbhai d` and dropping the footer.
- A payment *towards your own credit card* yields **no** merchant, not the card tail.
- No stored merchant may contain a masked card tail or a 4+ digit run — asserted over the
  four real bodies in this file.
- `MerchantDisplay` renders none of the five redaction placeholders as a payee name,
  embedded or whole.
- Guard: the payees that must survive unchanged — `ACME DIGITAL PRIVAT` from the Axis
  multiline rail, `Razorpay`, `Bharat Connect PostPaid Bill Payment` (TASK-39/42), and the
  two Google subscriptions TASK-42 proved are genuinely different.
- Guard proving the fixture: one body in, one payee out — per Phase 5's lesson, so a
  3-vs-3 result cannot pass for the wrong reason.

---

## Offline prediction — measured before installing

Run over all **2,065** exported rows, before and after, by stashing `lib/` between the two
passes so both used the real production readers.

| | Before | After |
|---|---|---|
| Rendered names containing a redaction placeholder | **348** | **0** |
| Rendered names containing a standalone identifier | 0 | **0** |
| Merchants **written** by enrichment | 35 | 29 |
| …of those, carrying a placeholder or identifier | **4** | **0** |
| Locked recurring commitments | 2 | **2 — identical** |
| Rows whose displayed name changed | — | **684** |

The commitment set is byte-identical, which is the collateral check that mattered: no
commitment was lost because a merchant became null.

**Representative transitions**, all measured rather than argued:

| Before | After | Rows |
|---|---|---|
| `[number], If Not You - Axis` | `Axis Bank` | 109 |
| `[number]` | `Card Purchase` | 76 |
| `Your Axis Bank Credit Card X` | `Axis Bank` | 56 |
| `Your Icici Bank Credit Card` | `ICICI Bank` | 44 |
| `1dhruvilvyas@gmail.com` | `ICICI Bank` | 24 |
| `Ecs/razorpay Softw/[number]` | `Ecs/razorpay Softw` | 21 |
| `Shaila Upendrabhai. Call [nu` | `Shaila Upendrabhai` | 13 |
| `[number]` | `Flipkart` | 7 |
| `Googlepay. Call [number] (if` | `Googlepay` | 4 |

**Rows showing the bank-name fallback rose 246 → 580.** That is the intended direction: a
row whose body names no payee now says `Axis Bank` instead of inventing one, and
`merchantResolved` stays false so it cannot become a recurring owner key. Every transition
was read; none lost a name the body actually contained.

### Two things the prediction caught that reading could not

1. **A blunt `\d{4,}` mangles real names.** It turned the UPI handle `samplepayee1910` into
   `samplepayee` and broke a passing TASK-36 test. An identifier must stand as **its own
   field** — a bank prints a reference in a slot of its own, whereas digits glued to letters
   are part of the word.
2. **Collapsing separators inside the shared rule broke a caller.** `MerchantDisplay._clean`
   strips a `RAZ*` aggregator prefix by matching the asterisk, and the shared sanitizer had
   already eaten it — `RAZ*La Pinoz Pizza` became `Raz La Pinoz Pizza`. Separator handling
   stays with the callers, which each already had it. **A shared rule must not do a job its
   callers are still doing.**

### One change beyond the stated scope, declared

`MerchantDisplay._bankName` never handled a DLT sender with no separators (`VMAXISBK`), so
those rows title-cased the raw header. That was pre-existing and nearly invisible; refusing
junk payees routes far more rows to that fallback, and it would have shipped **`Vmaxisbk`**
to the user on 150+ rows. Retrying the lookup without the two-character operator code is the
same reading `SmsLiveNormalizer._institution` already applies. It also improved ~131 rows
that read `Vmaxisbk` *before* this task.

---

## Definition of done

- [x] Every test above written first, each RED confirmed and its symptom recorded here.
      The parser failures reproduced the stored device values byte-for-byte
      (`akshat amrishbhai d. call 18605005555 …`, `your icici bank credit card xx7117`,
      `ecs/razorpay softw/111120218042703`), which is what proved the fixture.
- [x] The rule is applied at `_tidyPayee` and `MerchantDisplay._clean`, not at call sites.
- [x] The placeholder vocabulary has exactly one definition, owned by `SmsPrivacy`.
- [x] Predicted offline over all 2,065 exported rows **before** installing, per TASK-43.
- [x] Recurring detection measured: commitment set identical, 2 → 2.
- [x] `flutter analyze` — No issues found!
- [x] `flutter test` — **975 passing, 0 failing** (962 before; +13).
- [x] Device-verified, counts reconciled before and after.
- [x] One commit, imperative subject, no AI-attribution trailer.

---

## Device verification — 2026-08-05

Built, installed over the existing app, launched and navigated. No scan triggered, no
destructive control tapped. Database **byte-identical** before and after (`cmp` on two
pulls, 1,642,496 bytes each) — this change writes nothing, which is what it should do: the
display half is read-time, and the parser half only affects rows a future scan writes.

**The reported row is fixed.** The 5 Aug ICICI card purchase renders **`Card Purchase`**,
where TASK-44's install saw `[number]`.

Home is unchanged, as expected for a change that touches names and not amounts:
`Spent this month ₹1,14,879 · 11 payments tracked`, `Your plan now ₹61,415`,
`Free ₹38,585` — all matching TASK-43's recorded state.

**Two whole-history probes through the app's own search**, which matches on the rendered
name across all 2,065 rows:

| Search | Result |
|---|---|
| `call` | **No matching transactions** |
| `number` | **No matching transactions** |

Before this change 180 stored merchants contained the dispute footer and 109 rows rendered
`[number], If Not You - Axis`. Searching the rendered name is a better probe than reading a
screen, because it covers the whole history rather than the rows that happen to be on it.

Names read across August and July: `Card Purchase`, `Hdfc Bank Ltd`, `Lg Electronics App`,
`Gwaliasweetspvtltd`, `Vishvesh Medical Stores`, `Indian Clearing Corp`, `Groww`,
`Autopay Bharat Connec`, `Bharat Connect Gas Bill Paym`, `Shaila Upendrabhai Vyas`, `Cred`,
`Shree Arbuda Stationery`, `Lokesh Roat`, `M S Pihu Enterprise`,
`Cheq Digital Private Limi`, `Cred Club`. No placeholder, no card tail, no footer sentence.

`Shaila Upendrabhai Vyas` is the one to note: it rendered
`Shaila Upendrabhai. Call [nu` before.

All pulled database copies and screenshots deleted.

---

## Still open after this task

1. **The 236 rows already on disk keep their stored identifiers.** This task fixes what the
   parser writes from now on; it does not rewrite history. TASK-30 established that a
   reparse *can* rewrite a stored row's derived fields, so the cleanup is available — it was
   deliberately scoped out here, not overlooked.
2. **`merchant` is still not classified as a redaction surface.** The floor is enforced on
   `raw_body_redacted` alone. Any future derived column extracted from a raw body has the
   same exposure, and nothing tests for it.
3. **One cosmetic remainder, on one row.** `Mob/ccpmt/8mcqqe / Xxxxxx` — a bare masked run
   (`xxxxxx`) with no digits after it is not classified as an identifier, so it survives as
   a word. Strictly better than the `Mob/ccpmt/8mcqqe[number]/[nu` it replaced, and left
   alone deliberately: four passes of regex tuning had already reached diminishing returns
   on a display cosmetic, and the mechanism is understood rather than unexplained.
4. **The body often names the merchant while the row shows a fallback.** `Info:Amazon.in -
   Bil` and `Info:PSI SERVICES` sit in bodies that now render `Card Purchase`, because
   `_merchantFromBody` has no `Info:` branch. Adding one is the obvious next labelling win
   and was out of scope here — this task was about what a payee is **not**.
