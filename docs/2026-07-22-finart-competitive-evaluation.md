# FinArt Competitive Evaluation

**Date:** 2026-07-22  
**App observed:** FinArt 4.9 (`com.finart`, version code 172)  
**Device:** Samsung SM-G781B, Android 13  
**Method:** Read-only ADB interaction, accessibility hierarchy inspection, package/app-op inspection, and APK manifest/class-namespace metadata. No FinArt data, permissions, settings, transactions, or source code were modified. Captured financial values and personal identifiers were not copied into this repository.

## Executive Conclusion

FinArt feels complete because it closes the operational loop around money tracking:

1. Capture transactions continuously from SMS and, when authorized, other-app notifications.
2. Let users rescan, search, filter, classify, and manually repair missing data.
3. Keep account, cash, bill, subscription, and category views connected to the same transaction history.
4. Show dense summaries with immediate drill-down into the rows behind each number.
5. Provide practical controls such as app lock, backup/restore, import, widgets, budgets, and custom month boundaries.

Its main product model is retrospective: what was spent, where, from which account, and whether a bill was paid. It does not visibly answer our north-star question: how much must remain in the bank, by what date, and how much should be reserved each month for a future lump-sum payment.

The correct strategy is therefore **FinArt-grade capture and repair plus our proactive dated forecast and reserve planner**, not a visual clone or a replacement of the current forecast design.

## How FinArt Works

### Capture pipeline

- `READ_SMS` and `RECEIVE_SMS` are granted on the observed phone.
- `com.finart.sms.ReceiveSMS` listens for `SMS_RECEIVED` and `DATA_SMS_RECEIVED` and hands work to `ParsingSmsService`.
- **Rescan SMS** provides an explicit historical recovery path.
- `AppNotificationListener` can capture transaction notifications from other apps when notification access is authorized. It was declared but not enabled on the observed phone, so the current dataset is primarily SMS/manual/import driven.
- The global add action starts with a fast amount keypad, then continues to transaction details.
- Custom file import provides a non-SMS recovery path.

This combination explains why newly installed FinArt populated a broad transaction history quickly while also supporting continuous future capture.

### Classification and ownership

- Transactions are separated into **Expenses**, **Income**, and **Others**, with counts for unresolved/other rows.
- Each row shows category, merchant/description, date, amount, and source account.
- Account scope is first-class: the drawer can switch from **All Accounts** to account-specific views.
- Search, month paging, account/date filtering, manual add, and category drill-down make incorrect parsing repairable.
- Transfers, ATM/cash, bills, and subscriptions are not flattened into ordinary discretionary expense rows.

### Cash model

- ATM withdrawals feed a **Cash in Hand** balance.
- Users can add cash expenses against that balance.
- A policy toggle controls whether unallocated cash in hand is treated as expense.
- A cash-expense reminder helps close the manual-entry gap.

This is stronger than hiding ATM withdrawals, but treating all remaining cash as expense can materially distort category totals. Our implementation should preserve a quantified cash coverage gap unless the user records the cash spend.

### Bills and subscriptions

- Bills and subscriptions have separate views.
- Bills show received date, amount, paid date/status, total due, and a due-only filter.
- Payment observations reconcile a bill from received to paid.
- Subscriptions are inferred from prior recurring payments and show the latest payment and payment account.

The observed subscription view did not visibly show next renewal, cadence confidence, or a set-aside plan. This is an opportunity for our obligation center to be more proactive.

### Analytics

- Home shows current-month expense total, percentage of monthly average, a six-month trend, point values, an average baseline, and recent transactions.
- Expense Details provides pie, bar, and ranked-list modes.
- Category rows show an icon, total, and chevron into supporting transactions.
- The monthly trend remains visible while switching category presentation.

The effective pattern is **summary -> comparison -> ranked drivers -> source transactions**. Our Forecast Explorer should use the same disclosure discipline, but its primary metric remains required-in-bank rather than historical spend.

### Reliability and platform services

- The app process was active during inspection.
- WorkManager had a daily constrained job scheduled.
- Morning, night, and backup alarms were registered.
- A boot receiver restores scheduled work after restart.
- A home-screen widget surfaces expenses and due bills.
- Family sync and Firebase/FCM components provide multi-device/cloud capabilities.

### Privacy and security posture

- App lock and private mode are available.
- Backup, restore, custom import, reset, and account deletion are exposed.
- The manifest explicitly allows Android backup.
- The app requests SMS, notification, internet, location, camera, and other capabilities; Firebase, Facebook, billing, and upload/sync components are present.
- Static inspection cannot prove which transaction fields leave the phone or how cloud data is encrypted/retained. FinArt's privacy policy and network behavior would require a separate review before treating its cloud model as a reference.

