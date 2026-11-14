-- Crew build: readable push notifications (chat, splits, payments, photos), Asray-only announcements, and
-- opt-in location sharing between the four of us.
--
-- Push jobs may now carry {title, body} in their payload; the dispatcher uses them as the alert text.

-- ---------------------------------------------------------------------------
-- Announcements: a chat message flagged by Asray that notifies everyone.
-- ---------------------------------------------------------------------------
alter table public.trip_messages add column is_announcement boolean not null default false;

create or replace function private.is_crew_lead(p_trip_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trip_participants p
    where p.trip_id = p_trip_id and p.user_id = auth.uid() and p.id = 'c0ffee00-2026-4000-8000-000000000001'
  )
$$;

drop function public.post_trip_message(uuid, uuid, text, timestamptz);
create or replace function public.post_trip_message(p_trip_id uuid, p_id uuid, p_body text, p_sent_at timestamptz default null,
  p_announce boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_row public.trip_messages;
begin
  perform private.require_role(p_trip_id, 'member');
  if p_id is null then perform private.fail('invalid_message', 'Message id is required.'); end if;
  if p_body is null or char_length(btrim(p_body)) = 0 or char_length(p_body) > 2000 then
    perform private.fail('invalid_message', 'Messages must be 1–2000 characters.');
  end if;
  if coalesce(p_announce, false) and not private.is_crew_lead(p_trip_id) then
    perform private.fail('announcements_restricted', 'Only Asray can send announcements.', '42501');
  end if;

  select * into v_row from public.trip_messages where id = p_id;
  if found then
    if v_row.trip_id <> p_trip_id or v_row.sender_id is distinct from auth.uid() then
      perform private.fail('message_id_conflict', 'That message id is already used.', 'P0001');
    end if;
    return to_jsonb(v_row);
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();

  insert into public.trip_messages (id, trip_id, sender_id, sender_name, body, sent_at, is_announcement)
  values (p_id, p_trip_id, auth.uid(), coalesce(v_name, 'Someone'), btrim(p_body), least(coalesce(p_sent_at, now()), now()),
          coalesce(p_announce, false))
  returning * into v_row;
  return to_jsonb(v_row);
end $$;
revoke all on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean) from public, anon;
grant execute on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Push fan-out helper: one job per other active member with a registered device.
-- ---------------------------------------------------------------------------
create or replace function private.push_to_trip(p_trip_id uuid, p_actor uuid, p_kind text, p_title text, p_body text,
  p_entity uuid, p_dedupe text)
returns void language sql security definer set search_path = '' as $$
  insert into public.push_jobs (user_id, trip_id, kind, payload, dedupe_key)
  select m.user_id, p_trip_id, p_kind,
         jsonb_build_object('trip_id', p_trip_id, 'entity_id', p_entity, 'kind', p_kind,
                            'title', left(p_title, 80), 'body', left(p_body, 180)),
         p_dedupe || ':' || m.user_id
  from public.trip_members m
  left join public.notification_preferences np on np.user_id = m.user_id
  left join public.trip_notification_settings ts on ts.user_id = m.user_id and ts.trip_id = p_trip_id
  where m.trip_id = p_trip_id and m.status = 'active' and m.user_id is distinct from p_actor
    and coalesce(np.push_enabled, true)
    and coalesce(ts.muted, false) = false
    and exists (select 1 from public.devices d where d.user_id = m.user_id)
  on conflict (dedupe_key) do nothing
$$;

create or replace function private.push_chat_message() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.push_to_trip(new.trip_id, new.sender_id,
    case when new.is_announcement then 'announcement' else 'chat_message' end,
    case when new.is_announcement then '📣 ' || new.sender_name else new.sender_name end,
    new.body, new.id, 'chat:' || new.id);
  return new;
end $$;
create trigger trip_messages_push after insert on public.trip_messages
  for each row execute function private.push_chat_message();

-- Photo dumps: at most one notification per uploader per 15 minutes.
create or replace function private.push_photo_added() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.push_to_trip(new.trip_id, new.uploader_id, 'photos_added', 'Trip photos',
    new.uploader_name || ' added photos to the album', new.id,
    'photos:' || new.trip_id || ':' || coalesce(new.uploader_id::text, '-') || ':' || floor(extract(epoch from new.created_at) / 900)::bigint);
  return new;
end $$;
create trigger trip_photos_push after insert on public.trip_photos
  for each row execute function private.push_photo_added();

