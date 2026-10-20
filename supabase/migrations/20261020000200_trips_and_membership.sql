-- Trips, authenticated memberships, named financial participants, and hashed invites.

create table public.trips (
  id uuid primary key,
  owner_id uuid references auth.users(id) on delete set null,
  name text not null check (char_length(btrim(name)) between 1 and 80),
  emoji text not null default '✈️' check (char_length(emoji) <= 8),
  color_hex text not null default '23C58A' check (color_hex ~ '^[0-9A-Fa-f]{6}$'),
  start_date date,
  end_date date,
  timezone text not null default 'UTC',
  base_currency char(3) not null references public.currencies(code),
  budget_minor bigint check (budget_minor is null or budget_minor between 0 and 10000000000000),
  revision integer not null default 1,
  archived_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint trips_dates_ordered check (start_date is null or end_date is null or end_date >= start_date)
);
create index trips_owner_idx on public.trips(owner_id);

create table public.trip_participants (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  user_id uuid references auth.users(id) on delete set null,
  archived_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (trip_id, id)
);
create unique index trip_participants_user_unique on public.trip_participants(trip_id, user_id) where user_id is not null;
create index trip_participants_trip_idx on public.trip_participants(trip_id);
create index trip_participants_user_idx on public.trip_participants(user_id) where user_id is not null;

create table public.trip_members (
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  participant_id uuid not null,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  status text not null default 'active' check (status in ('active', 'left', 'removed')),
  joined_at timestamptz not null default now(),
  status_changed_at timestamptz not null default now(),
  primary key (trip_id, user_id),
  foreign key (trip_id, participant_id) references public.trip_participants(trip_id, id)
);
create index trip_members_user_active_idx on public.trip_members(user_id) where status = 'active';
create unique index trip_members_one_owner on public.trip_members(trip_id) where role = 'owner' and status = 'active';

create table public.trip_invites (
  id uuid primary key default gen_random_uuid(),
  trip_id uuid not null references public.trips(id) on delete cascade,
  created_by uuid references auth.users(id) on delete set null,
  role text not null default 'member' check (role in ('admin', 'member')),
  token_hash bytea not null unique,
  code_hash bytea not null unique,
  participant_id uuid,
  expires_at timestamptz not null,
  max_uses integer not null default 10 check (max_uses between 1 and 100),
  use_count integer not null default 0 check (use_count >= 0),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (trip_id, participant_id) references public.trip_participants(trip_id, id) on delete cascade
);
create index trip_invites_trip_idx on public.trip_invites(trip_id);
create index trip_invites_creator_recent_idx on public.trip_invites(created_by, created_at);

-- Failed/successful invite lookups for brute-force rate limiting. Not exposed.
create table private.invite_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  succeeded boolean not null,
  attempted_at timestamptz not null default now()
);
create index invite_attempts_user_time_idx on private.invite_attempts(user_id, attempted_at);

create trigger trips_touch before update on public.trips for each row execute function private.touch_updated_at();
create trigger trip_participants_touch before update on public.trip_participants for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Membership helpers. security definer so RLS policies can call them without
-- recursing through trip_members' own policies. Empty search_path; no public execute.
-- ---------------------------------------------------------------------------
create or replace function private.is_trip_member(p_trip_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trip_members m
    where m.trip_id = p_trip_id and m.user_id = auth.uid() and m.status = 'active'
  )
$$;

create or replace function private.trip_role(p_trip_id uuid) returns text
language sql stable security definer set search_path = '' as $$
  select m.role from public.trip_members m
  where m.trip_id = p_trip_id and m.user_id = auth.uid() and m.status = 'active'
$$;

create or replace function private.shares_trip_with(p_user_id uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.trip_members mine
    join public.trip_members theirs on theirs.trip_id = mine.trip_id
    where mine.user_id = auth.uid() and mine.status = 'active' and theirs.user_id = p_user_id
  )
$$;

-- Raises unless the caller is an active member with at least p_min_role. Returns the role.
create or replace function private.require_role(p_trip_id uuid, p_min_role text default 'member', p_allow_archived boolean default true)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_role text;
  v_archived timestamptz;
