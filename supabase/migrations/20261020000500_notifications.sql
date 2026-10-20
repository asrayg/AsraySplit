-- Device registration, notification preferences, and a durable, de-duplicated push queue.

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  apns_token text not null unique check (apns_token ~ '^[0-9a-f]{64,200}$'),
  environment text not null check (environment in ('sandbox', 'production')),
  bundle_id text not null,
  app_version text,
  locale text,
  timezone text,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index devices_user_idx on public.devices(user_id);

create table public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  push_enabled boolean not null default true,
  expense_changes boolean not null default true,
  settlements boolean not null default true,
  membership boolean not null default true,
  receipt_scans boolean not null default true,
  daily_reminder boolean not null default false,
  show_details_on_lock_screen boolean not null default false,
  quiet_hours_start time,
  quiet_hours_end time,
  timezone text not null default 'UTC',
  updated_at timestamptz not null default now()
);

create table public.trip_notification_settings (
  user_id uuid not null references auth.users(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  muted boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (user_id, trip_id)
);
create index trip_notification_settings_trip_idx on public.trip_notification_settings(trip_id);

create table public.push_jobs (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  trip_id uuid references public.trips(id) on delete cascade,
  activity_id bigint references public.activity_events(id) on delete cascade,
  kind text not null,
  -- Privacy-safe payload: identifiers + generic text. Details are added only when the user opted in.
  payload jsonb not null,
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index push_jobs_due_idx on public.push_jobs(next_attempt_at) where status in ('pending', 'failed');
create index push_jobs_user_idx on public.push_jobs(user_id);
create index push_jobs_activity_idx on public.push_jobs(activity_id);

create trigger notification_preferences_touch before update on public.notification_preferences
  for each row execute function private.touch_updated_at();
create trigger trip_notification_settings_touch before update on public.trip_notification_settings
  for each row execute function private.touch_updated_at();

alter table public.devices enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.trip_notification_settings enable row level security;
alter table public.push_jobs enable row level security;

revoke all on public.devices, public.notification_preferences, public.trip_notification_settings, public.push_jobs from anon, authenticated;
grant select, delete on public.devices to authenticated;
grant select, insert, update on public.notification_preferences to authenticated;
grant select, insert, update, delete on public.trip_notification_settings to authenticated;

create policy "own devices read" on public.devices for select to authenticated using (user_id = (select auth.uid()));
create policy "own devices delete" on public.devices for delete to authenticated using (user_id = (select auth.uid()));
create policy "own prefs read" on public.notification_preferences for select to authenticated using (user_id = (select auth.uid()));
create policy "own prefs insert" on public.notification_preferences for insert to authenticated with check (user_id = (select auth.uid()));
create policy "own prefs update" on public.notification_preferences for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own trip settings read" on public.trip_notification_settings for select to authenticated using (user_id = (select auth.uid()));
create policy "own trip settings write" on public.trip_notification_settings for insert to authenticated
  with check (user_id = (select auth.uid()) and (select private.is_trip_member(trip_id)));
create policy "own trip settings update" on public.trip_notification_settings for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()) and (select private.is_trip_member(trip_id)));
create policy "own trip settings delete" on public.trip_notification_settings for delete to authenticated using (user_id = (select auth.uid()));

-- Registers (or moves) an APNs token to the calling user.
create or replace function public.register_device(p_token text, p_environment text, p_bundle_id text,
  p_app_version text default null, p_locale text default null, p_timezone text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_user();
begin
  insert into public.devices (user_id, apns_token, environment, bundle_id, app_version, locale, timezone)
  values (v_uid, lower(p_token), p_environment, p_bundle_id, p_app_version, p_locale, p_timezone)
  on conflict (apns_token) do update set user_id = v_uid, environment = excluded.environment, bundle_id = excluded.bundle_id,
    app_version = excluded.app_version, locale = excluded.locale, timezone = excluded.timezone, last_seen_at = now();
  insert into public.notification_preferences (user_id, timezone) values (v_uid, coalesce(p_timezone, 'UTC'))
  on conflict (user_id) do nothing;
end $$;

create or replace function public.unregister_device(p_token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.devices where apns_token = lower(p_token) and user_id = auth.uid()
$$;

revoke all on function public.register_device(text, text, text, text, text, text), public.unregister_device(text) from public, anon;
grant execute on function public.register_device(text, text, text, text, text, text), public.unregister_device(text) to authenticated;

-- Fan out each activity event to the other active members who want it. dedupe_key makes replays harmless.
create or replace function private.enqueue_push_jobs() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_category text;
begin
  v_category := case
    when new.kind like 'expense_%' then 'expense_changes'
    when new.kind like 'settlement_%' then 'settlements'
    when new.kind in ('member_joined', 'member_left', 'member_removed') then 'membership'
    when new.kind like 'receipt_%' then 'receipt_scans'
    else null end;
  if v_category is null then return new; end if;

  insert into public.push_jobs (user_id, trip_id, activity_id, kind, payload, dedupe_key)
  select m.user_id, new.trip_id, new.id, new.kind,
         jsonb_build_object('trip_id', new.trip_id, 'entity_id', new.entity_id, 'kind', new.kind, 'activity_id', new.id),
         'activity:' || new.id || ':' || m.user_id
  from public.trip_members m
  left join public.notification_preferences np on np.user_id = m.user_id
  left join public.trip_notification_settings ts on ts.user_id = m.user_id and ts.trip_id = new.trip_id
  where m.trip_id = new.trip_id and m.status = 'active'
    -- Scan results go to the requester; everything else to everyone except the actor.
    and ((new.kind like 'receipt_%' and m.user_id = new.actor_id) or (new.kind not like 'receipt_%' and m.user_id is distinct from new.actor_id))
    and coalesce(np.push_enabled, true)
    and coalesce(ts.muted, false) = false
    and case v_category
          when 'expense_changes' then coalesce(np.expense_changes, true)
          when 'settlements' then coalesce(np.settlements, true)
          when 'membership' then coalesce(np.membership, true)
          when 'receipt_scans' then coalesce(np.receipt_scans, true)
        end
    and exists (select 1 from public.devices d where d.user_id = m.user_id)
  on conflict (dedupe_key) do nothing;
  return new;
end $$;

create trigger activity_enqueue_push after insert on public.activity_events
  for each row execute function private.enqueue_push_jobs();

-- Service role: claim due jobs for the dispatcher with SKIP LOCKED so parallel workers never double-send.
create or replace function public.claim_push_jobs(p_limit integer default 100) returns setof public.push_jobs
language sql security definer set search_path = '' as $$
  update public.push_jobs j set status = 'sending', attempts = j.attempts + 1
  where j.id in (
    select id from public.push_jobs
    where status in ('pending', 'failed') and next_attempt_at <= now() and attempts < 6
    order by next_attempt_at
    limit p_limit
    for update skip locked)
  returning j.*
$$;

create or replace function public.finish_push_job(p_job_id bigint, p_status text, p_error text default null) returns void
language sql security definer set search_path = '' as $$
  update public.push_jobs set
    status = p_status,
    last_error = p_error,
    sent_at = case when p_status = 'sent' then now() else sent_at end,
    -- Exponential backoff: 30s, 2m, 8m, 32m, ~2h.
    next_attempt_at = case when p_status = 'failed' then now() + make_interval(secs => 30 * power(4, least(attempts - 1, 4))) else next_attempt_at end
  where id = p_job_id
$$;

revoke all on function public.claim_push_jobs(integer), public.finish_push_job(bigint, text, text) from public, anon, authenticated;
grant execute on function public.claim_push_jobs(integer), public.finish_push_job(bigint, text, text) to service_role;
