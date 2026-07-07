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
3. Open the finished run → **Artifacts** → download **`expense-insight-debug-apk`**.
4. Unzip it → you get **`app-debug.apk`**. Send it to your phone (Drive, email, USB…).
5. On the phone, tap the APK. Allow **"Install unknown apps"** for your browser/files app when prompted, then install.

### Option 2 — Build it yourself (if you have Flutter)
```bash
flutter pub get
flutter build apk --debug
# APK lands at: build/app/outputs/flutter-apk/app-debug.apk
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

**The two values you'll need:**
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
5. Reinstall/open the app → **"Continue with Gmail"** → pick your account →
   approve read-only Gmail access. You may see an **"unverified app"** warning —
   that's expected for your own testing app; continue. The app scans recent
   mail on the phone and shows the bills it found for you to **confirm**.

> **Weekly re-login:** because the app stays in "Testing" mode, Google expires
> the token about every 7 days, so you'll tap "Continue with Gmail" again now and
> then. That's the tradeoff for skipping (paid) verification. Still ₹0.

---

## Troubleshooting
- **`DEVELOPER_ERROR` / sign-in closes instantly** → the SHA-1 or package name in
  the Android OAuth client doesn't match. Re-check Part C step 4.
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
- **Optional AI upgrade (later):** to squeeze more out of messy emails, a Gemini/
  Vertex model can be added *behind a small proxy* (never with keys in the APK).
  That path costs per-token and needs a billing account, so it's off by default.
