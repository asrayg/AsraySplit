# Operations runbook

## Environments

| | Bundle ID | Supabase project | Config |
| --- | --- | --- | --- |
| Debug | com.asray.AsraySplit.debug | local (`supabase start`) or none (demo) | `Config/Secrets.Debug.xcconfig` |
| Staging | com.asray.AsraySplit.staging | staging | `Config/Secrets.Staging.xcconfig` |
| Release | com.asray.AsraySplit | production | `Config/Secrets.Release.xcconfig` |

Only `SUPABASE_HOST` and the **publishable** key go in xcconfigs. Never the service-role key or AI keys.

## Deploying the backend

```sh
supabase link --project-ref <ref>
supabase db push                    # applies supabase/migrations in order
supabase functions deploy scan-receipt exchange-rates delete-account maintenance
supabase secrets set OPENAI_API_KEY=... RECEIPT_MODEL=gpt-4.1-mini \
  APNS_TEAM_ID=... APNS_KEY_ID=... APNS_PRIVATE_KEY="$(cat AuthKey.p8)" \
  APPLE_TEAM_ID=... APPLE_KEY_ID=... APPLE_CLIENT_ID=com.asray.AsraySplit APPLE_PRIVATE_KEY="$(cat SIWA.p8)"
```

One-time Vault setup so pg_cron can call the `maintenance` function (run in the SQL editor of each project;
these are secrets, so they are deliberately not in migrations):

```sql
select vault.create_secret('https://<ref>.supabase.co', 'project_url');
select vault.create_secret('<service-role-key>', 'service_role_key');
```

Auth settings live in `supabase/config.toml` (`supabase config push`): Apple provider, redirect
`asraysplit://auth-callback`, anonymous sign-ins disabled, rate limits. Configure custom SMTP before launch.

Host `web/` at the invite domain (`INVITE_HOST`, default `asraysplit.app`), replacing `TEAMID` in
`web/.well-known/apple-app-site-association` and serving it as `application/json` without redirects.

## Limits (tunable without deploys)

`private.app_limits`: `receipt_scans_per_day` (25), `receipt_scans_per_month` (300),
`receipt_scans_global_per_day` (20000 — the AI spend circuit breaker). Lower the global value to 0 to
pause AI scanning instantly; the app falls back to on-device OCR.

## Monitoring

- Edge Function logs are structured JSON (`event` field) and redacted; they never contain receipt
  contents, amounts, merchants, emails or tokens.
- Watch: `ai_usage` outcomes/latency, `push_jobs` with status `failed`, `private.storage_cleanup_queue`
  rows with `attempts >= 10`, auth error rates, RPC 5xx.
- Pause the phased release on balance inconsistencies (client logs "Local projection differs from server
  balances"), unauthorized access, data loss, crash regressions, or runaway AI usage.

## Incident playbooks

- **Runaway AI cost:** `update private.app_limits set value = 0 where key = 'receipt_scans_global_per_day';`
- **Push storm:** `update public.push_jobs set status = 'skipped' where status in ('pending','failed');`
- **Bad migration:** migrations are forward-only; ship a forward-repair migration. Restore from PITR backup
  for data loss.
- **Leaked publishable key:** rotate in the dashboard and ship a config update; RLS limits exposure.
- **Leaked service-role key:** rotate immediately, redeploy functions, audit `auth.audit_log_entries`.
