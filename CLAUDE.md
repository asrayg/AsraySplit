# Claude implementation brief

You are finishing **Asray Split**, a native iPhone vacation expense-sharing app. Treat the current repository as a compiling prototype, not as production-ready software.

Read these documents before changing code, in this order:

1. `docs/PRODUCT_SPEC.md`
2. `docs/CURRENT_STATE.md`
3. `docs/ARCHITECTURE.md`
4. `docs/IMPLEMENTATION_PLAN.md`
5. `docs/QA_AND_RELEASE.md`

## Non-negotiable working rules

- Preserve a native SwiftUI experience and iOS 17 minimum deployment target.
- Supabase is the system of record for shared data. Local storage is an offline cache, never a second source of truth.
- Monetary values must never use `Double` in production domain logic. Use integer minor units (`Int64`) plus ISO currency code, or PostgreSQL `numeric` with a lossless Swift conversion.
- Balance calculations must be deterministic and server-authoritative. Never update a stored group balance incrementally from a client.
- All schema changes are versioned migrations. Never make production-only Dashboard edits.
- Every exposed table must have explicit grants, RLS, indexes, and allow/deny tests.
- Secret/service-role keys and AI provider keys never enter the app bundle.
- AI output is untrusted input. Validate it, show it for review, and preserve the original receipt.
- Do not claim a feature is finished until its acceptance criteria and relevant tests pass.
- Avoid giant views and singleton networking state. Use feature modules, protocols, dependency injection, and testable reducers/view models.
- Run `xcodegen generate` after project changes. Keep `project.yml` authoritative.
- Before each handoff, run the build, unit tests, database tests, and any affected UI tests. Record failures honestly.

## Product priorities

1. Correct money and balances
2. Secure collaborative groups
3. Fast offline-friendly expense capture
4. Receipt scanning and item assignment
5. Clear settlement and audit history
6. App Store privacy, reliability, and accessibility
7. Advanced insights and monetization only after the above are stable

## Required final outcome

The release candidate must let two real users on separate devices sign in, join the same trip, work online or briefly offline, create/edit/delete expenses, see identical balances, scan and retain receipts, receive useful notifications, settle debts, export/delete their data, and recover safely from failed or duplicated requests.

