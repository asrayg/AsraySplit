-- Reverts 20261127000100 (already applied in production): announcements are Asray-only again and the
-- "ping Asray" RPC is removed. Restores post_trip_message exactly as in 20261116000200.

drop function if exists public.ping_crew_lead(uuid, text);

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
  if coalesce(p_announce, false) and not private.is_crew_lead(p_trip_id) then
    perform private.fail('announcements_restricted', 'Only Asray can send announcements.', '42501');
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
          (select m.id from public.trip_messages m where m.id = p_reply_to and m.trip_id = p_trip_id))
  returning * into v_row;
  return to_jsonb(v_row) || jsonb_build_object('reactions', '[]'::jsonb);
end $$;
revoke all on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean, uuid) from public, anon;
grant execute on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean, uuid) to authenticated;
