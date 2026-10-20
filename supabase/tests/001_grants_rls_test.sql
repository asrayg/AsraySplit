begin;
\ir helpers/test_helpers.psql
select plan(9);

-- Every table in exposed schemas has RLS enabled.
select is(
  (select coalesce(array_agg(tablename::text order by tablename), '{}') from pg_tables where schemaname = 'public' and not rowsecurity),
  '{}'::text[], 'every public table has row level security enabled');

-- anon can read nothing except currency reference data.
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'currencies'
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
       or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'))),
  '{}'::text[], 'anon has no table privileges beyond currencies');

-- Authenticated users cannot write ledger/membership tables directly; RPCs are the only writers.
select is(
  (select coalesce(array_agg(c.relname::text order by c.relname), '{}') from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
     and c.relname in ('trips','trip_members','trip_participants','trip_invites','expenses','expense_payments','expense_allocations',
                       'expense_items','expense_item_assignees','expense_tags','settlements','receipts','activity_events','push_jobs',
                       'ai_usage','exchange_rates','currencies')
     and (has_table_privilege('authenticated', c.oid, 'insert') or has_table_privilege('authenticated', c.oid, 'update')
       or has_table_privilege('authenticated', c.oid, 'delete') or has_table_privilege('authenticated', c.oid, 'truncate'))),
  '{}'::text[], 'authenticated cannot insert/update/delete ledger tables directly');

select ok(not has_column_privilege('authenticated', 'public.expenses', 'request_hash', 'select'), 'idempotency hashes are not readable');
select ok(not has_column_privilege('authenticated', 'public.trip_invites', 'token_hash', 'select'), 'invite token hashes are not readable');

-- anon cannot execute any public function.
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')),
  '{}'::text[], 'anon cannot execute public functions');

-- Service-only functions are not callable by signed-in users.
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname in ('complete_receipt_scan','claim_push_jobs','finish_push_job','claim_storage_cleanup',
                                                 'finish_storage_cleanup','purge_expired_records')
     and has_function_privilege('authenticated', p.oid, 'execute')),
  '{}'::text[], 'service-only functions are not executable by authenticated');

-- Every security definer function pins search_path.
select is(
  (select coalesce(array_agg(n.nspname || '.' || p.proname order by p.proname), '{}') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')),
  '{}'::text[], 'security definer functions set an explicit search_path');

-- Private helpers are not executable by default.
select ok(not has_function_privilege('authenticated', 'private.log_activity(uuid, text, uuid, jsonb)', 'execute'),
  'private helpers are not executable by API roles');

select * from finish();
rollback;