Our app should keep its stronger rule: SMS content and derived SMS records remain on-device. Any future family sync, backup, or notification listener must be separately opt-in with exact data disclosures, encryption, deletion, and failure behavior.

## Feature Inventory

| Area | FinArt behavior observed | Product implication |
|---|---|---|
| Home | Monthly spend, average comparison, trend, recent rows | Keep dense evidence, but lead with required-in-bank action |
| Transactions | Month paging, expense/income/other tabs, search, account/date filter | Build a full transaction center after Forecast Explorer |
| Categories | Pie/bar/list, ranked totals, transaction drill-down | Reuse summary-to-source disclosure pattern |
| Accounts | All-account and account-scoped views | Add explicit primary/secondary account scope |
| Cash | Cash-in-hand ledger, policy toggle, reminders | Build cash ledger without pretending untracked cash is categorized |
| Bills | Received/paid reconciliation, total due, due-only filter | Create an obligation center with paid/unpaid/overdue states |
| Subscriptions | Last payment and payment mode | Add next expected date, cadence confidence, and reserve impact |
| Capture | Live SMS receiver, rescan, optional notification listener, manual add | Add background trigger only after privacy/permission design |
| Data repair | Search, filters, manual entry, import | Make every prediction confirmable/editable/dismissible |
| Planning | Monthly budget | Preserve budget as a separate policy, not the forecast truth |
| Utility | Widget, backup/restore, family sync | Later bounded specs with explicit privacy contracts |
| Security | App lock, private mode, account deletion | Add before any broader cloud/sync capability |

## Adopt, Improve, Avoid

### Adopt

- Continuous trigger plus explicit rescan recovery.
- One canonical transaction history feeding every view.
- Month paging and account scope everywhere.
- Expense/income/other separation with visible review counts.
- Bills reconciled by received and paid evidence.
- Cash ledger and cash-entry reminders.
- Ranked category drill-down to source transactions.
- Backup/restore/import and app lock as expected finance-app capabilities.

### Improve

- Replace retrospective-only charts with a selectable 12-month required-balance forecast.
- Show next subscription/annual-obligation date and confidence, not only last payment.
- Turn future obligations into monthly reserve actions.
- Keep hard requirements separate from prediction risk.
- Explain account coverage and stale balances before showing precise surplus.
- Add category/account/date filters together rather than account/date only.
- Use clearer labels for payment, reserve funding, cash withdrawal, and actual cash expense.

### Avoid

- Counting all cash in hand as categorized expense without a coverage warning.
- Letting chart volume displace the action the user must take now.
- Broad cloud/analytics permissions without exact opt-in disclosures.
- Android backup of sensitive local finance data without an encrypted key-management design.
- Treating last payment as sufficient evidence of the next due amount/date.
- Hiding parsing uncertainty merely to make the dashboard look complete.

## Recommended Delivery Sequence

1. **Forecast Explorer and Reserve Planner** - finish the approved current plan; this is the product differentiator.
2. **Capture Reliability and Transaction Center** - background SMS receiver, optional notification listener, rescan, month/type/account/category filters, search, and correction queue.
3. **Obligation Center** - bills and subscriptions with received/paid reconciliation, next expected date, cadence confidence, and reserve impact.
4. **Cash Ledger and Budget Policy** - ATM-derived cash balance, manual cash spend, reminders, and explicit untracked-cash coverage.
5. **Accounts, Cards, and Data Portability** - account scope, card cycles, import/export, encrypted backup/restore, app lock, and private mode.
6. **Widgets and Optional Sync** - actionable due/required-balance widget; family sync only after a separate privacy and encryption design.

Each increment must use the existing canonical ownership rules so the same rupee cannot appear simultaneously as an expense, cash withdrawal, card payment, bill, subscription, and forecast reserve.

## Effect on the Current Plan

The current Home Forecast Explorer and Reserve Planner plan remains valid and should continue after this benchmark review. FinArt evidence reinforces these existing requirements:

- direct values and selected state on meaningful chart points;
- a ranked driver list with drill-down to source rows;
- a separate cash coverage line;
- received/paid reconciliation for obligations;
- account-aware filtering and provenance; and
- no I/O when changing chart month.

FinArt parity work beyond those shared foundations is intentionally deferred to the sequenced specs above so forecast correctness is not diluted by a platform-wide rewrite.
