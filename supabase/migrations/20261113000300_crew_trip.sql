-- The crew build has exactly one trip, created here with fixed ids, and no trip creation or invites in the UI.
-- Each phone calls join_crew_trip(<name>) after its anonymous sign-in and is linked to that person's
-- participant. Re-joining under the same name (new phone or reinstalled app = new anonymous user) moves the
-- participant — and all of its expenses — to the new account and retires the old membership.
-- Trust model: anyone who has this TestFlight build can claim any of the four names.

insert into public.trips (id, owner_id, name, emoji, color_hex, start_date, end_date, timezone, base_currency)
values ('c0ffee00-2026-4000-8000-00000000c0de', null, 'Puerto Rico Thanksgiving', '🇵🇷', '23C58A',
        '2026-11-26', '2026-12-01', 'America/Puerto_Rico', 'USD')
on conflict (id) do nothing;

insert into public.trip_participants (id, trip_id, display_name)
values ('c0ffee00-2026-4000-8000-000000000001', 'c0ffee00-2026-4000-8000-00000000c0de', 'Asray'),
       ('c0ffee00-2026-4000-8000-000000000002', 'c0ffee00-2026-4000-8000-00000000c0de', 'Anoop'),
       ('c0ffee00-2026-4000-8000-000000000003', 'c0ffee00-2026-4000-8000-00000000c0de', 'Arjun'),
       ('c0ffee00-2026-4000-8000-000000000004', 'c0ffee00-2026-4000-8000-00000000c0de', 'Justin')
on conflict (id) do nothing;

create or replace function public.join_crew_trip(p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_trip uuid := 'c0ffee00-2026-4000-8000-00000000c0de';
  v_participant public.trip_participants;
  v_previous uuid;
begin
  select * into v_participant from public.trip_participants
  where trip_id = v_trip and lower(display_name) = lower(btrim(p_name)) and archived_at is null
  for update;
  if not found then perform private.fail('unknown_crew_member', 'That name is not on this trip.'); end if;

  v_previous := v_participant.user_id;
  if v_previous is distinct from v_uid then
    -- Release whatever this account held before, then take over the named participant.
    update public.trip_participants set user_id = null where trip_id = v_trip and user_id = v_uid and id <> v_participant.id;
    if v_previous is not null then
      update public.trip_members set status = 'left', status_changed_at = now()
      where trip_id = v_trip and user_id = v_previous and status = 'active';
    end if;
    update public.trip_participants set user_id = v_uid where id = v_participant.id;
  end if;

  insert into public.trip_members (trip_id, user_id, participant_id, role, status)
  values (v_trip, v_uid, v_participant.id, 'admin', 'active')
  on conflict (trip_id, user_id) do update
    set status = 'active', participant_id = excluded.participant_id, status_changed_at = now();

  if v_previous is distinct from v_uid then
    perform private.log_activity(v_trip, 'member_joined', v_participant.id, jsonb_build_object('participant_id', v_participant.id));
  end if;
  return private.trip_json(v_trip);
end $$;

revoke all on function public.join_crew_trip(text) from public, anon;
grant execute on function public.join_crew_trip(text) to authenticated;
