# AsraySplit launch guide

This is the shortest path from the current release candidate to a live App Store release. The app is feature-complete enough for beta testing, but production services, signing, legal details, and real-device verification still block launch.

## What is left

### Must finish before TestFlight

- [ ] Create separate staging and production Supabase projects.
- [ ] Copy `Config/Secrets.example.xcconfig` to `Secrets.Staging.xcconfig` and `Secrets.Release.xcconfig`; add each project's host and publishable key. These files are git-ignored.
- [ ] Apply all migrations, deploy all Edge Functions, and add provider secrets.
- [ ] In Apple Developer, create the production and staging App IDs, the App Group for the app and Share Extension, Sign in with Apple, Associated Domains, and APNs credentials.
- [ ] Put the Apple development team ID in Xcode/project configuration and replace `TEAMID` in `web/.well-known/apple-app-site-association`.
- [ ] Replace the support-email, legal-entity, publication-date, review-account, and App Store-ID placeholders.
- [ ] Host `web/` on `asraysplit.app` with HTTPS and the required universal-link rewrites.
- [ ] Make a signed Release archive and validate it in Xcode Organizer.

### Must verify before public launch

- [ ] Test Sign in with Apple and email magic links against production-like services.
- [ ] Test invites/universal links, the Share Extension/App Group, receipt upload and AI fallback, push notifications, reminder email unsubscribe, data export, and account deletion on physical devices.
- [ ] Run the full automated suites and the device/accessibility matrix in `QA_AND_RELEASE.md`.
- [ ] Run Supabase security/performance advisors and load-test the important RPC and receipt paths.
- [ ] Complete legal review, App Privacy answers, screenshots, review notes, support ownership, monitoring, backups, rollback, and incident contacts.
- [ ] Run an internal TestFlight, then an external beta, and triage crashes and feedback before submission.

Nice-to-have work that does not need to block version 1.0: multiple payers in the expense editor, recurring templates, translations, richer chart accessibility, and a second cloud AI provider. The app already falls back to on-device OCR.

## Deploy the backend

Install the Supabase CLI, sign in, create the project in the Supabase dashboard, and keep the project reference handy. From the repository root:

```sh
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase functions deploy scan-receipt exchange-rates delete-account maintenance email-unsubscribe
```

Set the production secrets described in `OPERATIONS.md`: OpenAI, APNs, Sign in with Apple, Resend, email-link signing, and the invite host. Then configure the two Vault secrets used by the maintenance cron. Do not put service-role, OpenAI, APNs, Apple private, or Resend keys in an xcconfig or in git.

Configure auth and SMTP, then verify migrations and functions against the linked project:

```sh
supabase config push
supabase db lint --linked --level warning
supabase functions list
supabase secrets list
```

Use `OPERATIONS.md` as the authoritative command-level runbook; it also covers monitoring and emergency shutdowns for AI, email, and push.

## Deploy the website and universal links

Publish the contents of `web/` at `https://asraysplit.app`. Configure clean routes so `/join/*` serves `/join/index.html` and `/trip/*` serves `/trip/index.html`. Serve `/.well-known/apple-app-site-association` as `application/json` with no redirect.

Before publishing:

1. Replace `TEAMID` with the Apple Developer Team ID.
2. Replace `id0000000000` with the real App Store ID once Apple assigns it.
3. Replace every bracketed legal/support placeholder.
4. Confirm the support, privacy, and terms pages return HTTP 200 over HTTPS.

## Configure and archive the iOS app

1. Open `AsraySplit.xcodeproj` and select the AsraySplit target.
2. Set the Team under Signing & Capabilities for both AsraySplit and AsraySplitShare.
3. Confirm the Release bundle ID is `com.asray.AsraySplit` and the extension is `com.asray.AsraySplit.share`.
4. Register the matching App Group and confirm both targets use it.
5. Select **Any iOS Device (arm64)**, then **Product > Archive**.
6. In Organizer, run **Validate App**, fix every error, then distribute to App Store Connect.

The home-screen name is `AsraySplit` in Debug, Staging, and Release. The single 1024×1024 opaque icon is in the asset catalog and is regenerated with:

```sh
swift scripts/make-app-icon.swift AsraySplit/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

## TestFlight and App Store release

1. Add App Store metadata from `APP_STORE.md`, complete privacy/export-compliance forms, and upload current-device screenshots.
2. Add internal testers first. Verify the production-signed build, not a Debug/demo build.
3. Add external testers after the core flows pass; provide the review account and sample receipt in Beta App Review notes.
4. Submit version 1.0 only after every release gate in `QA_AND_RELEASE.md` is checked.
5. Use Apple's phased release. Watch auth errors, sync backlog, receipt latency/cost, push/email failures, and crashes; pause for unauthorized access, balance errors, data loss, or runaway spend.

## Quick local check

The app runs without a backend in demo mode:

```sh
xcodegen generate
xcodebuild test -project AsraySplit.xcodeproj -scheme AsraySplit \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

For a final production check, also run the database and Edge Function suites shown in `README.md`, then complete the signed-device matrix in `QA_AND_RELEASE.md`.