begin
  perform private.require_user();
  select m.role, t.archived_at into v_role, v_archived
  from public.trip_members m join public.trips t on t.id = m.trip_id
  where m.trip_id = p_trip_id and m.user_id = auth.uid() and m.status = 'active';
  if v_role is null then
    perform private.fail('not_trip_member', 'You are not a member of this trip.', '42501');
  end if;
  if p_min_role = 'owner' and v_role <> 'owner' then
    perform private.fail('owner_required', 'Only the trip owner can do this.', '42501');
  elsif p_min_role = 'admin' and v_role not in ('owner', 'admin') then
    perform private.fail('admin_required', 'Only trip owners and admins can do this.', '42501');
  end if;
  if not p_allow_archived and v_archived is not null then
    perform private.fail('trip_archived', 'This trip is archived. Unarchive it to make changes.', 'PT409');
  end if;
  return v_role;
end $$;

revoke all on function private.is_trip_member(uuid), private.trip_role(uuid), private.shares_trip_with(uuid),
  private.require_role(uuid, text, boolean), private.fail(text, text, text), private.require_user() from public;
grant execute on function private.is_trip_member(uuid), private.trip_role(uuid), private.shares_trip_with(uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Activity log (append-only; written by RPCs only)
-- ---------------------------------------------------------------------------
create table public.activity_events (
  id bigint generated always as identity primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  kind text not null check (kind in (
    'trip_created','trip_updated','trip_archived','trip_unarchived',
    'member_joined','member_left','member_removed','member_role_changed','ownership_transferred',
    'participant_added','participant_renamed',
    'expense_created','expense_updated','expense_deleted','expense_restored',
    'settlement_recorded','settlement_deleted',
    'receipt_scanned','receipt_scan_failed')),
  entity_id uuid,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index activity_events_trip_idx on public.activity_events(trip_id, id desc);

create or replace function private.log_activity(p_trip_id uuid, p_kind text, p_entity_id uuid, p_data jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v_id bigint;
begin
  insert into public.activity_events (trip_id, actor_id, kind, entity_id, data)
  values (p_trip_id, auth.uid(), p_kind, p_entity_id, coalesce(p_data, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function private.log_activity(uuid, text, uuid, jsonb) from public;

-- ---------------------------------------------------------------------------
-- RLS and grants
-- ---------------------------------------------------------------------------
alter table public.trips enable row level security;
alter table public.trip_participants enable row level security;
alter table public.trip_members enable row level security;
alter table public.trip_invites enable row level security;
alter table public.activity_events enable row level security;

revoke all on public.trips, public.trip_participants, public.trip_members, public.trip_invites, public.activity_events from anon, authenticated;
grant select on public.trips, public.trip_participants, public.trip_members, public.activity_events to authenticated;
-- Invite rows (even hashes) are visible only to trip admins.
grant select (id, trip_id, created_by, role, participant_id, expires_at, max_uses, use_count, revoked_at, created_at) on public.trip_invites to authenticated;

create policy "members read trips" on public.trips for select to authenticated
  using ((select private.is_trip_member(id)));
create policy "members read participants" on public.trip_participants for select to authenticated
  using ((select private.is_trip_member(trip_id)));
create policy "members read memberships" on public.trip_members for select to authenticated
  using ((select private.is_trip_member(trip_id)) or user_id = (select auth.uid()));
create policy "admins read invites" on public.trip_invites for select to authenticated
  using ((select private.trip_role(trip_id)) in ('owner', 'admin'));
create policy "members read activity" on public.activity_events for select to authenticated
  using ((select private.is_trip_member(trip_id)));

create policy "read own and co-member profiles" on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select private.shares_trip_with(id)));
create policy "update own profile" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Trip RPCs
-- ---------------------------------------------------------------------------
create or replace function private.validate_timezone(p_tz text) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz) then
    perform private.fail('invalid_timezone', 'Choose a valid time zone.');
  end if;
end $$;

create or replace function private.trip_json(p_trip_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(t) || jsonb_build_object(
    'my_role', private.trip_role(t.id),
    'participants', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at, p.id) from public.trip_participants p where p.trip_id = t.id), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(to_jsonb(m) order by m.joined_at) from public.trip_members m where m.trip_id = t.id), '[]'::jsonb))
  from public.trips t where t.id = p_trip_id
