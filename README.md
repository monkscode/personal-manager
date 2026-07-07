# Expense Insight

A Flutter app that looks **forward** at your money: it reads the bills already
sitting in your Gmail — **read-only, entirely on your phone** — and tells you how
much to keep aside for next month, so a lumpy expense like an annual insurance
premium never catches your bank balance off guard.

> Built from the [Expense Insight design](design/project/) handoff. The forecast
> engine is a faithful Dart port of the prototype's logic.

## What it does
- **Forecast dashboard** — "keep ₹X for next month", this-month vs next-month, a
  balance check (surplus/shortfall), category breakdown, and a 12-month outlook.
- **On-device Gmail scan** — signs in with Google (read-only `gmail.readonly`),
  fetches recent transactional mail, and extracts bills **on the phone** with a
  rule-based parser. You **confirm** every detected bill before it's added.
- **Manual add**, investments (FD/PPF/RD/MF) with an FD round-off savings plan,
  transactions, dark/light themes.

## Free & private by design
No server, no database, no AI bill. Gmail is read **read-only on the device** and
nothing about your email leaves the phone. See
[the cost/privacy notes in SETUP.md](SETUP.md#whats-free-vs-optional-paid).

## Try it
See **[SETUP.md](SETUP.md)** — download a prebuilt APK from GitHub Actions (no
tooling needed) or build locally, and the one-time (free) Google setup for real
Gmail scanning. You can explore the whole app immediately with **"Use sample
data"** — no Google setup required.

## Develop
```bash
flutter pub get
flutter analyze
flutter test
flutter run          # on a device/emulator
flutter run -d chrome   # web (sample-data mode; Gmail sign-in is mobile-only)
```

## Project layout
```
lib/
  core/        theme (colors, fonts), ₹ formatting
  data/        models, app state + Riverpod controller, forecast engine, seed data
  services/    email_parser (on-device, tested) + gmail_service (auth + fetch)
  features/    onboarding/ (incl. connect, scan, review) and app/ (home, activity,
               insights, invest, profile) screens
  widgets/     shared UI primitives
test/          forecast-engine, email-parser, and widget tests
design/        the original Claude Design HTML handoff (reference)
```
