# Expense Insight — install & try it

This app is **100% free and on-device**. It reads your Gmail *read-only, on your
phone*, finds upcoming bills, and shows you what to keep aside for next month.
No server, no database, no AI bill — nothing about your email ever leaves the
phone.

You can try the whole app **without any Google setup** using **"Use sample
data"**. You only need the Google steps (Part C) when you want it to scan *your
real* inbox.

---

## Part A — Get the app onto your Android phone

Pick whichever is easier for you.

### Option 1 — Download a ready APK from GitHub (no tools to install)
1. On GitHub, open the repo → **Actions** tab → **"Build Android APK"** workflow.
2. Click **Run workflow** (on branch `claude/expense-insight-app-i0uo2x`) and wait ~5 min.
3. Open the finished run → **Artifacts** → download **`expense-insight-apk`**.
4. Unzip it → install **`app-arm64-v8a-release.apk`** (the small ~10-15 MB build
   for any modern phone). Send it to your phone (Drive, email, USB…).
5. On the phone, tap the APK. Allow **"Install unknown apps"** for your browser/files app when prompted, then install.

### Option 2 — Build it yourself (if you have Flutter)
```bash
flutter pub get
flutter build apk --release --split-per-abi
# Small APK lands at: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
# Or, with the phone plugged in via USB debugging:
flutter run
```
Both options use the **committed debug keystore**, so they share the same SHA-1
below — you only ever register it once.

---

## Part B — Try it immediately (sample mode)
Open the app → swipe through onboarding → on **"Connect your Gmail"** tap
**"Use sample data instead"**. You'll land in the full app with the demo
dataset. This needs **no Google setup at all** — great for reviewing the UX.

---

## Part C — Turn on real Gmail scanning (free, ~10 minutes, one time)

Everything here is on Google's **free tier**. Do it once.

**Values you'll need** (the Web client ID is created in step 5):
- **Package name:** `com.expenseinsight.expense_insight`
- **SHA-1 fingerprint:** `7E:F6:07:7C:E7:6E:A6:C5:CD:7E:1E:CA:3B:96:32:A5:5D:CE:7A:94`

  (This is the committed debug key. If you re-generate your own keystore, get its
  SHA-1 with `keytool -list -v -keystore android/app/debug.keystore -storepass android`.)

