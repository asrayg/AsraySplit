# Current state

Updated: 2026-10-20

## Verified in this environment

| Suite | Result | How to run |
| --- | --- | --- |
| iOS unit tests (74) | pass | `xcodebuild test -scheme AsraySplit -only-testing:AsraySplitTests -destination 'platform=iOS Simulator,name=iPhone 15'` |
| iOS UI tests (2, demo backend) | pass | `... -only-testing:AsraySplitUITests` |
| Database: 9 migrations + 153 pgTAP assertions | pass | `scripts/db-test.sh` (local Postgres 16 + pgTAP, Supabase shim) |
| Edge Function shared logic (15) | pass | `node --test supabase/functions/tests/` |
| Debug simulator build, Release device build (unsigned) | pass | Xcode 15.2 / Swift 5.9 |

Not yet verified (no access from this machine): the real Supabase stack (`supabase start` could not pull
Docker images — low disk), Deno type-checking of the Edge Functions, a Release archive with signing, physical
devices, APNs, Sign in with Apple, and the AI provider. CI (`.github/workflows/ci.yml`) runs the real stack.

## Done (by milestone)

**M0 baseline** — Debug/Staging/Release xcconfigs with separate bundle IDs; secrets only in git-ignored
`Config/Secrets.*.xcconfig`; DI composition root; typed `AppError`; redacting logger; CI workflow; demo data
lives only in the in-memory backend and cannot reach Supabase.

**M1 domain + database** — integer minor units everywhere; equal/exact/percentage/shares/adjustment/itemized
splits with deterministic largest-remainder rounding and property tests; ledger tables, transactional RPCs
with idempotency keys + request hashing and optimistic revisions; derived balances and debt simplification;
grants/RLS tests for anon, members, non-members and removed members.

**M2 auth + account lifecycle** — Sign in with Apple (nonce), email magic link (PKCE), Keychain sessions via
the SDK, profile setup, sign-out with unsynced-work warning and cache wipe, JSON data export, in-app account
deletion (ownership hand-off, anonymized labels, storage purge, Apple token revocation, auth user deletion).

**M3 trips + invites** — trip CRUD, archive, delete, leave rules (owner must transfer; unsettled balance must
be acknowledged), roles, removal, ownership transfer, guest participants and claiming; hashed expiring
revocable invites with link, short code, QR and share sheet; brute-force limiting; universal-link handling.

**M4 offline-first** — SwiftData cache + durable outbox with coalescing; backoff; failed/conflict states
with retry, discard, keep-mine/keep-theirs; keyset-paginated canonical sync with tombstones; Realtime
invalidation; settlements (partial, method, reference, note); search and filters; default trip splits;
duplicate expense; undo delete.

**M5 receipts** — VisionKit document camera (multi-page stitching), photo library, PDF/file import; local
normalization (orientation, resize, metadata stripped), SHA-256 + perceptual hash duplicate warnings;
background scan jobs; hardened Edge Function (membership, quotas, timeouts, retry, schema validation);
per-field confidence highlighting, reconciliation, unassigned-item warnings; on-device OCR + manual fallback;
receipt gallery, download/share and deletion; receipts captured offline are queued and uploaded +
attached (`attach_receipt`) once their expense syncs.

**M6** — stored historical rates (ECB via Frankfurter, cached), manual override; server trip summary;
explainable insights with charts; CSV export (formula-injection safe) and shareable summary.

**M7** — device registration, preferences, per-trip mute, de-duplicated push queue, APNs dispatcher with
quiet hours, privacy-safe payloads, dead-token cleanup; notification deep links; local daily reminders.

**Rides** — Uber and Lyft don't grant ride-history API access to new apps, so rides are imported from
receipts: an on-device ride parser (fare, fees, tolls, promotions, tip, route) feeds a "who was in the car"
equal split; a Share Extension accepts receipt screenshots, PDFs and text from any app.

**Email (Resend)** — auth emails via Resend SMTP; queued, idempotent settle-up reminder emails (daily after a
trip ends, plus a "Remind" action for the person owed) with signed one-click unsubscribe.

**M8 (partial)** — adaptive light/dark + increased-contrast palette, Dynamic Type-friendly fonts, 44pt
targets, VoiceOver labels on custom controls, no color-only meaning for balances, original app icon,
privacy manifest, privacy/terms/support pages (`web/`).

## Known gaps / next steps

- **Legal/ops placeholders:** support email, App Store ID, Apple Team ID in `web/.well-known/…`, privacy
  policy legal review, production Supabase project + Vault secrets (see `docs/OPERATIONS.md`).
- **Multiple payers per expense** are supported by the ledger but not exposed in the editor (deferred per
  product spec).
- **Recurring expense templates** are not built (duplicate covers the common case).
- **Localization:** strings use `String(localized:)`/`LocalizedStringKey`; a String Catalog will be
  populated by Xcode on the next IDE build. No translations yet.
- **Accessibility audit** with Accessibility Inspector and largest text sizes has not been performed on
  device; VoiceOver behaviour of charts is basic.
- **Share Extension** needs a signed build with the App Group (`group.<bundle id>`) registered in the
  developer account; unsigned/CI builds compile it but sharing is unavailable.
- **Resend** needs a verified domain and secrets (docs/OPERATIONS.md).
- **Push** requires APNs keys as function secrets and the `maintenance` cron (pg_cron + pg_net + Vault).
- **AI provider fallback:** a single provider (OpenAI) with on-device OCR as the fallback.
- **Load testing** of RPCs/scan endpoint, Supabase advisors, TestFlight, App Store metadata/screenshots.
