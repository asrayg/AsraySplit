-- Photos sent in chat are messages whose body is "📷 Photo\nasraysplit://photo/<id>".
-- The push notification for them should be just a camera emoji, not the file link.
create or replace function private.push_chat_message() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.push_to_trip(new.trip_id, new.sender_id,
    case when new.is_announcement then 'announcement' else 'chat_message' end,
    case when new.is_announcement then '📣 ' || new.sender_name else new.sender_name end,
    case when left(new.body, 8) = E'📷 Photo\n' then '📷' else new.body end,
    new.id, 'chat:' || new.id);
  return new;
end $$;
