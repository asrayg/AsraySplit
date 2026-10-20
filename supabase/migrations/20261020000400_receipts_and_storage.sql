-- Private receipt storage, receipt registration, duplicate detection, and AI scan bookkeeping.
--
-- Object paths: receipts/{trip_id}/{receipt_id}.{jpg|png|heic|pdf}

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/heic', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.receipt_path_trip(p_name text) returns uuid
language sql immutable set search_path = '' as $$
  select case when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|heic|pdf)$'
    then split_part(p_name, '/', 1)::uuid end
$$;
grant execute on function private.receipt_path_trip(text) to authenticated;

create policy "members upload trip receipts" on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts' and (select private.is_trip_member(private.receipt_path_trip(name))));
create policy "members read trip receipts" on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and (select private.is_trip_member(private.receipt_path_trip(name))));
create policy "uploader or admin deletes receipts" on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and (
    (owner_id = (select auth.uid())::text and (select private.is_trip_member(private.receipt_path_trip(name))))
    or (select private.trip_role(private.receipt_path_trip(name))) in ('owner', 'admin')));

-- Objects whose rows were deleted; drained by the `maintenance` Edge Function with the service role.
create table private.storage_cleanup_queue (
  id bigint generated always as identity primary key,
  bucket_id text not null,
  object_path text not null,
  reason text not null,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  attempts integer not null default 0,
  last_error text
);
create index storage_cleanup_pending_idx on private.storage_cleanup_queue(created_at) where processed_at is null;

create or replace function private.queue_trip_storage_cleanup(p_trip_id uuid, p_reason text) returns void
language sql security definer set search_path = '' as $$
  insert into private.storage_cleanup_queue (bucket_id, object_path, reason)
  select 'receipts', r.object_path, p_reason from public.receipts r where r.trip_id = p_trip_id
$$;

