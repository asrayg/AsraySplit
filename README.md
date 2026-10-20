# Asray Split

A native SwiftUI expense-sharing app with receipt photos, AI itemization, per-item assignment, proportional tax/tip splitting, groups, balances, insights, and local-first persistence.

> **Status:** compiling product prototype, not an App Store-ready release. Start with [CLAUDE.md](CLAUDE.md) and the [implementation plan](docs/IMPLEMENTATION_PLAN.md) before extending it.

### Vacation features

- Create trips with dates, travelers, home currency, and a shared budget
- Add ordinary numeric expenses or scan/itemize a receipt
- Split equally, by exact amount, percentage, or weighted shares
- Record who paid and whether it was cash, card, bank, Venmo, or another method
- Built-in and custom expense tags, including an automatic `cash` tag
- Per-person allocation breakdowns and balance-aware settlement records
- Daily opt-in trip reminders and expense confirmation notifications
- Expense history, detail screens, and deletion

## Run the iOS app

```sh
xcodegen generate
open AsraySplit.xcodeproj
```

The app runs immediately in demo mode. Camera capture works on a device; the simulator can use the photo library or built-in demo receipt.

## Connect Supabase

1. Create a Supabase project and enable anonymous sign-ins under Auth.
2. Run `supabase/migrations/001_initial.sql` in the SQL editor (or link the CLI and run `supabase db push`).
3. Add the project URL and publishable key to `AsraySplit/Info.plist`. Never add a secret/service-role key to the app.
4. Set the server-only AI key and deploy:

```sh
supabase secrets set OPENAI_API_KEY=your_key
supabase functions deploy scan-receipt
```

The receipt bucket is private and protected by owner-scoped RLS. The Edge Function validates the caller JWT and keeps AI credentials server-side.

## Architecture

- SwiftUI + Observation via `ObservableObject`
- Vision text recognition as the private on-device fallback
- Supabase Auth, Postgres, Storage, and Edge Functions
- JSON local snapshot for offline/demo behavior
- Structured AI output; the user must review before saving