**Steps** (in the [Google Cloud Console](https://console.cloud.google.com)):
1. **Create a project** (top bar → project dropdown → New Project). Name it anything.
2. **Enable the Gmail API:** APIs & Services → Library → search **"Gmail API"** → **Enable**.
3. **OAuth consent screen:** APIs & Services → OAuth consent screen.
   - User type **External** → Create.
   - Fill app name + your email where required.
   - **Publishing status: leave it in "Testing".** (No verification, no cost.)
   - **Test users:** add **your own Gmail address**. Only test users can sign in.
   - **Scopes:** add `.../auth/gmail.readonly` (search "Gmail API … readonly").
4. **Create the Android OAuth client:** APIs & Services → Credentials →
   **Create credentials** → **OAuth client ID** → Application type **Android**.
   - **Package name:** `com.expenseinsight.expense_insight`
   - **SHA-1:** the fingerprint above.
   - Create. (There's **no file to download** for Android — it's matched by
     package + SHA-1.)
5. **Create a Web OAuth client too** (Android's sign-in needs its ID): Credentials
   → **Create credentials** → **OAuth client ID** → Application type **Web
   application** → Create. **Copy its Client ID** (looks like
   `1234…apps.googleusercontent.com`). You don't need the secret.
   - This Client ID is baked into the app as `_webClientId` in
     `lib/services/gmail_service.dart` (it's tied to the SHA-1 above, which
     never changes, so it doesn't need to be entered per-install). If you're
     building your own fork with your own keystore/OAuth clients, update that
     constant with your Web Client ID before building.
6. Open the app → **Connect your Gmail** → **Continue with Gmail** → pick your
   account → approve read-only Gmail access. You may see an **"unverified
   app"** warning — that's expected for your own testing app; continue. The
   app scans recent mail on the phone and shows the bills it found for you to
   **confirm**.

> **Weekly re-login:** because the app stays in "Testing" mode, Google expires
> the token about every 7 days, so you'll tap "Continue with Gmail" again now and
> then. That's the tradeoff for skipping (paid) verification. Still ₹0.

---

## Part E — On-device SMS bank-transaction reading (Android only, **sideload only**)

On Android the app can read your **bank/UPI transaction SMS on the device** to
build a salary-anchored dated cash-flow forecast from your real spending. This is
strictly local and off by default. **iOS does not have SMS reading** — the entry
point is hidden there and only the Gmail path is offered.

### The `READ_SMS` permission and why it's requested
- The app declares `android.permission.READ_SMS` in the manifest. It is requested
  **on demand**, the first time you tap **"Scan messages"** — not at launch and
  not during onboarding.
- If you **deny** it, scanning simply does nothing and the app tells you to *"Grant
  SMS access to scan your messages."* If you **permanently deny** it, the app tells
  you to *"Enable SMS access in Settings"* — nothing is read either way.
- You are always in control of when a scan runs; there is **no background reading**
  and no automatic sync.

### On-demand scan flow
- A scan reads your SMS inbox in batches **on the device**, parses only
  bank/UPI-style transaction messages, and shows the detected transactions for you
  to **confirm** before anything is committed. Duplicates and low-confidence
  matches are queued for review rather than auto-added.
- Everything happens locally: **no SMS content is ever uploaded** to any server.
  (The only path that uploads text is the *opt-in* Gmail AI extraction in Part D,
  which sends *email* bodies — never SMS — and only when you turn it on.)

### The redaction floor (what actually gets stored)
Raw SMS bodies are **never stored verbatim**. Before persistence each message is
reduced to:
- **`raw_body_redacted`** — the message body with account tails, card numbers and
  other identifiers **redacted** out, and
- **`body_hash`** — a **salted** hash used only for de-duplication. The salt is a
  per-install random 32-byte value generated once and kept in the local database's
  `meta` table, so the hash can't be reversed with a precomputed table of common
  bank-message templates.

### Backups are disabled and the database is excluded
- The app sets **`allowBackup=false`** on the Android application.
- On top of that, the **data extraction rules** (`data_extraction_rules.xml`,
  covering both cloud-backup and device-transfer) and the legacy full-backup rules
  (`backup_rules.xml`) **exclude** the transactions database and shared
  preferences. So the SMS-derived data does **not** leave the device via Android
  auto-backup or phone-to-phone transfer.

### At-rest honesty (no false promises)
- The local SQLite database (`transactions.db`) stores the redacted rows as
  **plaintext inside the app's private sandbox**. It is protected by Android's
  app-sandbox isolation and the backup exclusions above — **not** by encryption.
- **SQLCipher (encryption-at-rest) is intentionally deferred** for this version
  because it needs a proper key-management design. A local attacker who already
  has root/filesystem access to your unlocked device could read the sandbox; that
  threat is out of scope for this build. Redaction + salted hashing + no-backup are
  the guarantees we actually ship.

### Sideload only — this build is **Play-Store-ineligible**
Requesting `READ_SMS` makes the app ineligible for Google Play distribution under
Play's SMS/Call Log policy. This is a deliberate, personal-use, **sideload-only**
build (install the APK yourself, per Part A). Do not expect to publish it to the
Play Store as-is.

---

## Troubleshooting
- **`DEVELOPER_ERROR` / "Developer console is not set up correctly" / sign-in
  closes instantly** → the SHA-1 or package name in the Android OAuth client
  doesn't match (Part C step 4), or the Android and Web OAuth clients aren't
  in the same Google Cloud project.
- **AI/Vertex unavailable (on-device extraction supplements it)** → check the project has the
  **Vertex AI API enabled** and the service account has the **"Vertex AI User"**
  role, and the region is right. Review reports how many emails AI analyzed and
  how many required local extraction.
- **"Access blocked / app not verified" and you can't continue** → your Gmail
  address isn't added as a **Test user** (Part C step 3).
- **Signed in but "No bills detected"** → the parser is conservative; add missed
  bills with the **+** button, or widen the search window later. Nothing is added
  without your confirmation.
- **iPhone:** the code is cross-platform, but installing on iOS needs a Mac +
  Xcode (or TestFlight) and an iOS OAuth client. Android is the quick path.

---

## What's free vs. optional paid
- **Free & on-device (default):** Gmail read + rule-based parsing on the phone. ₹0.
- **Optional AI upgrade:** use Gemini/Vertex to read messy emails more accurately
  (see Part D). Costs per-token on your billing; off unless you add a key.

---

## Part D — Optional: AI extraction with your Gemini / Vertex key

Turn this on in the app: **Profile → AI extraction**. When set, fetched emails
are sent to the model in five-email batches with bounded concurrency, retries,
and request/operation time limits. Successful AI batches are retained. Only a
batch the provider cannot process uses on-device rules, so a provider timeout,
quota response, or network interruption does not fail the Gmail sync. Review
shows the AI/local email counts.

> ⚠️ **Privacy & cost:** with AI on, prefiltered email text leaves the phone (to Google's
> API) and usage is **billed to your account** (tiny for personal volume, not
> ₹0). The key/credential lives **on your phone** — fine for a personal build,
> but don't share the APK once you've entered it.

You have two ways to authenticate — pick the one that matches what you have:

### 1) An API key (Google AI Studio, or a Vertex **Express** key)
- Paste it into **API key**. Default model `gemini-2.5-flash` works.
- Get a free Gemini key at <https://aistudio.google.com/apikey> if you don't have one.
- Only change **Endpoint** if your key requires the Vertex host.

### 2) A `credentials.json` service-account key (classic Vertex)
Your `credentials.json` (the file with `"type": "service_account"`,
`"private_key"`, `"project_id"`) authenticates to Vertex AI.
1. In Google Cloud, make sure the project has **Vertex AI API enabled**, and the
   service account has the **"Vertex AI User"** role.
2. In the app → Profile → AI extraction → **Service account JSON**: open
   `credentials.json`, copy **all** of its contents, and paste them in.
3. Set **Vertex region** (default `us-central1`).
4. That's it — it takes priority over the API-key field.

> **Not a service account?** If your `credentials.json` instead contains
> `"installed"` / `"web"` with a `client_id` + `client_secret`, that's an
> **OAuth client** for sign-in, *not* an AI credential — you do **not** paste it
> anywhere. Android Gmail sign-in is authorized by package name + SHA-1 (Part C).