-- Registers an uploaded receipt and reports likely duplicates in the same trip
-- (identical bytes, or the same perceptual hash).
create or replace function public.register_receipt(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid := (p_payload ->> 'id')::uuid;
  v_trip uuid := (p_payload ->> 'trip_id')::uuid;
  v_path text := p_payload ->> 'object_path';
  v_existing public.receipts;
  v_ext text;
begin
  perform private.require_role(v_trip, 'member', false);
  if private.receipt_path_trip(v_path) is distinct from v_trip or split_part(split_part(v_path, '/', 2), '.', 1) <> v_id::text then
    perform private.fail('invalid_receipt_path', 'The receipt upload path does not match this trip.', '42501');
  end if;
  v_ext := split_part(v_path, '.', 2);
  if (p_payload ->> 'mime_type') is distinct from (case v_ext when 'jpg' then 'image/jpeg' when 'png' then 'image/png' when 'heic' then 'image/heic' when 'pdf' then 'application/pdf' end) then
    perform private.fail('invalid_receipt_type', 'Receipts must be JPEG, PNG, HEIC, or PDF.');
  end if;
  select * into v_existing from public.receipts where id = v_id;
  if found then
    if v_existing.trip_id <> v_trip then perform private.fail('id_conflict', 'This receipt ID is already in use.', 'PT409'); end if;
  else
    if (select count(*) from public.receipts where uploaded_by = auth.uid() and created_at > now() - interval '1 day') >= 200 then
      perform private.fail('rate_limited', 'Daily receipt upload limit reached.', 'PT429');
    end if;
    insert into public.receipts (id, trip_id, uploaded_by, object_path, mime_type, byte_size, width, height, sha256, perceptual_hash)
    values (v_id, v_trip, auth.uid(), v_path, p_payload ->> 'mime_type', (p_payload ->> 'byte_size')::integer,
            (p_payload ->> 'width')::integer, (p_payload ->> 'height')::integer, lower(p_payload ->> 'sha256'),
            lower(nullif(p_payload ->> 'perceptual_hash', '')))
    returning * into v_existing;
  end if;
  return jsonb_build_object(
    'receipt', to_jsonb(v_existing),
    'duplicates', coalesce((
      select jsonb_agg(jsonb_build_object('receipt_id', r.id, 'expense_id', r.expense_id, 'created_at', r.created_at,
                                          'exact', r.sha256 = v_existing.sha256) order by r.created_at)
      from public.receipts r
      where r.trip_id = v_trip and r.id <> v_id and r.deleted_at is null
        and (r.sha256 = v_existing.sha256 or (v_existing.perceptual_hash is not null and r.perceptual_hash = v_existing.perceptual_hash))), '[]'::jsonb));
end $$;

-- Marks a receipt deleted and queues its object for removal. Uploader or trip admin only.
create or replace function public.delete_receipt(p_receipt_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_row public.receipts; v_role text;
begin
  select * into v_row from public.receipts where id = p_receipt_id for update;
  if not found then perform private.fail('not_found', 'Receipt not found.', 'PT404'); end if;
  v_role := private.require_role(v_row.trip_id, 'member');
  if v_row.uploaded_by is distinct from auth.uid() and v_role not in ('owner', 'admin') then
    perform private.fail('admin_required', 'Only the uploader or a trip admin can delete this receipt.', '42501');
  end if;
  if v_row.deleted_at is null then
    update public.receipts set deleted_at = now(), scan_result = null, expense_id = null, settlement_id = null where id = p_receipt_id;
    insert into private.storage_cleanup_queue (bucket_id, object_path, reason) values ('receipts', v_row.object_path, 'receipt_deleted');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- AI scan bookkeeping. The Edge Function calls begin_receipt_scan with the user's JWT (membership
-- + quota checked here), then complete_receipt_scan with the service role. Receipt contents are
-- stored only on the receipt row (visible to trip members), never in usage logs.
-- ---------------------------------------------------------------------------
create table public.ai_usage (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  trip_id uuid references public.trips(id) on delete set null,
  receipt_id uuid references public.receipts(id) on delete set null,
  feature text not null default 'receipt_scan',
  model text,
  outcome text not null default 'pending' check (outcome in ('pending', 'succeeded', 'failed', 'invalid_output', 'timeout', 'quota_exceeded')),
  latency_ms integer,
  input_tokens integer,
  output_tokens integer,
  error_code text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create index ai_usage_user_time_idx on public.ai_usage(user_id, created_at);
alter table public.ai_usage enable row level security;
revoke all on public.ai_usage from anon, authenticated;
grant select on public.ai_usage to authenticated;
create policy "users read own ai usage" on public.ai_usage for select to authenticated using (user_id = (select auth.uid()));

create table private.app_limits (
  key text primary key,
  value integer not null
);
insert into private.app_limits (key, value) values
  ('receipt_scans_per_day', 25), ('receipt_scans_per_month', 300), ('receipt_scans_global_per_day', 20000);

create or replace function public.begin_receipt_scan(p_receipt_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_user();
  v_row public.receipts;
  v_usage uuid;
  v_daily integer;
  v_monthly integer;
  v_global integer;
begin
  select * into v_row from public.receipts where id = p_receipt_id and deleted_at is null for update;
  if not found then perform private.fail('not_found', 'Receipt not found.', 'PT404'); end if;
  perform private.require_role(v_row.trip_id, 'member');
  if v_row.scan_status = 'processing' and v_row.updated_at > now() - interval '2 minutes' then
    perform private.fail('scan_in_progress', 'This receipt is already being scanned.', 'PT409');
  end if;
  if v_row.scan_status = 'succeeded' then
    return jsonb_build_object('receipt_id', v_row.id, 'cached', true, 'result', v_row.scan_result);
  end if;
  select count(*) into v_daily from public.ai_usage where user_id = v_uid and created_at > now() - interval '1 day' and outcome <> 'quota_exceeded';
  select count(*) into v_monthly from public.ai_usage where user_id = v_uid and created_at > now() - interval '30 days' and outcome <> 'quota_exceeded';
  select count(*) into v_global from public.ai_usage where created_at > now() - interval '1 day' and outcome <> 'quota_exceeded';
  if v_daily >= (select value from private.app_limits where key = 'receipt_scans_per_day')
     or v_monthly >= (select value from private.app_limits where key = 'receipt_scans_per_month')
     or v_global >= (select value from private.app_limits where key = 'receipt_scans_global_per_day') then
    perform private.fail('scan_quota_exceeded', 'You have reached the receipt scan limit. You can still enter items manually.', 'PT429');
  end if;
  insert into public.ai_usage (user_id, trip_id, receipt_id) values (v_uid, v_row.trip_id, v_row.id) returning id into v_usage;
  update public.receipts set scan_status = 'processing', scan_error = null where id = v_row.id;
  return jsonb_build_object('receipt_id', v_row.id, 'usage_id', v_usage, 'object_path', v_row.object_path,
                            'mime_type', v_row.mime_type, 'trip_id', v_row.trip_id, 'cached', false,
                            'base_currency', (select base_currency from public.trips where id = v_row.trip_id));
end $$;

-- Service role only. Stores the validated scan result (or failure) and usage metrics.
create or replace function public.complete_receipt_scan(
  p_receipt_id uuid, p_usage_id uuid, p_outcome text, p_result jsonb, p_model text,
  p_latency_ms integer, p_input_tokens integer, p_output_tokens integer, p_error_code text
) returns void language plpgsql security definer set search_path = '' as $$
declare v_trip uuid;
begin
  update public.ai_usage set outcome = p_outcome, model = p_model, latency_ms = p_latency_ms, input_tokens = p_input_tokens,
    output_tokens = p_output_tokens, error_code = p_error_code, completed_at = now()
  where id = p_usage_id;
  update public.receipts set
    scan_status = case when p_outcome = 'succeeded' then 'succeeded' else 'failed' end,
    scan_result = case when p_outcome = 'succeeded' then p_result else scan_result end,
    scan_error = case when p_outcome = 'succeeded' then null else p_error_code end,
    scan_model = p_model, scanned_at = now()
  where id = p_receipt_id and deleted_at is null
  returning trip_id into v_trip;
  if v_trip is not null then
    insert into public.activity_events (trip_id, actor_id, kind, entity_id, data)
    select v_trip, u.user_id, case when p_outcome = 'succeeded' then 'receipt_scanned' else 'receipt_scan_failed' end, p_receipt_id, '{}'::jsonb
    from public.ai_usage u where u.id = p_usage_id;
  end if;
end $$;

revoke all on function public.register_receipt(jsonb), public.delete_receipt(uuid), public.begin_receipt_scan(uuid),
  public.complete_receipt_scan(uuid, uuid, text, jsonb, text, integer, integer, integer, text),
  private.queue_trip_storage_cleanup(uuid, text) from public, anon, authenticated;
grant execute on function public.register_receipt(jsonb), public.delete_receipt(uuid), public.begin_receipt_scan(uuid) to authenticated;
grant execute on function public.complete_receipt_scan(uuid, uuid, text, jsonb, text, integer, integer, integer, text) to service_role;
