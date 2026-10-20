# App Store submission package (draft)

## Metadata

- **Name:** Asray Split · **Subtitle:** Split trip costs, receipt by receipt
- **Category:** Finance (secondary: Travel) · **Age rating:** 4+ (no objectionable content; no gambling; no UGC sharing beyond invited trip members)
- **Keywords:** split,expenses,travel,trip,group,receipt,bill,share,costs,settle,friends,vacation
- **Description (first lines):** Split trip costs fairly with friends. Scan a receipt and tap who had what, or add an
  expense in seconds — even offline. Asray Split keeps everyone's balance exact to the cent in any currency and
  shows the fewest payments needed to settle up.
- **Support URL:** https://asraysplit.app/support · **Privacy URL:** https://asraysplit.app/privacy
- **Copyright / SKU / bundle ID:** © 2026 [legal entity] · ASRAYSPLIT1 · com.asray.AsraySplit

## Review notes

- Tap **Explore the demo trip** on the sign-in screen for a fully featured demo (in-memory, nothing uploaded),
  or sign in with the review account: `[review email]` (magic link delivered to a reviewer-accessible inbox —
  set up before submission).
- Receipt scanning: use any receipt photo, or "Choose a photo" with the sample in the review attachment.
  Results are always shown for review before saving; offline/AI-unavailable falls back to on-device text recognition.
- Invites: Trip → gear → Invite people shows a link, QR code and 8-character code.
- **Recording a payment does not move money.** Payment-app buttons only open Venmo/PayPal.
- Account deletion: Settings → Delete account (type DELETE; Sign in with Apple users confirm with Apple so the
  token is revoked).
- Notifications are requested only after creating a first trip or enabling a notification setting.

## App Privacy answers

| Data type | Collected | Linked to user | Tracking | Purpose |
| --- | --- | --- | --- | --- |
| Email address | Yes | Yes | No | App functionality (sign-in) |
| Name | Yes | Yes | No | App functionality (display name) |
| Photos | Yes (receipts the user uploads) | Yes | No | App functionality |
| Other financial info (expenses) | Yes | Yes | No | App functionality |
| User ID | Yes | Yes | No | App functionality |
| Device ID (push token) | Yes | Yes | No | App functionality |
| Usage/diagnostics | No | — | — | — |

Matches `AsraySplit/Resources/PrivacyInfo.xcprivacy`. Export compliance: standard HTTPS only
(`ITSAppUsesNonExemptEncryption = NO`).

## Before submitting (blocking)

- [ ] Production Supabase project, Vault secrets, custom SMTP, APNs + SIWA keys (docs/OPERATIONS.md)
- [ ] Apple Team ID in `web/.well-known/apple-app-site-association`; host `web/` at the invite domain
- [ ] Support email + legal review of privacy policy and terms; replace placeholders in `web/`
- [ ] Signed Release archive validated in Xcode Organizer; TestFlight internal → external
- [ ] Screenshots: run `ScreenshotTests` with `TEST_RUNNER_SCREENSHOT_DIR` set on 6.7" and 6.1" simulators
- [ ] Physical-device pass of QA_AND_RELEASE.md (two devices, offline, push, SIWA, account deletion)
