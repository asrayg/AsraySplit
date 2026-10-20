-- Canonical read RPCs used by the iOS sync engine. Both return the exact shapes produced by the
-- write RPCs so clients have one decoding path. security invoker + RLS keeps them member-scoped.

create or replace function public.list_my_trips() returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(private.trip_json(t.id) order by t.created_at desc), '[]'::jsonb)
  from public.trips t
  where exists (select 1 from public.trip_members m where m.trip_id = t.id and m.user_id = auth.uid() and m.status = 'active')
$$;

-- Incremental expense sync. Includes soft-deleted rows (tombstones). Keyset pagination on (updated_at, id).
create or replace function public.list_expenses(
  p_trip_id uuid,
  p_updated_after timestamptz default null,
  p_after_id uuid default null,
  p_limit integer default 500
) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(public.expense_json(e.id) order by e.updated_at, e.id), '[]'::jsonb)
  from (
    select x.id, x.updated_at from public.expenses x
    where x.trip_id = p_trip_id
      and (p_updated_after is null or (x.updated_at, x.id) > (p_updated_after, coalesce(p_after_id, '00000000-0000-0000-0000-000000000000'::uuid)))
    order by x.updated_at, x.id
    limit least(greatest(p_limit, 1), 1000)
  ) e
$$;

create or replace function public.list_settlements(p_trip_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(s) - 'request_hash' order by s.settled_at, s.id), '[]'::jsonb)
  from (select id, trip_id, from_participant_id, to_participant_id, amount_minor, currency, base_amount_minor, exchange_rate,
               rate_provider, rate_date, method, reference, note, settled_at, revision, idempotency_key, created_by, deleted_at,
               created_at, updated_at
        from public.settlements where trip_id = p_trip_id) s
$$;

create or replace function public.list_activity(p_trip_id uuid, p_before_id bigint default null, p_limit integer default 50) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(a) order by a.id desc), '[]'::jsonb)
  from (select * from public.activity_events
        where trip_id = p_trip_id and (p_before_id is null or id < p_before_id)
        order by id desc limit least(greatest(p_limit, 1), 200)) a
$$;

create or replace function public.list_receipts(p_trip_id uuid) returns jsonb
language sql stable security invoker set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
  from public.receipts r where r.trip_id = p_trip_id and r.deleted_at is null
$$;

-- private.trip_json is security definer and not member-checked; list_my_trips filters first, but
-- direct calls must be scoped too.
create or replace function public.get_trip(p_trip_id uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(p_trip_id, 'member');
  return private.trip_json(p_trip_id);
end $$;

grant execute on function private.trip_json(uuid) to authenticated;
-- trip_json reveals nothing beyond what RLS already allows members to read, but keep it member-only:
create or replace function private.trip_json(p_trip_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select to_jsonb(t) || jsonb_build_object(
    'my_role', private.trip_role(t.id),
    'participants', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at, p.id) from public.trip_participants p where p.trip_id = t.id), '[]'::jsonb),
    'members', coalesce((select jsonb_agg(to_jsonb(m) order by m.joined_at) from public.trip_members m where m.trip_id = t.id), '[]'::jsonb))
  from public.trips t where t.id = p_trip_id and private.is_trip_member(t.id)
$$;

revoke all on function public.list_my_trips(), public.list_expenses(uuid, timestamptz, uuid, integer), public.list_settlements(uuid),
  public.list_activity(uuid, bigint, integer), public.list_receipts(uuid), public.get_trip(uuid) from public, anon;
grant execute on function public.list_my_trips(), public.list_expenses(uuid, timestamptz, uuid, integer), public.list_settlements(uuid),
  public.list_activity(uuid, bigint, integer), public.list_receipts(uuid), public.get_trip(uuid) to authenticated;
