-- Chat reactions and replies.

alter table public.trip_messages add column reply_to uuid references public.trip_messages(id) on delete set null;

create table public.trip_message_reactions (
  message_id uuid not null references public.trip_messages(id) on delete cascade,
  trip_id uuid not null references public.trips(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  emoji text not null check (char_length(emoji) between 1 and 16),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);
create index trip_message_reactions_trip_idx on public.trip_message_reactions(trip_id);
create index trip_message_reactions_user_idx on public.trip_message_reactions(user_id);

alter table public.trip_message_reactions enable row level security;
revoke all on public.trip_message_reactions from public, anon, authenticated;
grant select on public.trip_message_reactions to authenticated;
create policy trip_message_reactions_member_read on public.trip_message_reactions
  for select to authenticated using (private.is_trip_member(trip_id));

-- Idempotent toggle. Reacting (not un-reacting) notifies the message's sender.
create or replace function public.set_message_reaction(p_message_id uuid, p_emoji text, p_on boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_msg public.trip_messages;
  v_name text;
  v_inserted int;
begin
  perform private.require_user();
  select * into v_msg from public.trip_messages where id = p_message_id;
  if not found or v_msg.deleted_at is not null then perform private.fail('not_found', 'Message not found.', 'PT404'); end if;
  perform private.require_role(v_msg.trip_id, 'member');
  if p_emoji is null or char_length(p_emoji) not between 1 and 16 then perform private.fail('invalid_reaction', 'Pick an emoji.'); end if;

  if not coalesce(p_on, true) then
    delete from public.trip_message_reactions where message_id = p_message_id and user_id = auth.uid() and emoji = p_emoji;
    return;
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = v_msg.trip_id and p.user_id = auth.uid();
  insert into public.trip_message_reactions (message_id, trip_id, user_id, display_name, emoji)
  values (p_message_id, v_msg.trip_id, auth.uid(), coalesce(v_name, 'Someone'), p_emoji)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted > 0 and v_msg.sender_id is distinct from auth.uid() and v_msg.sender_id is not null then
    insert into public.push_jobs (user_id, trip_id, kind, payload, dedupe_key)
    select v_msg.sender_id, v_msg.trip_id, 'chat_reaction',
           jsonb_build_object('trip_id', v_msg.trip_id, 'entity_id', v_msg.id, 'kind', 'chat_reaction',
                              'title', coalesce(v_name, 'Someone'),
                              'body', 'Reacted ' || p_emoji || ' to “' || left(v_msg.body, 80) || '”'),
           'reaction:' || p_message_id || ':' || auth.uid() || ':' || p_emoji
    where exists (select 1 from public.devices d where d.user_id = v_msg.sender_id)
    on conflict (dedupe_key) do nothing;
  end if;
end $$;

-- post_trip_message gains p_reply_to.
drop function public.post_trip_message(uuid, uuid, text, timestamptz, boolean);
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
          -- Only keep a reply link to a message in the same trip (it may not have synced yet: then drop it).
          (select m.id from public.trip_messages m where m.id = p_reply_to and m.trip_id = p_trip_id))
  returning * into v_row;
  return to_jsonb(v_row) || jsonb_build_object('reactions', '[]'::jsonb);
end $$;

create or replace function public.list_trip_messages(p_trip_id uuid, p_after timestamptz default null, p_limit integer default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member');
  return coalesce((
    select jsonb_agg(to_jsonb(m) || jsonb_build_object('reactions', coalesce((
             select jsonb_agg(jsonb_build_object('emoji', r.emoji, 'user_id', r.user_id, 'display_name', r.display_name) order by r.created_at)
             from public.trip_message_reactions r where r.message_id = m.id), '[]'::jsonb))
           order by m.sent_at, m.id)
    from (select * from public.trip_messages
          where trip_id = p_trip_id and (p_after is null or created_at > p_after)
          order by sent_at desc, id desc
          limit least(greatest(coalesce(p_limit, 200), 1), 500)) m
  ), '[]'::jsonb);
end $$;

revoke all on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean, uuid),
  public.set_message_reaction(uuid, text, boolean) from public, anon;
grant execute on function public.post_trip_message(uuid, uuid, text, timestamptz, boolean, uuid),
  public.set_message_reaction(uuid, text, boolean) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.trip_message_reactions;
  end if;
end $$;
