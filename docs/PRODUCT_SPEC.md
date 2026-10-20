# Product specification

## Product promise

Asray Split makes group travel money effortless: capture an expense in seconds, split it fairly in any practical way, keep receipts and decisions auditable, and show the minimum payments needed to settle the trip.

## Primary users

- Friends sharing a vacation.
- Couples or families traveling with different share weights.
- One organizer entering most costs for a larger group.
- Travelers in weak-connectivity or roaming conditions.
- Guests who may join a trip before creating a full account.

## Core journeys

### 1. Start or join a trip

- Sign in with Apple or email magic link.
- Create a trip with name, image/emoji, dates, base currency, timezone, and optional budget.
- Invite using system share sheet, link, short code, or QR code.
- Invite opens the correct trip through a universal link.
- Recipient can join as an authenticated member; optional guest participants remain supported for people who never install the app.
- Owner can manage roles, remove members, transfer ownership, archive, or delete the trip.

### 2. Add an expense manually

- Enter description, amount, currency, date/time, payer, participants, category, tags, notes, and payment method.
- Split equally, exact amounts, percentages, shares, or adjustments.
- Support multiple payers for a single expense before v1.1 only if the ledger model is ready; otherwise explicitly defer it.
- Validate that allocations equal the expense total in minor units.
- Save instantly offline and visibly show pending/failed sync state.
- Allow edit, duplicate, delete, and attach one or more receipt images.

### 3. Scan a receipt

- Capture using VisionKit document scanning when available; import existing images and PDFs.
- Crop, rotate, compress, and remove metadata before upload.
- Extract merchant, purchase date, currency, line items, quantities, discounts, tax, service fees, tip, and total.
- Show confidence and highlight questionable fields.
- Let users edit items and assign each to one or more participants.
- Allow shared-item weighting, unassigned-item detection, and proportional or custom tax/tip allocation.
- Require reconciliation before save or make the discrepancy explicit.
- Retain the original privately and offer delete/download.

### 4. Understand balances

- Group summary shows total spent, budget progress, personal net balance, category totals, and recent activity.
- “Balances” shows who owes whom and explains how each number was derived.
- Debt simplification minimizes transfers without changing anyone’s net balance.
- Display original and trip-base currencies; preserve the rate and rate date used for historical calculations.
- Never silently recalculate old expenses using today’s rate.

### 5. Settle up

- Suggest settlements from the simplified debt graph.
- Record cash, bank transfer, Venmo, PayPal, or custom settlement without moving money in-app for v1.
- Allow partial payments, reference/note, date, and proof image.
- Both parties see the same result and receive a notification.
- Payment integrations are deep links only until legal/compliance and partner requirements are reviewed.

### 6. Search, export, and leave

- Search by description, merchant, person, tag, category, or amount range.
- Filter by date, payer, payment method, sync status, and receipt presence.
- Export trip CSV and a human-readable summary.
- Leave a trip only after ownership and unsettled-balance conditions are handled.
- Delete account and associated personal data from inside the app.

## Notification requirements

- Member joined/left.
- Expense created, materially edited, or deleted.
- Settlement recorded.
- Receipt scan completed or failed.
- Optional daily “log today’s spending” reminder during an active trip.
- Optional trip-start, trip-end, and unsettled-balance reminders.
- Granular per-trip preferences, quiet hours, and a global opt-out.
- Push payloads contain no sensitive amount/merchant details when the device is locked unless the user opts in.

## AI features

### Release scope

- Receipt structured extraction with per-field confidence.
- Merchant/category suggestion.
- Duplicate-expense warning based on merchant, amount, date, and perceptual image hash.
- Plain-language search translated into local/server filters.
- Explainable trip insights derived from aggregates, not invented financial advice.

### Guardrails

- AI never finalizes or pays an expense.
- User review is mandatory for scan results.
- Validate structured output against a schema and business invariants.
- Strip EXIF/location metadata before upload unless explicitly needed.
- Publish retention and provider-processing behavior.
- Store model/version, latency, outcome, and user correction metrics without logging receipt contents.
- Provide a non-AI manual path for every essential feature.

## Non-functional requirements

- P95 non-AI screen load under 500 ms from local cache.
- Manual expense save feels immediate and works offline.
- No duplicated server rows when requests retry.
- Monetary invariants hold exactly in all supported currencies.
- Crash-free sessions target above 99.8% during staged rollout.
- VoiceOver, Dynamic Type through accessibility sizes, sufficient contrast, Reduce Motion, and minimum tap targets.
- English at launch with localization-ready strings and locale-aware currency/date formatting.

## Explicit v1 exclusions

- Holding user funds, a wallet, lending, credit, or regulated money transmission.
- Direct bank/card transaction import unless a vetted aggregation provider and privacy review are completed.
- Cryptocurrency settlement.
- Public social feed or stranger discovery.
- Generative financial advice.

