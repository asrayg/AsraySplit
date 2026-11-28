-- Trip chat. Messages are also exchanged phone-to-phone over Bluetooth/peer Wi-Fi when nearby; this table
-- is the durable copy. The client generates the message id, so a message delivered both ways is stored once.
-- Writes go through post_trip_message only; members read via RLS (and Realtime) or list_trip_messages.

create table public.trip_messages (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  sender_name text not null check (char_length(btrim(sender_name)) between 1 and 60),
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  sent_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index trip_messages_trip_idx on public.trip_messages(trip_id, sent_at, id);
create index trip_messages_sender_idx on public.trip_messages(sender_id);

alter table public.trip_messages enable row level security;
revoke all on public.trip_messages from public, anon, authenticated;
grant select on public.trip_messages to authenticated;

create policy trip_messages_member_read on public.trip_messages
  for select to authenticated using (private.is_trip_member(trip_id));

-- Idempotent: re-posting the same id returns the stored row unchanged (even if the body differs).
create or replace function public.post_trip_message(p_trip_id uuid, p_id uuid, p_body text, p_sent_at timestamptz default null)
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
    return to_jsonb(v_row);
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();

  insert into public.trip_messages (id, trip_id, sender_id, sender_name, body, sent_at)
  values (p_id, p_trip_id, auth.uid(), coalesce(v_name, 'Someone'), btrim(p_body),
          -- Clamp client clocks: offline messages may be older, never in the future.
          least(coalesce(p_sent_at, now()), now()))
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

create or replace function public.list_trip_messages(p_trip_id uuid, p_after timestamptz default null, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member');
  return coalesce((
    select jsonb_agg(to_jsonb(m) order by m.sent_at, m.id)
    from (select * from public.trip_messages
          where trip_id = p_trip_id and (p_after is null or created_at > p_after)
          order by sent_at desc, id desc
          limit least(greatest(coalesce(p_limit, 200), 1), 500)) m
  ), '[]'::jsonb);
end $$;

revoke all on function public.post_trip_message(uuid, uuid, text, timestamptz), public.list_trip_messages(uuid, timestamptz, integer)
  from public, anon;
grant execute on function public.post_trip_message(uuid, uuid, text, timestamptz), public.list_trip_messages(uuid, timestamptz, integer)
  to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.trip_messages;
  end if;
end $$;
