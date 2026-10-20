-- Shared pgTAP helpers. Included with \ir from each *_test.sql inside its transaction.
create schema if not exists tests;

create or replace function tests.create_user(p_email text, p_name text default null) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data) values (v_id, p_email, jsonb_build_object('display_name', coalesce(p_name, split_part(p_email, '@', 1))));
  return v_id;
end $$;

create or replace function tests.authenticate_as(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true);
end $$;

create or replace function tests.as_anon() returns void
language plpgsql as $$
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', jsonb_build_object('role', 'anon')::text, true);
end $$;

create or replace function tests.as_service() returns void
language plpgsql as $$
begin
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', jsonb_build_object('role', 'service_role')::text, true);
end $$;

create or replace function tests.reset_role() returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Minimal expense payload: p_payer pays p_amount, split equally-by-caller among p_shares.
create or replace function tests.expense_payload(p_payer uuid, p_amount bigint, p_shares jsonb, p_currency text default 'USD',
  p_extra jsonb default '{}'::jsonb) returns jsonb
language sql as $$
  select jsonb_build_object(
    'id', gen_random_uuid(), 'idempotency_key', gen_random_uuid(), 'description', 'Dinner', 'category', 'food',
    'payment_method', 'card', 'spent_at', '2026-10-20T19:00:00Z', 'split_method', 'exact',
    'amount_minor', p_amount, 'currency', p_currency,
    'payments', jsonb_build_array(jsonb_build_object('participant_id', p_payer, 'amount_minor', p_amount)),
    'allocations', p_shares) || p_extra
$$;

grant usage on schema tests to anon, authenticated, service_role;
grant execute on all functions in schema tests to anon, authenticated, service_role;
