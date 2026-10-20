# Target architecture

## iOS layers

```text
App shell / deep links / dependency container
                 |
Feature modules (Auth, Trips, Expenses, Scan, Balances, Settings)
                 |
Use cases and pure money/splitting domain
                 |
Repository protocols
        /                         \
SwiftData offline cache      Supabase repositories
        \                         /
        Sync engine + operation outbox
```

Recommended implementation:

- SwiftUI with small views and `@Observable` feature models on `@MainActor`.
- Swift Concurrency throughout; no callback-based application services.
- SwiftData for cached normalized entities and a durable sync outbox.
- Supabase Swift SDK unless a documented SDK limitation requires direct REST.
- Keychain-backed session handling through the SDK.
- Protocol-backed clock, UUID generator, network, notification, currency-rate, and AI clients for deterministic tests.
- `OSLog` with privacy annotations; production crash/error monitoring without receipt contents.

## Money representation

```swift
struct Money: Hashable, Codable, Sendable {
    let minorUnits: Int64
    let currency: CurrencyCode
}
```

- Maintain a currency metadata table for fraction digits (JPY 0, USD 2, currencies with 3 digits).
- Parse user input with locale-aware `Decimal` and convert once to minor units.
- Allocate remainders deterministically using largest-remainder ordering with a stable participant ID tie-breaker.
- Persist original amount/currency, converted base amount, exchange rate, provider, and rate timestamp.

## Ledger model

Do not store a mutable group balance. Store immutable-ish financial facts:

- Expense header
- One or more payments (who funded it)
- Participant allocations (who consumed it)
- Settlement transfers
- Adjustments/reversals for auditability

Compute each participant’s net:

```text
net = funded expenses - consumed allocations + settlements received - settlements sent
```

Create or edit an expense through one transactional PostgreSQL function that validates membership, currency, totals, revision, and idempotency key. Return the complete canonical record. Deletion should soft-delete or create a reversal so activity history remains understandable.

## Proposed database entities

- `profiles`
- `devices` — APNs token, environment, last seen, notification settings
- `trips` — owner, dates, timezone, base currency, budget, archive state
- `trip_members` — authenticated user, role, status, joined timestamp
- `trip_participants` — named financial participant; optionally linked to a user
- `trip_invites` — hashed token, role, expiry, usage limits, revoked timestamp
- `expenses` — trip, creator, description, date, category, original/base money, revision, idempotency key, deleted timestamp
- `expense_payments` — participant and funded minor units
- `expense_allocations` — participant, owed minor units, input method/value
- `expense_tags` or normalized `tags` plus join table
- `receipts` — private object path, dimensions, hash, scan state, retention state
- `receipt_items` and `receipt_item_participants`
- `settlements`
- `exchange_rates`
- `activity_events`
- `notification_preferences`
- `push_jobs` or a reliable webhook/queue equivalent
- `ai_usage` — request metadata and cost controls, never raw receipt content in logs

Every table needs ownership/membership indexes and explicit grants/RLS. Avoid policies that recursively query each other; use carefully scoped `security definer` membership helpers with empty `search_path`, revoked public execution, and tests.

## Sync contract

- Client creates UUID and idempotency key before local save.
- Local mutation and outbox record commit together.
- Sync worker retries with exponential backoff and network awareness.
- Server RPC performs one transaction and returns `revision` plus `updated_at`.
- Realtime events invalidate/refetch canonical aggregates; do not blindly append.
- Use optimistic concurrency (`expected_revision`) for edits.
- Surface conflicts with a human-readable choice; never silently overwrite financial edits.
- Tombstones propagate deletions.
- On sign-out, remove decrypted local trip data and pending credentials after warning about unsynced work.

## Supabase responsibilities

- Auth: Sign in with Apple and email magic link; optional anonymous-to-account linking only if tested.
- Postgres: source of truth, transactional RPCs, balance views/functions, invite validation.
- Storage: private receipt/proof buckets and short-lived signed URLs.
- Realtime: group-scoped change notification, followed by canonical fetch.
- Edge Functions: AI proxy, account deletion orchestration, push fan-out, exports, provider webhooks.
- Cron/queues: reminder scheduling, stale object cleanup, retryable notifications.

## Security boundaries

- Publishable key may be in the app; secret/service-role and AI keys may not.
- Authorization belongs in RLS/RPC, not in hidden client controls.
- Edge Functions verify the user and trip membership again for sensitive work.
- Rate-limit invites, AI scanning, exports, login attempts, and account deletion.
- Validate image magic bytes, dimensions, MIME type, decompression size, and object path ownership.
- Signed receipt URLs should expire quickly.
- Redact tokens, email, receipt OCR, merchant/amount, and invite codes from logs.

