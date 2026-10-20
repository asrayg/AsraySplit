# QA and App Store release plan

## Automated test matrix

### Unit and property tests

- Money parsing/formatting for 0-, 2-, and 3-decimal currencies.
- Every split mode, negative/zero rejection, rounding, remainders, discounts, refunds, and large values.
- Balance/debt simplification invariants.
- Receipt reconciliation and malformed AI response handling.
- Deep-link routing, notification routing, feature flags, retry/backoff, and conflict resolution.

### Database and security tests

- Every table: anon denial, member allow, non-member denial, removed-member denial, owner/admin boundaries.
- Storage upload/read/delete ownership and signed URL expiry.
- RPC membership checks, total invariants, idempotency, revision conflicts, and atomic rollback.
- Invite expiry/revocation/race tests.
- Account deletion cascade and retained anonymized records.
- Migration up/down or forward-repair test from the last production schema.

### Integration/UI tests

- Sign in with Apple stub and email magic-link route.
- Create/join/archive/leave/delete trip.
- Manual expense in each split mode.
- Offline create/edit/delete then reconnect.
- Two-client Realtime convergence.
- Receipt camera/library, correction, assignment, failure, duplicate warning, and deletion.
- Settlement, export, notification opt-in/deep link, sign-out, and account deletion.
- Permission denied states for camera, photos, notifications, and network.

### Device and quality matrix

- Small supported iPhone, standard current device, and Pro Max.
- Latest iOS plus oldest supported iOS 17 release.
- Light/dark mode, all accessibility text sizes, VoiceOver, Reduce Motion, increased contrast.
- Wi-Fi, cellular, high latency, packet loss, offline, background/foreground, force quit, low storage.
- US and non-US locale, 12/24-hour time, DST crossing, right-to-left smoke test.

## Privacy and legal deliverables

- Public privacy policy describing account/profile data, trip financial data, contacts if used, receipt images/OCR, AI provider processing, analytics/crash data, retention, deletion, and user rights.
- Terms of service and acceptable-use/contact process.
- In-app account deletion; deletion must include automatically created/guest accounts and associated data unless retention is legally required.
- Valid `PrivacyInfo.xcprivacy` and an accurate App Store Privacy Nutrition Label.
- Purpose strings that describe actual camera/photo/notification use.
- Data-processing agreements and subprocessors recorded internally.
- No receipt or financial content in analytics, crash breadcrumbs, push previews, or logs by default.

## App Store package

- Unique final product name, subtitle, keywords, description, category, age rating, copyright, SKU, and bundle ID.
- Original 1024×1024 icon with no alpha and complete asset catalog.
- Required current-device screenshots showing real app UI and no placeholder data claims.
- Support URL, marketing URL if used, and privacy-policy URL.
- App Review notes explaining demo mode/account, receipt scan, notification opt-in, and that settlement records do not transfer money.
- Working review credentials or a fully featured demo mode. Include a sample receipt and invite/QR if needed.
- Export compliance answers, content-rights answers, and App Privacy responses.
- If premium digital features are added, use StoreKit/In-App Purchase and include restore/manage-subscription flows. Do not add payments until the product decision and review requirements are complete.

## Release gates

All must be true:

- Clean Release archive succeeds with production configuration and no development secrets.
- Unit/integration/UI/RLS suites pass.
- Privacy manifest validation and archive validation pass.
- No critical Supabase security/performance advisor findings.
- Production RLS is verified using publishable and authenticated user tokens.
- Account deletion and receipt deletion are tested end-to-end.
- APNs production environment is tested.
- AI spend limits, timeouts, and provider outage fallback are tested.
- Accessibility audit has no critical issues.
- Support/privacy/terms URLs are live.
- Monitoring, alerts, backups, restore procedure, incident owner, and rollback steps exist.
- TestFlight feedback has been triaged and crash-free target met.

## Rollout

1. Internal TestFlight with seeded staging data.
2. External beta with explicit feedback channel and server feature flags.
3. Submit version 1.0 with conservative AI quotas and push enabled gradually.
4. Use phased release; monitor auth failures, sync backlog, RPC errors, receipt latency/cost, crashes, and notification delivery.
5. Pause rollout on balance inconsistencies, unauthorized access, data loss, crash regression, or runaway AI usage.

## Current authoritative references

- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- Apple account deletion guidance: https://developer.apple.com/support/offering-account-deletion-in-your-app/
- Apple privacy manifests: https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk
- Supabase deployment workflow: https://supabase.com/docs/guides/deployment
- Supabase production maturity model: https://supabase.com/docs/guides/deployment/maturity-model
- Supabase database testing: https://supabase.com/docs/guides/database/testing
- Supabase advisors: https://supabase.com/docs/guides/observability/advisors

Re-check these sources immediately before submission because platform requirements change.

