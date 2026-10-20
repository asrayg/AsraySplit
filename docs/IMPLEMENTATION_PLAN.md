# Implementation plan for Claude

Work in order. Each milestone must leave the main branch building and must include migrations/tests with the feature.

## Milestone 0 — establish engineering baseline

Tasks:

- Create Debug, Staging, and Release configurations with separate bundle IDs and `.xcconfig` files.
- Replace credentials in `Info.plist` with generated/configuration values; add a checked-in example config.
- Add SwiftLint/SwiftFormat if the team will enforce them in CI.
- Set up GitHub Actions for Xcode build/unit tests and Supabase lint/database tests.
- Add dependency injection and move demo fixtures behind a debug-only repository.
- Add a typed application error model and reusable loading/error/empty states.
- Add structured logging with privacy redaction.

Exit criteria:

- Fresh clone can generate and build without secret files.
- CI protects main and produces a test report.
- Demo data can never be uploaded to a non-local Supabase project.

## Milestone 1 — correct domain and database foundation

Tasks:

- Replace `Double` money with `Money`/minor units throughout.
- Implement and exhaustively test equal, amount, percentage, share, adjustment, itemized, tax/tip, discount, and remainder allocation.
- Replace the initial migration with additive, reviewable migrations for the ledger entities in `ARCHITECTURE.md`.
- Add transactional RPCs: `create_expense`, `update_expense`, `delete_expense`, `record_settlement`, `accept_invite`.
- Add idempotency and optimistic revisions.
- Implement server-derived balances and debt simplification.
- Write pgTAP tests for grants/RLS, membership boundaries, RPC validation, and deletion behavior.

Exit criteria:

- Property tests prove allocations always equal totals.
- Two concurrent edits cannot silently overwrite each other.
- A non-member cannot enumerate or mutate any trip data or receipt object.
- Replaying a create request does not create a duplicate.

## Milestone 2 — authentication and account lifecycle

Tasks:

- Integrate the official Supabase Swift SDK.
- Add Sign in with Apple and email magic-link onboarding.
- Persist/refresh sessions securely and handle revoked/expired credentials.
- Build profile editing and auth-state routing.
- If retaining guest/anonymous mode, build an explicit upgrade/link flow.
- Implement sign out, local cache cleanup, data export request, and in-app account deletion.
- Account deletion Edge Function must authenticate, remove private storage, handle owned trips, revoke Apple tokens where applicable, and delete the auth user.

Exit criteria:

- New, returning, expired, revoked, and deleted-account flows are tested.
- Account deletion is discoverable in Settings and removes associated personal data.
- Reviewers can use a documented demo account or fully featured demo mode.

## Milestone 3 — real trips and invitations

Tasks:

- Implement trip CRUD, archive, leave, delete, ownership transfer, member roles, and participant linking.
- Build cryptographically random, expiring, revocable invite tokens stored only as hashes.
- Add universal links, associated domains, QR code, short code, and system share sheet.
- Handle installed, not-installed, authenticated, and unauthenticated invite routes.
- Add member notification preferences and removal/block behavior.

Exit criteria:

- Two physical devices can join one trip and see the same membership.
- Expired/revoked/reused invites fail safely.
- Removing a member immediately removes data access while retaining correct historical participant labels.

## Milestone 4 — offline-first expenses and settlements

Tasks:

- Introduce SwiftData normalized cache and durable operation outbox.
- Implement canonical fetch, pagination, Realtime invalidation, retry, sync status, tombstones, and conflicts.
- Complete add/edit/duplicate/delete expense flows and all split modes.
- Add multiple receipt attachments, notes, categories, tags, recurring templates, and default trip splits.
- Implement settlement suggestions and partial/custom settlement records.
- Add search and filters.

Exit criteria:

- Airplane-mode creates appear on another device after reconnection exactly once.
- Editing and deleting changes balances correctly on both devices.
- Failed sync is visible and retryable; no user work disappears.
- Expense lists remain responsive at 10,000 records with pagination.

## Milestone 5 — production receipt intelligence

Tasks:

- Replace single-photo camera flow with VisionKit document capture plus library/PDF import.
- Normalize orientation, crop, compress, and strip metadata locally.
- Make scans asynchronous: upload, create scan job, poll/Realtime completion, allow user to leave the screen.
- Harden Edge Function auth, membership check, quotas, timeouts, retries, schema validation, provider error mapping, and observability.
- Add per-field confidence, correction UI, unassigned-item warning, receipt reconciliation, duplicate detection, and image lifecycle controls.
- Provide on-device OCR/manual fallback and clear failure recovery.

Exit criteria:

- Test corpus covers restaurants, groceries, VAT, discounts, service fees, tips, long receipts, rotated images, and non-English layouts.
- Bad AI output cannot create an invalid expense.
- Duplicate scans are warned and cost/rate limits are enforced per user.
- Receipt deletion removes the private object according to retention policy.

## Milestone 6 — currency, budgets, insights, export

Tasks:

- Choose and document an exchange-rate provider, licensing, cache policy, and failure behavior.
- Store historical rate/provider/timestamp on every conversion.
- Finish budget categories and trip progress using server aggregates.
- Implement accurate category/person/day summaries and explainable insights.
- Generate CSV and shareable trip summaries through an authenticated export job.
- Add recurring expense templates without silently creating financial records.

Exit criteria:

- Historical totals do not change when rates update.
- Exports reconcile exactly with the visible ledger.
- Insights include their comparison window and can be regenerated from source facts.

## Milestone 7 — notifications and operational services

Tasks:

- Register APNs tokens per device/environment and rotate/delete them correctly.
- Build durable push events for expense/member/settlement changes.
- Add quiet hours, per-trip controls, privacy-safe previews, and notification deep links.
- Keep local reminders for personal capture nudges.
- Add delivery retries, deduplication, expired-token cleanup, and metrics.

Exit criteria:

- Push works in sandbox and production on physical devices.
- A user never receives another trip’s notification.
- Duplicate database events do not create duplicate notifications.
- Tapping each notification opens the correct current record or a safe fallback.

## Milestone 8 — UX, accessibility, and trust

Tasks:

- Conduct full VoiceOver and Dynamic Type audit.
- Fix contrast, tap targets, keyboard/focus behavior, Reduce Motion, and color-only meaning.
- Move all strings into String Catalogs and test long/localized content.
- Add onboarding, contextual help, contact/support, privacy policy, terms, and scan-data explanation.
- Add destructive confirmations, undo where safe, and clear sync/security status.
- Produce original app icon and launch assets; do not copy Splitwise branding or trade dress.

Exit criteria:

- No critical Accessibility Inspector issues.
- Core flows work at the largest accessibility text size.
- Privacy and support links are reachable before and after sign-in.

## Milestone 9 — hardening and launch

Tasks:

- Execute `QA_AND_RELEASE.md` completely.
- Add unit, UI, integration, RLS, Edge Function, migration, performance, and accessibility tests.
- Load test balance/RPC and scan endpoints.
- Run Supabase security/performance advisors and resolve/document every finding.
- Configure staging/production, backups, budget alerts, rate limits, SMTP, monitoring, and incident runbooks.
- Run TestFlight internal then external beta with staged feature flags.
- Prepare App Store metadata, screenshots, review account/notes, privacy answers, age rating, support URL, and deletion instructions.

Exit criteria:

- All release gates are green and rollback has been rehearsed.
- No P0/P1 defects; all accepted lower-severity issues are documented.
- App Review can exercise every reviewed capability without staff intervention.

