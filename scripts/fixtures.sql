-- Produces canonical JSON payloads for Swift contract tests (AsraySplitTests/Fixtures).
begin;
\ir ../supabase/tests/helpers/test_helpers.sql
\set QUIET on
\pset tuples_only on
\pset format unaligned
select tests.create_user('fx1@example.com', 'Ana') as u1 \gset
select tests.create_user('fx2@example.com', 'Ben') as u2 \gset
select tests.authenticate_as(:'u1') \gset
select public.create_trip('11111111-1111-4111-8111-111111111111', 'Fixture Trip', 'USD', '🌊', '23C58A', '2026-11-01', '2026-11-08', 'Europe/Lisbon', 150000, array['Guest Gus']) as t \gset
select (select id from public.trip_participants where trip_id = '11111111-1111-4111-8111-111111111111' and user_id = :'u1') as p1 \gset
select (select id from public.trip_participants where trip_id = '11111111-1111-4111-8111-111111111111' and display_name = 'Guest Gus') as p2 \gset
select public.create_invite('11111111-1111-4111-8111-111111111111') as inv \gset
select public.create_expense('11111111-1111-4111-8111-111111111111', tests.expense_payload(:'p1', 10000, jsonb_build_array(
  jsonb_build_object('participant_id', :'p1', 'amount_minor', 3334), jsonb_build_object('participant_id', :'p2', 'amount_minor', 6666)),
  'JPY', jsonb_build_object('exchange_rate', '0.0067', 'rate_provider', 'ecb', 'rate_date', '2026-10-19T00:00:00Z', 'split_method', 'itemized',
  'tax_minor', 1000, 'tags', jsonb_build_array('food'), 'items', jsonb_build_array(
    jsonb_build_object('id', gen_random_uuid(), 'name', 'Ramen', 'quantity', 2, 'amount_minor', 9000,
      'assignees', jsonb_build_array(jsonb_build_object('participant_id', :'p1', 'weight', 1), jsonb_build_object('participant_id', :'p2', 'weight', 2))))))) as e \gset
select public.record_settlement('11111111-1111-4111-8111-111111111111', jsonb_build_object('id', gen_random_uuid(), 'idempotency_key', gen_random_uuid(),
  'from_participant_id', :'p2', 'to_participant_id', :'p1', 'amount_minor', 1000, 'currency', 'USD', 'method', 'venmo', 'reference', 'abc')) as s \gset
\o :outdir/trip.json
select public.get_trip('11111111-1111-4111-8111-111111111111');
\o :outdir/trips.json
select public.list_my_trips();
\o :outdir/expenses.json
select public.list_expenses('11111111-1111-4111-8111-111111111111');
\o :outdir/settlements.json
select public.list_settlements('11111111-1111-4111-8111-111111111111');
\o :outdir/balances.json
select coalesce(jsonb_agg(to_jsonb(b)), '[]') from public.trip_balances('11111111-1111-4111-8111-111111111111') b;
\o :outdir/suggestions.json
select coalesce(jsonb_agg(to_jsonb(b)), '[]') from public.suggested_settlements('11111111-1111-4111-8111-111111111111') b;
\o :outdir/summary.json
select public.trip_summary('11111111-1111-4111-8111-111111111111');
\o :outdir/activity.json
select public.list_activity('11111111-1111-4111-8111-111111111111');
\o :outdir/invite.json
select :'inv';
select tests.authenticate_as(:'u2') \gset
\o :outdir/invite_preview.json
select public.preview_invite(:'inv'::jsonb ->> 'code');
\o
rollback;
