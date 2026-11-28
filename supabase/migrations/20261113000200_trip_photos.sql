-- Shared trip album. Photos are passed phone-to-phone when nearby and uploaded here (typically overnight,
-- on Wi-Fi + charging) so everyone ends up with the full set.
--
-- Object paths: trip-photos/{trip_id}/{photo_id}.jpg — the client resizes to ≤2048 px JPEG before upload.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('trip-photos', 'trip-photos', false, 15728640, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.photo_path_trip(p_name text) returns uuid
language sql immutable set search_path = '' as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
    then split_part(p_name, '/', 1)::uuid end
$$;
grant execute on function private.photo_path_trip(text) to authenticated;

create policy "members upload trip photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'trip-photos' and (select private.is_trip_member(private.photo_path_trip(name))));
create policy "members read trip photos" on storage.objects for select to authenticated
  using (bucket_id = 'trip-photos' and (select private.is_trip_member(private.photo_path_trip(name))));
create policy "uploader or admin deletes trip photos" on storage.objects for delete to authenticated
  using (bucket_id = 'trip-photos' and (
    (owner_id = (select auth.uid())::text and (select private.is_trip_member(private.photo_path_trip(name))))
    or (select private.trip_role(private.photo_path_trip(name))) in ('owner', 'admin')));

create table public.trip_photos (
  id uuid primary key,
  trip_id uuid not null references public.trips(id) on delete cascade,
  uploader_id uuid references auth.users(id) on delete set null,
  uploader_name text not null check (char_length(btrim(uploader_name)) between 1 and 60),
  object_path text not null unique,
  width integer not null check (width between 1 and 10000),
  height integer not null check (height between 1 and 10000),
  byte_size integer not null check (byte_size between 1 and 15728640),
  taken_at timestamptz,
  created_at timestamptz not null default now()
);
create index trip_photos_trip_idx on public.trip_photos(trip_id, created_at, id);
create index trip_photos_uploader_idx on public.trip_photos(uploader_id);

alter table public.trip_photos enable row level security;
revoke all on public.trip_photos from public, anon, authenticated;
grant select on public.trip_photos to authenticated;
create policy trip_photos_member_read on public.trip_photos
  for select to authenticated using (private.is_trip_member(trip_id));

-- Registers an uploaded object. Idempotent on id; the object must already exist in the bucket.
create or replace function public.register_trip_photo(p_trip_id uuid, p_id uuid, p_width integer, p_height integer,
  p_byte_size integer, p_taken_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_path text := lower(p_trip_id::text) || '/' || lower(p_id::text) || '.jpg';
  v_name text;
  v_row public.trip_photos;
begin
  perform private.require_role(p_trip_id, 'member');
  select * into v_row from public.trip_photos where id = p_id;
  if found then
    if v_row.trip_id <> p_trip_id or v_row.uploader_id is distinct from auth.uid() then
      perform private.fail('photo_id_conflict', 'That photo id is already used.', 'P0001');
    end if;
    return to_jsonb(v_row);
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'trip-photos' and o.name = v_path) then
    perform private.fail('photo_not_uploaded', 'Upload the photo before registering it.');
  end if;
  if coalesce(p_width, 0) not between 1 and 10000 or coalesce(p_height, 0) not between 1 and 10000
     or coalesce(p_byte_size, 0) not between 1 and 15728640 then
    perform private.fail('invalid_photo', 'Photo size is out of range.');
  end if;
  select coalesce(nullif(btrim(p.display_name), ''), 'Someone') into v_name
  from public.trip_participants p where p.trip_id = p_trip_id and p.user_id = auth.uid();

  insert into public.trip_photos (id, trip_id, uploader_id, uploader_name, object_path, width, height, byte_size, taken_at)
  values (p_id, p_trip_id, auth.uid(), coalesce(v_name, 'Someone'), v_path, p_width, p_height, p_byte_size,
          least(p_taken_at, now()))
  returning * into v_row;
  return to_jsonb(v_row);
end $$;

create or replace function public.list_trip_photos(p_trip_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member');
  return coalesce((select jsonb_agg(to_jsonb(p) order by coalesce(p.taken_at, p.created_at), p.id)
                   from public.trip_photos p where p.trip_id = p_trip_id), '[]'::jsonb);
end $$;

create or replace function public.delete_trip_photo(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_row public.trip_photos;
begin
  perform private.require_user();
  select * into v_row from public.trip_photos where id = p_id;
  if not found then perform private.fail('not_found', 'Photo not found.', 'PT404'); end if;
  if v_row.uploader_id is distinct from auth.uid() then
    perform private.require_role(v_row.trip_id, 'admin');
  else
    perform private.require_role(v_row.trip_id, 'member');
  end if;
  delete from public.trip_photos where id = p_id;
  insert into private.storage_cleanup_queue (bucket_id, object_path, reason) values ('trip-photos', v_row.object_path, 'photo_deleted');
end $$;

revoke all on function public.register_trip_photo(uuid, uuid, integer, integer, integer, timestamptz),
  public.list_trip_photos(uuid), public.delete_trip_photo(uuid) from public, anon;
grant execute on function public.register_trip_photo(uuid, uuid, integer, integer, integer, timestamptz),
  public.list_trip_photos(uuid), public.delete_trip_photo(uuid) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.trip_photos;
  end if;
end $$;
