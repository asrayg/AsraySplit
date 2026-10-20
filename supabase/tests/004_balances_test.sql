begin;
\ir helpers/test_helpers.sql
select plan(14);

-- Fixture shared with AsraySplitTests/Domain/LedgerTests.swift (testSimplifyMatchesDatabaseFixture):
-- p1 pays 100.00 split equally four ways -> p2, p3, p4 each pay p1 25.00.
select tests.create_user('p1@example.com', 'P1') as u1 \gset
select tests.create_user('p2@example.com', 'P2') as u2 \gset
select 'cccccccc-0000-0000-0000-000000000001'::uuid as trip \gset
select '00000000-0000-0000-0000-000000000001'::uuid as p1, '00000000-0000-0000-0000-000000000002'::uuid as p2,
       '00000000-0000-0000-0000-000000000003'::uuid as p3, '00000000-0000-0000-0000-000000000004'::uuid as p4 \gset

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'Fixture', 'USD') as t \gset
select tests.reset_role();
-- Use deterministic participant ids to match the Swift fixture.
insert into public.trip_participants (id, trip_id, display_name) values (:'p1', :'trip', 'One'), (:'p2', :'trip', 'Two'), (:'p3', :'trip', 'Three'), (:'p4', :'trip', 'Four');
select tests.authenticate_as(:'u1');

select public.create_expense(:'trip', tests.expense_payload(:'p1', 10000, jsonb_build_array(
  jsonb_build_object('participant_id', :'p1', 'amount_minor', 2500), jsonb_build_object('participant_id', :'p2', 'amount_minor', 2500),
  jsonb_build_object('participant_id', :'p3', 'amount_minor', 2500), jsonb_build_object('participant_id', :'p4', 'amount_minor', 2500)))) as e \gset

select is((select net_minor from public.trip_balances(:'trip') where participant_id = :'p1'), 7500::bigint, 'payer is owed 75.00');
select is((select net_minor from public.trip_balances(:'trip') where participant_id = :'p2'), -2500::bigint, 'consumer owes 25.00');
select is((select sum(net_minor)::bigint from public.trip_balances(:'trip')), 0::bigint, 'nets sum to zero');
select results_eq(
  format($$ select from_participant_id, to_participant_id, amount_minor from public.suggested_settlements(%L) $$, :'trip'),
  format($$ values (%L::uuid, %L::uuid, 2500::bigint), (%L::uuid, %L::uuid, 2500::bigint), (%L::uuid, %L::uuid, 2500::bigint) $$, :'p2', :'p1', :'p3', :'p1', :'p4', :'p1'),
  'greedy suggestions match the Swift implementation');

-- Partial settlement: p2 pays p1 10.00.
select public.record_settlement(:'trip', jsonb_build_object('id', gen_random_uuid(), 'idempotency_key', gen_random_uuid(),
  'from_participant_id', :'p2', 'to_participant_id', :'p1', 'amount_minor', 1000, 'currency', 'USD', 'method', 'venmo')) as s1 \gset
select is((select net_minor from public.trip_balances(:'trip') where participant_id = :'p2'), -1500::bigint, 'partial settlement reduces debt');
select is((select net_minor from public.trip_balances(:'trip') where participant_id = :'p1'), 6500::bigint, 'creditor balance reduced by payment received');
select is((public.record_settlement(:'trip', :'s1'::jsonb - 'base_amount_minor' - 'exchange_rate' - 'rate_provider' - 'rate_date' - 'reference' - 'note'
   - 'settled_at' - 'revision' - 'created_by' - 'deleted_at' - 'deleted_by' - 'created_at' - 'updated_at' - 'trip_id' - 'request_hash') ->> 'id') is not null, true,
  'settlement response is canonical');
select throws_ok(format($$ select public.record_settlement(%L, jsonb_build_object('id', gen_random_uuid(), 'idempotency_key', gen_random_uuid(), 'from_participant_id', %L, 'to_participant_id', %L, 'amount_minor', 100, 'currency', 'USD')) $$, :'trip', :'p2', :'p2'),
  '22023', 'invalid_parties', 'self settlement rejected');
select throws_ok(format($$ select public.record_settlement(%L, jsonb_build_object('id', gen_random_uuid(), 'idempotency_key', gen_random_uuid(), 'from_participant_id', %L, 'to_participant_id', %L, 'amount_minor', 0, 'currency', 'USD')) $$, :'trip', :'p2', :'p1'),
  '22023', 'invalid_amount', 'zero settlement rejected');

-- Deleting the expense removes its effect; the settlement remains.
select public.delete_expense((:'e'::jsonb ->> 'id')::uuid, 1) as d \gset
select is((select net_minor from public.trip_balances(:'trip') where participant_id = :'p1'), -1000::bigint, 'deleted expense no longer counts');
select public.delete_settlement((:'s1'::jsonb ->> 'id')::uuid, 1) as ds \gset
select is((select count(*)::int from public.trip_balances(:'trip') where net_minor <> 0), 0, 'deleting settlement zeroes balances');

-- Summary aggregates.
select public.restore_expense((:'e'::jsonb ->> 'id')::uuid, 2) as r \gset
select is((public.trip_summary(:'trip') ->> 'total_spent_minor')::bigint, 10000::bigint, 'summary total from live expenses');

-- Non-members get nothing from derived functions.
select tests.authenticate_as(:'u2');
select is((select count(*)::int from public.trip_balances(:'trip') where net_minor <> 0), 0, 'non-member sees no balances');
select is(public.trip_summary(:'trip'), null, 'non-member gets no summary');

select * from finish();
rollback;