$$;
revoke all on function private.trip_json(uuid) from public;

-- Creates a trip owned by the caller, plus the caller's participant and optional guest participants.
-- Idempotent on p_trip_id: replaying returns the existing trip if the caller owns it.
create or replace function public.create_trip(
  p_trip_id uuid,
  p_name text,
  p_base_currency text,
  p_emoji text default '✈️',
  p_color_hex text default '23C58A',
  p_start_date date default null,
  p_end_date date default null,
  p_timezone text default 'UTC',
  p_budget_minor bigint default null,
  p_guest_names text[] default '{}'
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_participant uuid := gen_random_uuid();
  v_name text;
  v_existing uuid;
begin
  select owner_id into v_existing from public.trips where id = p_trip_id;
  if found then
    if v_existing = v_uid then return private.trip_json(p_trip_id); end if;
    perform private.fail('id_conflict', 'This trip ID is already in use.', 'PT409');
  end if;
  if (select count(*) from public.trips where created_by = v_uid and created_at > now() - interval '1 hour') >= 30 then
    perform private.fail('rate_limited', 'You are creating trips too quickly. Try again later.', 'PT429');
  end if;
  perform private.validate_timezone(p_timezone);
  if not exists (select 1 from public.currencies where code = upper(p_base_currency)) then
    perform private.fail('unsupported_currency', 'That currency is not supported.');
  end if;
  if coalesce(array_length(p_guest_names, 1), 0) > 50 then
    perform private.fail('too_many_participants', 'A trip can start with at most 50 guests.');
  end if;

  insert into public.trips (id, owner_id, name, emoji, color_hex, start_date, end_date, timezone, base_currency, budget_minor, created_by)
  values (p_trip_id, v_uid, btrim(p_name), coalesce(p_emoji, '✈️'), coalesce(p_color_hex, '23C58A'), p_start_date, p_end_date,
          p_timezone, upper(p_base_currency), p_budget_minor, v_uid);

  select display_name into v_name from public.profiles where id = v_uid;
  insert into public.trip_participants (id, trip_id, display_name, user_id, created_by)
  values (v_participant, p_trip_id, coalesce(v_name, 'Me'), v_uid, v_uid);
  insert into public.trip_members (trip_id, user_id, participant_id, role) values (p_trip_id, v_uid, v_participant, 'owner');

  insert into public.trip_participants (id, trip_id, display_name, created_by)
  select gen_random_uuid(), p_trip_id, btrim(n), v_uid
  from unnest(coalesce(p_guest_names, '{}')) as n
  where char_length(btrim(n)) > 0;

  perform private.log_activity(p_trip_id, 'trip_created', p_trip_id, jsonb_build_object('name', btrim(p_name)));
  return private.trip_json(p_trip_id);
end $$;

create or replace function public.update_trip(
  p_trip_id uuid,
  p_expected_revision integer,
  p_name text,
  p_emoji text,
  p_color_hex text,
  p_start_date date,
  p_end_date date,
  p_timezone text,
  p_base_currency text,
  p_budget_minor bigint
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_trip public.trips;
begin
  perform private.require_role(p_trip_id, 'admin');
  select * into v_trip from public.trips where id = p_trip_id for update;
  if v_trip.revision <> p_expected_revision then
    perform private.fail('revision_conflict', 'Someone else changed this trip. Review the latest version and try again.', 'PT409');
  end if;
  perform private.validate_timezone(p_timezone);
  if upper(p_base_currency) <> v_trip.base_currency and exists (select 1 from public.expenses where trip_id = p_trip_id)
     then perform private.fail('base_currency_locked', 'The trip currency cannot change after expenses are added.', 'PT409');
  end if;
  update public.trips set
    name = btrim(p_name), emoji = p_emoji, color_hex = p_color_hex, start_date = p_start_date, end_date = p_end_date,
    timezone = p_timezone, base_currency = upper(p_base_currency), budget_minor = p_budget_minor, revision = revision + 1
  where id = p_trip_id;
  perform private.log_activity(p_trip_id, 'trip_updated', p_trip_id, jsonb_build_object('name', btrim(p_name)));
  return private.trip_json(p_trip_id);
end $$;

create or replace function public.set_trip_archived(p_trip_id uuid, p_archived boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'admin');
  update public.trips set archived_at = case when p_archived then coalesce(archived_at, now()) else null end, revision = revision + 1
  where id = p_trip_id;
  perform private.log_activity(p_trip_id, case when p_archived then 'trip_archived' else 'trip_unarchived' end, p_trip_id);
  return private.trip_json(p_trip_id);
end $$;

-- Hard-deletes a trip and all of its financial data. Receipt objects are queued for storage cleanup.
create or replace function public.delete_trip(p_trip_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'owner');
  perform private.queue_trip_storage_cleanup(p_trip_id, 'trip_deleted');
  delete from public.trips where id = p_trip_id;
end $$;

create or replace function public.add_participant(p_trip_id uuid, p_participant_id uuid, p_display_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member', false);
  if exists (select 1 from public.trip_participants where id = p_participant_id) then
    if exists (select 1 from public.trip_participants where id = p_participant_id and trip_id = p_trip_id) then
      return private.trip_json(p_trip_id);
    end if;
    perform private.fail('id_conflict', 'This participant ID is already in use.', 'PT409');
  end if;
  if (select count(*) from public.trip_participants where trip_id = p_trip_id) >= 100 then
    perform private.fail('too_many_participants', 'A trip can have at most 100 people.');
  end if;
  insert into public.trip_participants (id, trip_id, display_name, created_by)
  values (p_participant_id, p_trip_id, btrim(p_display_name), auth.uid());
  perform private.log_activity(p_trip_id, 'participant_added', p_participant_id, jsonb_build_object('name', btrim(p_display_name)));
  return private.trip_json(p_trip_id);
end $$;

create or replace function public.rename_participant(p_participant_id uuid, p_display_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_trip uuid; v_user uuid;
begin
  select trip_id, user_id into v_trip, v_user from public.trip_participants where id = p_participant_id;
  if v_trip is null then perform private.fail('not_found', 'That person no longer exists.', 'PT404'); end if;
  if v_user is not null and v_user <> auth.uid() then
    perform private.require_role(v_trip, 'admin', false);
  else
    perform private.require_role(v_trip, 'member', false);
  end if;
  update public.trip_participants set display_name = btrim(p_display_name) where id = p_participant_id;
  perform private.log_activity(v_trip, 'participant_renamed', p_participant_id, jsonb_build_object('name', btrim(p_display_name)));
  return private.trip_json(v_trip);
end $$;

-- ---------------------------------------------------------------------------
-- Invites: random secrets returned once; only SHA-256 hashes are stored.
-- ---------------------------------------------------------------------------
create or replace function private.normalize_invite_secret(p_secret text) returns text
language sql immutable set search_path = '' as $$
  select case
    when char_length(regexp_replace(btrim(p_secret), '[\s-]', '', 'g')) = 8
      then upper(regexp_replace(btrim(p_secret), '[\s-]', '', 'g'))
    else btrim(p_secret)
  end
$$;

create or replace function private.hash_secret(p_secret text) returns bytea
language sql immutable set search_path = '' as $$
  select extensions.digest(convert_to(p_secret, 'UTF8'), 'sha256')
$$;

create or replace function public.create_invite(
  p_trip_id uuid,
  p_role text default 'member',
  p_expires_in_hours integer default 168,
  p_max_uses integer default 10,
  p_participant_id uuid default null
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_token text;
  v_code text := '';
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_bytes bytea;
  v_invite public.trip_invites;
  i integer;
begin
  perform private.require_role(p_trip_id, 'admin', false);
  if p_role not in ('admin', 'member') then perform private.fail('invalid_role', 'Invites can grant member or admin access.'); end if;
  if p_expires_in_hours not between 1 and 720 then perform private.fail('invalid_expiry', 'Invites can last between 1 hour and 30 days.'); end if;
  if p_participant_id is not null and not exists (
    select 1 from public.trip_participants where id = p_participant_id and trip_id = p_trip_id and user_id is null and archived_at is null)
  then perform private.fail('participant_unavailable', 'That person is already linked to an account.', 'PT409'); end if;
  if (select count(*) from public.trip_invites where created_by = v_uid and created_at > now() - interval '1 hour') >= 20 then
    perform private.fail('rate_limited', 'Too many invites created. Try again later.', 'PT429');
  end if;

  v_token := rtrim(translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/', '-_'), '=');
  v_bytes := extensions.gen_random_bytes(8);
  for i in 0..7 loop
    v_code := v_code || substr(v_alphabet, (get_byte(v_bytes, i) % 32) + 1, 1);
  end loop;

  insert into public.trip_invites (trip_id, created_by, role, token_hash, code_hash, participant_id, expires_at, max_uses)
  values (p_trip_id, v_uid, p_role, private.hash_secret(v_token), private.hash_secret(v_code), p_participant_id,
          now() + make_interval(hours => p_expires_in_hours), p_max_uses)
  returning * into v_invite;

  return jsonb_build_object('id', v_invite.id, 'trip_id', p_trip_id, 'token', v_token, 'code', v_code,
                            'role', v_invite.role, 'expires_at', v_invite.expires_at, 'max_uses', v_invite.max_uses);
end $$;

create or replace function public.revoke_invite(p_invite_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_trip uuid;
begin
  select trip_id into v_trip from public.trip_invites where id = p_invite_id;
  if v_trip is null then perform private.fail('not_found', 'Invite not found.', 'PT404'); end if;
  perform private.require_role(v_trip, 'admin');
  update public.trip_invites set revoked_at = coalesce(revoked_at, now()) where id = p_invite_id;
end $$;

-- Looks up an invite by link token or 8-character code. Every lookup is recorded for brute-force
-- rate limiting, so invalid secrets are reported as an `error` value instead of raising (which
-- would roll back the attempt record).
create or replace function private.lookup_invite(p_secret text, p_lock boolean, out invite public.trip_invites, out error text)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_secret text := private.normalize_invite_secret(coalesce(p_secret, ''));
  v_hash bytea;
begin
  if (select count(*) from private.invite_attempts where user_id = v_uid and not succeeded and attempted_at > now() - interval '1 hour') >= 20 then
    perform private.fail('rate_limited', 'Too many invalid invite attempts. Try again in an hour.', 'PT429');
  end if;
  v_hash := private.hash_secret(v_secret);
  if p_lock then
    select * into invite from public.trip_invites i where i.token_hash = v_hash or i.code_hash = v_hash for update;
  else
    select * into invite from public.trip_invites i where i.token_hash = v_hash or i.code_hash = v_hash;
  end if;
  insert into private.invite_attempts (user_id, succeeded) values (v_uid, invite.id is not null);
  if invite.id is null or char_length(v_secret) < 8 then
    error := 'invite_invalid';
  elsif invite.revoked_at is not null then
    error := 'invite_revoked';
  elsif invite.expires_at <= now() then
    error := 'invite_expired';
  end if;
end $$;
revoke all on function private.lookup_invite(text, boolean), private.normalize_invite_secret(text), private.hash_secret(text) from public;

create or replace function public.preview_invite(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_lookup record;
  v_invite public.trip_invites;
  v_result jsonb;
begin
  select * into v_lookup from private.lookup_invite(p_secret, false);
  if v_lookup.error is not null then return jsonb_build_object('error', v_lookup.error); end if;
  v_invite := v_lookup.invite;
  select jsonb_build_object(
      'trip_id', t.id, 'name', t.name, 'emoji', t.emoji, 'start_date', t.start_date, 'end_date', t.end_date,
      'base_currency', t.base_currency, 'role', v_invite.role, 'expires_at', v_invite.expires_at,
      'invited_by', (select display_name from public.profiles where id = v_invite.created_by),
      'member_count', (select count(*) from public.trip_members m where m.trip_id = t.id and m.status = 'active'),
      'already_member', exists (select 1 from public.trip_members m where m.trip_id = t.id and m.user_id = auth.uid() and m.status = 'active'),
      'exhausted', v_invite.use_count >= v_invite.max_uses,
      'reserved_participant_id', v_invite.participant_id,
      'claimable_participants', coalesce((
        select jsonb_agg(jsonb_build_object('id', p.id, 'display_name', p.display_name) order by p.display_name)
        from public.trip_participants p
        where p.trip_id = t.id and p.user_id is null and p.archived_at is null
          and (v_invite.participant_id is null or p.id = v_invite.participant_id)), '[]'::jsonb))
    into v_result
  from public.trips t where t.id = v_invite.trip_id;
  return v_result;
end $$;

-- Joins the trip. Safe to retry: an existing active member gets the trip back without using the invite.
-- Returns {"error": code} for invalid/expired/revoked/exhausted invites.
create or replace function public.accept_invite(p_secret text, p_claim_participant_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_lookup record;
  v_invite public.trip_invites;
  v_member public.trip_members;
  v_participant uuid;
  v_name text;
begin
  select * into v_lookup from private.lookup_invite(p_secret, true);
  if v_lookup.error is not null then return jsonb_build_object('error', v_lookup.error); end if;
  v_invite := v_lookup.invite;

  select * into v_member from public.trip_members where trip_id = v_invite.trip_id and user_id = v_uid for update;
  if v_member.status = 'active' then
    return private.trip_json(v_invite.trip_id);
  end if;
  if v_invite.use_count >= v_invite.max_uses then
    return jsonb_build_object('error', 'invite_exhausted');
  end if;

  v_participant := coalesce(v_invite.participant_id, p_claim_participant_id);
  if v_participant is not null then
    if v_invite.participant_id is not null and p_claim_participant_id is not null and p_claim_participant_id <> v_invite.participant_id then
      return jsonb_build_object('error', 'participant_unavailable');
    end if;
    perform 1 from public.trip_participants
      where id = v_participant and trip_id = v_invite.trip_id and archived_at is null and (user_id is null or user_id = v_uid)
      for update;
    if not found then return jsonb_build_object('error', 'participant_unavailable'); end if;
    -- A user can be linked to only one participant per trip; release any previous link first.
    update public.trip_participants set user_id = null where trip_id = v_invite.trip_id and user_id = v_uid and id <> v_participant;
    update public.trip_participants set user_id = v_uid where id = v_participant;
  else
    select id into v_participant from public.trip_participants where trip_id = v_invite.trip_id and user_id = v_uid;
    if v_participant is null then
      select display_name into v_name from public.profiles where id = v_uid;
      v_participant := gen_random_uuid();
      insert into public.trip_participants (id, trip_id, display_name, user_id, created_by)
      values (v_participant, v_invite.trip_id, coalesce(v_name, 'Traveler'), v_uid, v_uid);
    end if;
  end if;

  insert into public.trip_members (trip_id, user_id, participant_id, role, status)
  values (v_invite.trip_id, v_uid, v_participant, v_invite.role, 'active')
  on conflict (trip_id, user_id) do update
    set status = 'active', role = excluded.role, participant_id = excluded.participant_id, status_changed_at = now(), joined_at = now();

  update public.trip_invites set use_count = use_count + 1 where id = v_invite.id;
  perform private.log_activity(v_invite.trip_id, 'member_joined', v_participant, jsonb_build_object('participant_id', v_participant));
  return private.trip_json(v_invite.trip_id);
end $$;

-- ---------------------------------------------------------------------------
-- Member management
-- ---------------------------------------------------------------------------
create or replace function public.set_member_role(p_trip_id uuid, p_user_id uuid, p_role text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'owner');
  if p_role not in ('admin', 'member') then perform private.fail('invalid_role', 'Use transfer ownership to change the owner.'); end if;
  if p_user_id = auth.uid() then perform private.fail('invalid_role', 'Transfer ownership before changing your own role.'); end if;
  update public.trip_members set role = p_role where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if not found then perform private.fail('not_found', 'That member is no longer in the trip.', 'PT404'); end if;
  perform private.log_activity(p_trip_id, 'member_role_changed', null, jsonb_build_object('user_id', p_user_id, 'role', p_role));
  return private.trip_json(p_trip_id);
end $$;

create or replace function public.transfer_ownership(p_trip_id uuid, p_new_owner_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_user();
begin
  perform private.require_role(p_trip_id, 'owner');
  if not exists (select 1 from public.trip_members where trip_id = p_trip_id and user_id = p_new_owner_id and status = 'active') then
    perform private.fail('not_found', 'The new owner must be an active member.', 'PT404');
  end if;
  if p_new_owner_id = v_uid then return private.trip_json(p_trip_id); end if;
  update public.trip_members set role = 'admin' where trip_id = p_trip_id and user_id = v_uid;
  update public.trip_members set role = 'owner' where trip_id = p_trip_id and user_id = p_new_owner_id;
  update public.trips set owner_id = p_new_owner_id, revision = revision + 1 where id = p_trip_id;
  perform private.log_activity(p_trip_id, 'ownership_transferred', null, jsonb_build_object('user_id', p_new_owner_id));
  return private.trip_json(p_trip_id);
end $$;

create or replace function public.remove_member(p_trip_id uuid, p_user_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_my_role text;
  v_target_role text;
begin
  v_my_role := private.require_role(p_trip_id, 'admin');
  select role into v_target_role from public.trip_members where trip_id = p_trip_id and user_id = p_user_id and status = 'active';
  if v_target_role is null then perform private.fail('not_found', 'That member is no longer in the trip.', 'PT404'); end if;
  if v_target_role = 'owner' then perform private.fail('owner_required', 'The owner cannot be removed.', '42501'); end if;
  if v_target_role = 'admin' and v_my_role <> 'owner' then perform private.fail('owner_required', 'Only the owner can remove admins.', '42501'); end if;
  update public.trip_members set status = 'removed', status_changed_at = now() where trip_id = p_trip_id and user_id = p_user_id;
  perform private.log_activity(p_trip_id, 'member_removed', null, jsonb_build_object('user_id', p_user_id));
  return private.trip_json(p_trip_id);
end $$;

revoke all on function public.create_trip(uuid, text, text, text, text, date, date, text, bigint, text[]),
  public.update_trip(uuid, integer, text, text, text, date, date, text, text, bigint),
  public.set_trip_archived(uuid, boolean), public.delete_trip(uuid),
  public.add_participant(uuid, uuid, text), public.rename_participant(uuid, text),
  public.create_invite(uuid, text, integer, integer, uuid), public.revoke_invite(uuid),
  public.preview_invite(text), public.accept_invite(text, uuid),
  public.set_member_role(uuid, uuid, text), public.transfer_ownership(uuid, uuid), public.remove_member(uuid, uuid)
  from public, anon;
grant execute on function public.create_trip(uuid, text, text, text, text, date, date, text, bigint, text[]),
  public.update_trip(uuid, integer, text, text, text, date, date, text, text, bigint),
  public.set_trip_archived(uuid, boolean), public.delete_trip(uuid),
  public.add_participant(uuid, uuid, text), public.rename_participant(uuid, text),
  public.create_invite(uuid, text, integer, integer, uuid), public.revoke_invite(uuid),
  public.preview_invite(text), public.accept_invite(text, uuid),
  public.set_member_role(uuid, uuid, text), public.transfer_ownership(uuid, uuid), public.remove_member(uuid, uuid)
  to authenticated;
