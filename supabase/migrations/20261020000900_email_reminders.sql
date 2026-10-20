-- Email reminders sent through Resend: automatic settle-up reminders after a trip ends, and
-- "remind" requests from the person who is owed. Jobs are queued here and delivered by the
-- `maintenance` Edge Function with an idempotency key, so retries never send twice.

alter table public.notification_preferences
  add column if not exists email_reminders boolean not null default true;

create table public.email_jobs (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  trip_id uuid references public.trips(id) on delete cascade,
  kind text not null check (kind in ('settle_up_reminder', 'payment_request')),
  -- Rendering data captured at enqueue time: trip name, amounts, who to pay. Only the recipient's own debts.
  data jsonb not null,
  dedupe_key text not null unique,
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts integer not null default 0,
  next_attempt_at timestamptz not null default now(),
  last_error text,
  provider_message_id text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index email_jobs_due_idx on public.email_jobs(next_attempt_at) where status in ('pending', 'failed');
create index email_jobs_user_trip_idx on public.email_jobs(user_id, trip_id, created_at);

alter table public.email_jobs enable row level security;
revoke all on public.email_jobs from anon, authenticated;

-- What `user_id` owes in `trip_id`, as recipients + amounts from the simplified settlement plan.
create or replace function private.debt_summary(p_trip_id uuid, p_user_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_participant uuid;
  v_result jsonb;
begin
  select participant_id into v_participant from public.trip_members where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if v_participant is null then return null; end if;
  select jsonb_build_object(
      'trip_id', t.id, 'trip_name', t.name, 'trip_emoji', t.emoji, 'currency', t.base_currency,
      'amount_minor', coalesce(sum(s.amount_minor), 0),
      'pay_to', coalesce(jsonb_agg(jsonb_build_object('name', p.display_name, 'amount_minor', s.amount_minor) order by s.amount_minor desc)
                         filter (where s.from_participant_id is not null), '[]'::jsonb))
    into v_result
  from public.trips t
  left join public.suggested_settlements(p_trip_id) s on s.from_participant_id = v_participant
  left join public.trip_participants p on p.id = s.to_participant_id
  where t.id = p_trip_id
  group by t.id;
  return v_result;
end $$;
revoke all on function private.debt_summary(uuid, uuid) from public;

-- "Remind" button: the person who is owed (or a trip admin) nudges a member who owes money.
-- At most one request per debtor per trip per day; returns {queued, reason}.
create or replace function public.request_payment_reminder(p_trip_id uuid, p_debtor_participant_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_role text;
  v_my_participant uuid;
  v_debtor_user uuid;
  v_owed_to_me bigint;
  v_summary jsonb;
  v_inserted integer;
begin
  v_role := private.require_role(p_trip_id, 'member');
  select participant_id into v_my_participant from public.trip_members where trip_id = p_trip_id and user_id = v_uid;
  select m.user_id into v_debtor_user from public.trip_members m where m.trip_id = p_trip_id and m.participant_id = p_debtor_participant_id and m.status = 'active';
  if v_debtor_user is null then return jsonb_build_object('queued', false, 'reason', 'no_account'); end if;
  if v_debtor_user = v_uid then perform private.fail('invalid_parties', 'You can’t remind yourself.'); end if;

  select coalesce(sum(s.amount_minor), 0) into v_owed_to_me from public.suggested_settlements(p_trip_id) s
  where s.from_participant_id = p_debtor_participant_id and s.to_participant_id = v_my_participant;
  if v_owed_to_me = 0 and v_role not in ('owner', 'admin') then
    perform private.fail('nothing_owed', 'This person doesn’t owe you anything.', 'PT409');
  end if;

  v_summary := private.debt_summary(p_trip_id, v_debtor_user);
  if coalesce((v_summary ->> 'amount_minor')::bigint, 0) = 0 then return jsonb_build_object('queued', false, 'reason', 'settled'); end if;
  if exists (select 1 from public.notification_preferences where user_id = v_debtor_user and not email_reminders) then
    return jsonb_build_object('queued', false, 'reason', 'opted_out');
  end if;

  insert into public.email_jobs (user_id, trip_id, kind, data, dedupe_key, created_by)
  values (v_debtor_user, p_trip_id, 'payment_request',
          v_summary || jsonb_build_object('requested_by', (select display_name from public.profiles where id = v_uid)),
          'request:' || p_trip_id || ':' || v_debtor_user || ':' || to_char(now() at time zone 'utc', 'YYYY-MM-DD'), v_uid)
  on conflict (dedupe_key) do nothing;
  get diagnostics v_inserted = row_count;
  return jsonb_build_object('queued', v_inserted > 0, 'reason', case when v_inserted > 0 then null else 'already_reminded_today' end);
end $$;

-- Daily (pg_cron): members who still owe money in a trip that ended at least a day ago get a reminder
-- every 3 days, at most 3 times per trip.
create or replace function public.enqueue_settle_up_reminders() returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_row record;
  v_summary jsonb;
  v_count integer := 0;
begin
  for v_row in
    select m.trip_id, m.user_id
    from public.trip_members m
    join public.trips t on t.id = m.trip_id
    left join public.notification_preferences np on np.user_id = m.user_id
    where m.status = 'active'
      and coalesce(np.email_reminders, true)
      and t.end_date is not null and t.end_date < (now() at time zone t.timezone)::date - 1
      and (select count(*) from public.email_jobs j where j.user_id = m.user_id and j.trip_id = m.trip_id and j.kind = 'settle_up_reminder') < 3
      and not exists (select 1 from public.email_jobs j where j.user_id = m.user_id and j.trip_id = m.trip_id
                      and j.kind = 'settle_up_reminder' and j.created_at > now() - interval '3 days')
      and exists (select 1 from public.trip_balances(m.trip_id) b where b.participant_id = m.participant_id and b.net_minor < 0)
  loop
    v_summary := private.debt_summary(v_row.trip_id, v_row.user_id);
    if coalesce((v_summary ->> 'amount_minor')::bigint, 0) > 0 then
      insert into public.email_jobs (user_id, trip_id, kind, data, dedupe_key)
      values (v_row.user_id, v_row.trip_id, 'settle_up_reminder', v_summary,
              'settle:' || v_row.trip_id || ':' || v_row.user_id || ':' || to_char(now() at time zone 'utc', 'YYYY-MM-DD'))
      on conflict (dedupe_key) do nothing;
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

create or replace function public.claim_email_jobs(p_limit integer default 50) returns setof public.email_jobs
language sql security definer set search_path = '' as $$
  update public.email_jobs j set status = 'sending', attempts = j.attempts + 1
  where j.id in (
    select id from public.email_jobs
    where status in ('pending', 'failed') and next_attempt_at <= now() and attempts < 5
    order by next_attempt_at limit p_limit for update skip locked)
  returning j.*
$$;

create or replace function public.finish_email_job(p_job_id bigint, p_status text, p_error text default null, p_provider_id text default null) returns void
language sql security definer set search_path = '' as $$
  update public.email_jobs set
    status = p_status, last_error = p_error, provider_message_id = coalesce(p_provider_id, provider_message_id),
    sent_at = case when p_status = 'sent' then now() else sent_at end,
    next_attempt_at = case when p_status = 'failed' then now() + make_interval(secs => 60 * power(4, least(attempts - 1, 4))) else next_attempt_at end
  where id = p_job_id
$$;

-- One-click unsubscribe from reminder emails (called by the `email-unsubscribe` function after it
-- verifies the signed link).
create or replace function public.disable_email_reminders(p_user_id uuid) returns void
language sql security definer set search_path = '' as $$
  insert into public.notification_preferences (user_id, email_reminders) values (p_user_id, false)
  on conflict (user_id) do update set email_reminders = false
$$;

revoke all on function public.request_payment_reminder(uuid, uuid), public.enqueue_settle_up_reminders(),
  public.claim_email_jobs(integer), public.finish_email_job(bigint, text, text, text), public.disable_email_reminders(uuid)
  from public, anon, authenticated;
grant execute on function public.request_payment_reminder(uuid, uuid) to authenticated;
grant execute on function public.enqueue_settle_up_reminders(), public.claim_email_jobs(integer),
  public.finish_email_job(bigint, text, text, text), public.disable_email_reminders(uuid) to service_role;

-- Retention: drop delivered email jobs after 90 days (part of the daily purge).
create or replace function private.purge_email_jobs() returns integer
language sql security definer set search_path = '' as $$
  with deleted as (delete from public.email_jobs where status in ('sent', 'skipped') and created_at < now() - interval '90 days' returning 1)
  select count(*)::integer from deleted
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('settle-up-reminders', '0 17 * * *', 'select public.enqueue_settle_up_reminders(); select private.purge_email_jobs();');
  end if;
end $$;
