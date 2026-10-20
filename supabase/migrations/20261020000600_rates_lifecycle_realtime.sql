-- Exchange-rate cache, account export/deletion, retention, realtime, and scheduled jobs.

-- ---------------------------------------------------------------------------
-- Exchange rates. Written only by the `exchange-rates` Edge Function (service role).
-- Every expense stores the rate it used, so updates here never change history.
-- ---------------------------------------------------------------------------
create table public.exchange_rates (
  base char(3) not null references public.currencies(code),
  quote char(3) not null references public.currencies(code),
  as_of date not null,
  provider text not null,
  rate numeric(24, 12) not null check (rate > 0),
  fetched_at timestamptz not null default now(),
  primary key (base, quote, as_of, provider)
);
alter table public.exchange_rates enable row level security;
revoke all on public.exchange_rates from anon, authenticated;
grant select on public.exchange_rates to authenticated;
create policy "rates readable by signed-in users" on public.exchange_rates for select to authenticated using (true);

-- ---------------------------------------------------------------------------
-- Data export: everything the caller can see about themselves and their trips.
-- ---------------------------------------------------------------------------
create or replace function public.export_my_data() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'notification_preferences', (select to_jsonb(n) from public.notification_preferences n where n.user_id = auth.uid()),
    'devices', coalesce((select jsonb_agg(jsonb_build_object('environment', d.environment, 'app_version', d.app_version, 'created_at', d.created_at, 'last_seen_at', d.last_seen_at))
                         from public.devices d where d.user_id = auth.uid()), '[]'::jsonb),
    'trips', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trip', to_jsonb(t),
        'participants', (select jsonb_agg(to_jsonb(p) order by p.created_at) from public.trip_participants p where p.trip_id = t.id),
        'expenses', coalesce((select jsonb_agg(public.expense_json(e.id) order by e.spent_at) from public.expenses e where e.trip_id = t.id), '[]'::jsonb),
        'settlements', coalesce((select jsonb_agg(to_jsonb(s) order by s.settled_at) from public.settlements s where s.trip_id = t.id), '[]'::jsonb),
        'balances', (select jsonb_agg(to_jsonb(b)) from public.trip_balances(t.id) b)) order by t.created_at)
      from public.trips t), '[]'::jsonb),
    'ai_usage', coalesce((select jsonb_agg(jsonb_build_object('feature', u.feature, 'outcome', u.outcome, 'created_at', u.created_at))
                          from public.ai_usage u where u.user_id = auth.uid()), '[]'::jsonb))
$$;