-- Readable text for split/payment activity (the generic activity trigger stays for everything else).
create or replace function private.enqueue_push_jobs() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_actor text;
  v_title text;
  v_body text;
  v_expense record;
  v_settlement record;
begin
  if not (new.kind like 'expense_%' or new.kind like 'settlement_%') then return new; end if;
  select coalesce(p.display_name, 'Someone') into v_actor
  from public.trip_participants p where p.trip_id = new.trip_id and p.user_id = new.actor_id;
  v_actor := coalesce(v_actor, 'Someone');

  if new.kind like 'expense_%' then
    select e.description, e.original_minor as amount_minor, e.original_currency as currency into v_expense from public.expenses e where e.id = new.entity_id;
    v_title := 'New split';
    v_body := v_actor || case new.kind
        when 'expense_created' then ' added '
        when 'expense_updated' then ' edited '
        when 'expense_deleted' then ' removed '
        else ' restored ' end
      || coalesce(v_expense.description, 'an expense')
      || coalesce(' · ' || case when v_expense.currency = 'USD' then '$' else v_expense.currency || ' ' end
                  || to_char(v_expense.amount_minor / 100.0, 'FM999,999,990.00'), '');
    if new.kind <> 'expense_created' then v_title := 'Split updated'; end if;
  else
    select s.amount_minor, s.currency, pf.display_name as from_name, pt.display_name as to_name into v_settlement
    from public.settlements s
    left join public.trip_participants pf on pf.id = s.from_participant_id
    left join public.trip_participants pt on pt.id = s.to_participant_id
    where s.id = new.entity_id;
    v_title := 'Payment';
    v_body := case when new.kind = 'settlement_deleted' then v_actor || ' removed a payment'
      else coalesce(v_settlement.from_name, 'Someone') || ' paid ' || coalesce(v_settlement.to_name, 'someone')
           || coalesce(' $' || to_char(v_settlement.amount_minor / 100.0, 'FM999,999,990.00'), '') end;
  end if;

  perform private.push_to_trip(new.trip_id, new.actor_id, new.kind, v_title, v_body, new.entity_id, 'activity:' || new.id);
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Location sharing: latest position per member, visible to the trip. Opt-in from the app.
-- ---------------------------------------------------------------------------
create table public.member_locations (
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m double precision check (accuracy_m is null or accuracy_m between 0 and 100000),
  recorded_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (trip_id, user_id)
);
create index member_locations_user_idx on public.member_locations(user_id);

alter table public.member_locations enable row level security;
revoke all on public.member_locations from public, anon, authenticated;
grant select on public.member_locations to authenticated;
create policy member_locations_member_read on public.member_locations
  for select to authenticated using (private.is_trip_member(trip_id));

create or replace function public.update_my_location(p_trip_id uuid, p_latitude double precision, p_longitude double precision,
  p_accuracy double precision default null, p_recorded_at timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  perform private.require_role(p_trip_id, 'member');
  if p_latitude is null or p_longitude is null or p_latitude not between -90 and 90 or p_longitude not between -180 and 180 then
    perform private.fail('invalid_location', 'Location is out of range.');
  end if;
  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();
  insert into public.member_locations (trip_id, user_id, display_name, latitude, longitude, accuracy_m, recorded_at)
  values (p_trip_id, auth.uid(), coalesce(v_name, 'Someone'), p_latitude, p_longitude, least(greatest(p_accuracy, 0), 100000),
          least(coalesce(p_recorded_at, now()), now()))
  on conflict (trip_id, user_id) do update
    set display_name = excluded.display_name, latitude = excluded.latitude, longitude = excluded.longitude,
        accuracy_m = excluded.accuracy_m, recorded_at = excluded.recorded_at, updated_at = now()
    -- Offline queues can deliver out of order; never replace a newer fix with an older one.
    where public.member_locations.recorded_at <= excluded.recorded_at;
end $$;

create or replace function public.stop_sharing_location(p_trip_id uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.member_locations where trip_id = p_trip_id and user_id = auth.uid()
$$;

create or replace function public.list_member_locations(p_trip_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member');
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.display_name) from public.member_locations l where l.trip_id = p_trip_id), '[]'::jsonb);
end $$;

revoke all on function public.update_my_location(uuid, double precision, double precision, double precision, timestamptz),
  public.stop_sharing_location(uuid), public.list_member_locations(uuid) from public, anon;
grant execute on function public.update_my_location(uuid, double precision, double precision, double precision, timestamptz),
  public.stop_sharing_location(uuid), public.list_member_locations(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.member_locations;
  end if;
end $$;
