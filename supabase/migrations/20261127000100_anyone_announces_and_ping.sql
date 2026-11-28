-- Anyone on the trip can send an announcement (it notifies everyone else), and anyone can ping Asray.

-- Same signature as before; only the "Asray only" announcement check is gone.
create or replace function public.post_trip_message(p_trip_id uuid, p_id uuid, p_body text, p_sent_at timestamptz default null,
  p_announce boolean default false, p_reply_to uuid default null)
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

  select * into v_row from public.trip_messages where id = p_id;
  if found then
    if v_row.trip_id <> p_trip_id or v_row.sender_id is distinct from auth.uid() then
      perform private.fail('message_id_conflict', 'That message id is already used.', 'P0001');
    end if;
    return to_jsonb(v_row) || jsonb_build_object('reactions', '[]'::jsonb);
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();

  insert into public.trip_messages (id, trip_id, sender_id, sender_name, body, sent_at, is_announcement, reply_to)
  values (p_id, p_trip_id, auth.uid(), coalesce(v_name, 'Someone'), btrim(p_body), least(coalesce(p_sent_at, now()), now()),
          coalesce(p_announce, false),
          -- Only keep a reply link to a message in the same trip (it may not have synced yet: then drop it).
          (select m.id from public.trip_messages m where m.id = p_reply_to and m.trip_id = p_trip_id))
  returning * into v_row;
  return to_jsonb(v_row) || jsonb_build_object('reactions', '[]'::jsonb);
end $$;

-- "Ping Asray": a push to the crew lead from any member. One per sender per 30 seconds (dedupe bucket).
-- Respects the lead's push-enabled and trip-mute settings, like every other notification.
create or replace function public.ping_crew_lead(p_trip_id uuid, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_lead uuid;
begin
  perform private.require_role(p_trip_id, 'member');
  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();
  select p.user_id into v_lead from public.trip_participants p
  where p.trip_id = p_trip_id and p.id = 'c0ffee00-2026-4000-8000-000000000001';
  if v_lead is null or v_lead = auth.uid() then return; end if;

  insert into public.push_jobs (user_id, trip_id, kind, payload, dedupe_key)
  select v_lead, p_trip_id, 'ping',
         jsonb_build_object('trip_id', p_trip_id, 'kind', 'ping', 'title', left('👋 ' || coalesce(v_name, 'Someone'), 80),
                            'body', left(coalesce(nullif(btrim(p_note), ''), 'is trying to get your attention'), 180)),
         'ping:' || auth.uid() || ':' || floor(extract(epoch from now()) / 30)::bigint
  where exists (select 1 from public.devices d where d.user_id = v_lead)
    and coalesce((select np.push_enabled from public.notification_preferences np where np.user_id = v_lead), true)
    and not coalesce((select ts.muted from public.trip_notification_settings ts where ts.user_id = v_lead and ts.trip_id = p_trip_id), false)
  on conflict (dedupe_key) do nothing;
end $$;
revoke all on function public.ping_crew_lead(uuid, text) from public, anon;
grant execute on function public.ping_crew_lead(uuid, text) to authenticated;
