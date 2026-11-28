-- Chat: senders can edit and delete their own messages. Deletes are tombstones (body cleared, deleted_at set)
-- so every phone removes the message on its next sync. Edits/deletes never send push notifications.

alter table public.trip_messages add column edited_at timestamptz;
alter table public.trip_messages add column deleted_at timestamptz;
alter table public.trip_messages drop constraint if exists trip_messages_body_check;
alter table public.trip_messages add constraint trip_messages_body_check
  check (deleted_at is not null or char_length(btrim(body)) between 1 and 2000);

create or replace function public.edit_trip_message(p_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row public.trip_messages;
begin
  perform private.require_user();
  select * into v_row from public.trip_messages where id = p_id for update;
  if not found then perform private.fail('not_found', 'Message not found.', 'PT404'); end if;
  perform private.require_role(v_row.trip_id, 'member');
  if v_row.sender_id is distinct from auth.uid() then perform private.fail('not_your_message', 'You can only edit your own messages.', '42501'); end if;
  if v_row.deleted_at is not null then return to_jsonb(v_row); end if;
  if p_body is null or char_length(btrim(p_body)) = 0 or char_length(p_body) > 2000 then
    perform private.fail('invalid_message', 'Messages must be 1–2000 characters.');
  end if;
  update public.trip_messages set body = btrim(p_body), edited_at = now() where id = p_id returning * into v_row;
  return to_jsonb(v_row);
end $$;

create or replace function public.delete_trip_message(p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_row public.trip_messages;
begin
  perform private.require_user();
  select * into v_row from public.trip_messages where id = p_id for update;
  if not found then perform private.fail('not_found', 'Message not found.', 'PT404'); end if;
  perform private.require_role(v_row.trip_id, 'member');
  if v_row.sender_id is distinct from auth.uid() then perform private.fail('not_your_message', 'You can only delete your own messages.', '42501'); end if;
  update public.trip_messages set body = '', deleted_at = coalesce(deleted_at, now()) where id = p_id returning * into v_row;
  return to_jsonb(v_row);
end $$;

revoke all on function public.edit_trip_message(uuid, text), public.delete_trip_message(uuid) from public, anon;
grant execute on function public.edit_trip_message(uuid, text), public.delete_trip_message(uuid) to authenticated;