-- ---------------------------------------------------------------------------
-- Account deletion, step 1 (called by the `delete-account` Edge Function with the user's JWT).
-- Owned trips with other members are handed to the longest-standing admin/member; solo trips are
-- deleted. The user's participants become "Former traveler" so others' ledgers stay correct, and
-- receipts the user uploaded are deleted. Step 2 (Edge Function, service role) removes storage
-- objects and the auth user, which cascades devices, preferences, profile, memberships and usage.
-- ---------------------------------------------------------------------------
create or replace function public.prepare_account_deletion() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_trip record;
  v_successor uuid;
  v_deleted integer := 0;
  v_transferred integer := 0;
begin
  for v_trip in select m.trip_id from public.trip_members m where m.user_id = v_uid and m.role = 'owner' and m.status = 'active' loop
    select m.user_id into v_successor from public.trip_members m
    where m.trip_id = v_trip.trip_id and m.status = 'active' and m.user_id <> v_uid
    order by (m.role = 'admin') desc, m.joined_at asc limit 1;
    if v_successor is null then
      perform private.queue_trip_storage_cleanup(v_trip.trip_id, 'account_deleted');
      delete from public.trips where id = v_trip.trip_id;
      v_deleted := v_deleted + 1;
    else
      update public.trip_members set role = 'admin' where trip_id = v_trip.trip_id and user_id = v_uid;
      update public.trip_members set role = 'owner' where trip_id = v_trip.trip_id and user_id = v_successor;
      update public.trips set owner_id = v_successor, revision = revision + 1 where id = v_trip.trip_id;
      insert into public.activity_events (trip_id, actor_id, kind, data)
      values (v_trip.trip_id, null, 'ownership_transferred', jsonb_build_object('user_id', v_successor, 'reason', 'account_deleted'));
      v_transferred := v_transferred + 1;
    end if;
  end loop;

  insert into private.storage_cleanup_queue (bucket_id, object_path, reason)
  select 'receipts', r.object_path, 'account_deleted' from public.receipts r where r.uploaded_by = v_uid and r.deleted_at is null;
  update public.receipts set deleted_at = now(), scan_result = null where uploaded_by = v_uid and deleted_at is null;

  update public.trip_members set status = 'left', status_changed_at = now() where user_id = v_uid and status = 'active';
  update public.trip_participants set display_name = 'Former traveler', user_id = null where user_id = v_uid;
  delete from public.devices where user_id = v_uid;
  delete from public.notification_preferences where user_id = v_uid;

  return jsonb_build_object('user_id', v_uid, 'trips_deleted', v_deleted, 'trips_transferred', v_transferred);
end $$;

-- Service role: storage cleanup queue access for the maintenance Edge Function.
create or replace function public.claim_storage_cleanup(p_limit integer default 200)
returns table (id bigint, bucket_id text, object_path text)
language sql security definer set search_path = '' as $$
  update private.storage_cleanup_queue q set attempts = q.attempts + 1
  where q.id in (select c.id from private.storage_cleanup_queue c where c.processed_at is null and c.attempts < 10
                 order by c.created_at limit p_limit for update skip locked)
  returning q.id, q.bucket_id, q.object_path
$$;

create or replace function public.finish_storage_cleanup(p_ids bigint[], p_error text default null) returns void
language sql security definer set search_path = '' as $$
  update private.storage_cleanup_queue set
    processed_at = case when p_error is null then now() else processed_at end,
    last_error = p_error
  where id = any(p_ids)
$$;

-- Retention: invite attempts 7 days, finished push jobs 30 days, processed cleanup rows 30 days.
create or replace function public.purge_expired_records() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_attempts integer; v_jobs integer; v_cleanup integer; v_invites integer;
begin
  delete from private.invite_attempts where attempted_at < now() - interval '7 days';
  get diagnostics v_attempts = row_count;
  delete from public.push_jobs where status in ('sent', 'skipped') and created_at < now() - interval '30 days'
     or status = 'failed' and attempts >= 6 and created_at < now() - interval '30 days';
  get diagnostics v_jobs = row_count;
  delete from private.storage_cleanup_queue where processed_at < now() - interval '30 days';
  get diagnostics v_cleanup = row_count;
  delete from public.trip_invites where (expires_at < now() - interval '30 days') or (revoked_at < now() - interval '30 days');
  get diagnostics v_invites = row_count;
  return jsonb_build_object('invite_attempts', v_attempts, 'push_jobs', v_jobs, 'cleanup_rows', v_cleanup, 'invites', v_invites);
end $$;

revoke all on function public.export_my_data(), public.prepare_account_deletion(), public.claim_storage_cleanup(integer),
  public.finish_storage_cleanup(bigint[], text), public.purge_expired_records() from public, anon, authenticated;
grant execute on function public.export_my_data(), public.prepare_account_deletion() to authenticated;
grant execute on function public.claim_storage_cleanup(integer), public.finish_storage_cleanup(bigint[], text),
  public.purge_expired_records() to service_role;

-- ---------------------------------------------------------------------------
-- Realtime: clients subscribe per trip and refetch canonical aggregates on any change.
-- RLS applies to postgres_changes, so non-members receive nothing.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.trips, public.trip_members, public.trip_participants,
      public.expenses, public.settlements, public.receipts, public.activity_events;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Scheduled jobs (only where pg_cron/pg_net are installed, i.e. hosted Supabase).
-- The service-role key and project URL are read from Vault at run time; they are never stored in
-- migrations. See docs/OPERATIONS.md for the one-time Vault setup.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron')
     and exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_cron;
    create extension if not exists pg_net with schema extensions;
    perform cron.schedule('purge-expired-records', '17 3 * * *', 'select public.purge_expired_records()');
    perform cron.schedule('maintenance-every-minute', '* * * * *', $job$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/maintenance',
        headers := jsonb_build_object('Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'service_role_key')),
        body := '{}'::jsonb, timeout_milliseconds := 25000)
      where exists (select 1 from vault.decrypted_secrets where name = 'service_role_key')
    $job$);
  end if;
end $$;
