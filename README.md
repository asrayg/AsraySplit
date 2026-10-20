# Asray Split

Native SwiftUI app for splitting group-travel costs: exact multi-currency splits, receipt scanning with
per-item assignment, offline capture, collaborative trips with invites, and minimal settle-up payments.

> **Status:** feature-complete release candidate pending real-backend, device and App Store verification.
> See [docs/CURRENT_STATE.md](docs/CURRENT_STATE.md) for what is verified and what remains.

## Run the app (no backend needed)

```sh
xcodegen generate
open AsraySplit.xcodeproj
```

Without Supabase configuration the app runs in **demo mode** against an in-memory backend that enforces the
same rules as the server. Demo data never leaves the device.

## Connect Supabase

1. `cp Config/Secrets.example.xcconfig Config/Secrets.Debug.xcconfig` and fill in the project host and
   publishable key (for a local stack: `SUPABASE_HOST = 127.0.0.1:54321`).
2. `supabase start` (or `supabase link` + `supabase db push` for a hosted project).
3. Deploy functions and set secrets — see [docs/OPERATIONS.md](docs/OPERATIONS.md).

## Tests

```sh
xcodebuild test -project AsraySplit.xcodeproj -scheme AsraySplit -destination 'platform=iOS Simulator,name=iPhone 15'
scripts/db-test.sh                      # migrations + pgTAP on local Postgres (no Docker)
supabase test db                        # same suite on the real Supabase stack
node --test supabase/functions/tests/   # Edge Function logic (or: deno test)
DB_FIXTURES_OUT=$PWD/AsraySplitTests/Fixtures scripts/db-test.sh   # refresh Swift contract fixtures
```

## Docs

[Product spec](docs/PRODUCT_SPEC.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Implementation plan](docs/IMPLEMENTATION_PLAN.md) · [QA & release](docs/QA_AND_RELEASE.md) ·
[Operations](docs/OPERATIONS.md)
