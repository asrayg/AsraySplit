begin;
\ir helpers/test_helpers.psql
select plan(35);

select tests.create_user('a@example.com', 'Ana') as ua \gset
select tests.create_user('b@example.com', 'Ben') as ub \gset
select tests.create_user('x@example.com', 'Xan') as ux \gset
select 'bbbbbbbb-0000-0000-0000-000000000001'::uuid as trip \gset

select tests.authenticate_as(:'ua');
select public.create_trip(:'trip', 'Tokyo', 'USD', '🗼', '23C58A', null, null, 'Asia/Tokyo', null, array['Cam']) as t \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'ua') as pa \gset
select (select id from public.trip_participants where trip_id = :'trip' and display_name = 'Cam') as pc \gset
select public.create_invite(:'trip') as inv \gset
select tests.authenticate_as(:'ub');
select public.accept_invite(:'inv'::jsonb ->> 'token') as joined \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'ub') as pb \gset

-- Valid create: 100.00 paid by A, split 34/33/33.
select tests.expense_payload(:'pa', 10000, jsonb_build_array(
  jsonb_build_object('participant_id', :'pa', 'amount_minor', 3334),
  jsonb_build_object('participant_id', :'pb', 'amount_minor', 3333),
  jsonb_build_object('participant_id', :'pc', 'amount_minor', 3333)), 'USD', '{"tags": ["Dinner", "shared"]}'::jsonb) as p1 \gset
select public.create_expense(:'trip', :'p1') as e1 \gset
select is((:'e1'::jsonb ->> 'revision')::int, 1, 'new expense starts at revision 1');
select is((:'e1'::jsonb ->> 'base_minor')::bigint, 10000::bigint, 'base amount equals original in base currency');
select is(jsonb_array_length(:'e1'::jsonb -> 'allocations'), 3, 'allocations stored');
select is((:'e1'::jsonb -> 'tags'), '["dinner", "shared"]'::jsonb, 'tags normalized');

-- Replays are idempotent; key reuse with different content conflicts.
select is((public.create_expense(:'trip', :'p1') ->> 'id'), (:'e1'::jsonb ->> 'id'), 'replayed create returns original');
select is((select count(*)::int from public.expenses where trip_id = :'trip'), 1, 'replay created no duplicate');
select throws_ok(format($$ select public.create_expense(%L, %L::jsonb || '{"description": "Changed"}') $$, :'trip', :'p1'),
  'PT409', 'idempotency_key_reused', 'same key with different payload conflicts');
select throws_ok(format($$ select public.create_expense(%L, %L::jsonb || jsonb_build_object('idempotency_key', gen_random_uuid())) $$, :'trip', :'p1'),
  'PT409', 'id_conflict', 'reusing an expense id with a new key conflicts');

-- Validation.
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 10000, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 9999)))) $$, :'trip', :'pa', :'pa'),
  '22023', 'allocations_mismatch', 'allocations must equal total');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 10000, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 10000))) || '{"payments": [{"participant_id": "%s", "amount_minor": 5000}]}') $$, :'trip', :'pa', :'pa', :'pa'),
  '22023', 'payments_mismatch', 'payments must equal total');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 10000, jsonb_build_array(jsonb_build_object('participant_id', gen_random_uuid(), 'amount_minor', 10000)))) $$, :'trip', :'pa'),
  '22023', 'unknown_participant', 'participants must belong to the trip');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 0, '[]')) $$, :'trip', :'pa'),
  '22023', 'invalid_amount', 'zero amount rejected');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 1000, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 1500), jsonb_build_object('participant_id', %L, 'amount_minor', -500)))) $$, :'trip', :'pa', :'pa', :'pb'),
  '22023', 'mixed_signs', 'mixed sign shares rejected');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 1000, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 1000)), 'EUR')) $$, :'trip', :'pa', :'pa'),
  '22023', 'exchange_rate_required', 'foreign currency requires a rate');

-- Foreign currency: 10,000 JPY at 0.0067 = 67.00 USD, base shares apportioned exactly.
select public.create_expense(:'trip', tests.expense_payload(:'pb', 10000, jsonb_build_array(
  jsonb_build_object('participant_id', :'pa', 'amount_minor', 3334),
  jsonb_build_object('participant_id', :'pb', 'amount_minor', 3333),
  jsonb_build_object('participant_id', :'pc', 'amount_minor', 3333)), 'JPY',
  '{"exchange_rate": "0.0067", "rate_provider": "ecb", "rate_date": "2026-10-19T00:00:00Z"}'::jsonb)) as e2 \gset
select is((:'e2'::jsonb ->> 'base_minor')::bigint, 6700::bigint, 'JPY converted to USD minor units');
select is((select sum(base_amount_minor)::bigint from public.expense_allocations where expense_id = (:'e2'::jsonb ->> 'id')::uuid), 6700::bigint, 'base allocations sum to base total');
select is((select base_amount_minor from public.expense_allocations where expense_id = (:'e2'::jsonb ->> 'id')::uuid and participant_id = :'pa'), 2234::bigint, 'largest remainder matches Swift');

-- Itemized expenses must reconcile.
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 1200, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 1200)),
   'USD', jsonb_build_object('split_method', 'itemized', 'tax_minor', 100, 'items', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'name', 'Ramen', 'amount_minor', 1000, 'assignees', jsonb_build_array(jsonb_build_object('participant_id', %L, 'weight', 1))))))) $$,
   :'trip', :'pa', :'pa', :'pa'),
  '22023', 'receipt_unreconciled', 'itemized total must equal items + extras');
select lives_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 1100, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 1100)),
   'USD', jsonb_build_object('split_method', 'itemized', 'tax_minor', 100, 'items', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'name', 'Ramen', 'amount_minor', 1000, 'assignees', jsonb_build_array(jsonb_build_object('participant_id', %L, 'weight', 1))))))) $$,
   :'trip', :'pa', :'pa', :'pa'),
  'reconciled itemized expense accepted');
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 1000, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 1000)),
   'USD', jsonb_build_object('split_method', 'itemized', 'items', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'name', 'Mystery', 'amount_minor', 1000, 'assignees', '[]'::jsonb))))) $$,
   :'trip', :'pa', :'pa'),
  '22023', 'unassigned_items', 'unassigned items rejected');

-- Optimistic concurrency: two editors start from revision 1; the second save conflicts.
select public.update_expense((:'e1'::jsonb ->> 'id')::uuid, 1, :'p1'::jsonb || '{"description": "Sushi dinner"}') as e1v2 \gset
select is((:'e1v2'::jsonb ->> 'revision')::int, 2, 'update bumps revision');
select is((:'e1v2'::jsonb ->> 'description'), 'Sushi dinner', 'update applied');
select throws_ok(format($$ select public.update_expense(%L, 1, %L::jsonb || '{"description": "Stale edit"}') $$, :'e1'::jsonb ->> 'id', :'p1'),
  'PT409', 'revision_conflict', 'stale revision cannot overwrite');
select is((select description from public.expenses where id = (:'e1'::jsonb ->> 'id')::uuid), 'Sushi dinner', 'stale edit did not overwrite');
select is((select count(*)::int from public.expense_allocations where expense_id = (:'e1'::jsonb ->> 'id')::uuid), 3, 'update replaced allocations atomically');

-- Failed update rolls back completely (atomicity).
select throws_ok(format($$ select public.update_expense(%L, 2, %L::jsonb || '{"amount_minor": 99999}') $$, :'e1'::jsonb ->> 'id', :'p1'),
  '22023', 'payments_mismatch', 'invalid update rejected');
select is((select revision from public.expenses where id = (:'e1'::jsonb ->> 'id')::uuid), 2, 'failed update left revision unchanged');

-- Delete is a soft delete with history; restore brings it back.
select is((public.delete_expense((:'e1'::jsonb ->> 'id')::uuid, 2) ->> 'deleted_at') is not null, true, 'expense soft deleted');
select is((select count(*)::int from public.activity_events where trip_id = :'trip' and kind = 'expense_deleted'), 1, 'deletion logged');
select is((public.restore_expense((:'e1'::jsonb ->> 'id')::uuid, 3) ->> 'deleted_at'), null, 'expense restored');

-- Non-members cannot read or mutate.
select tests.authenticate_as(:'ux');
select is((select count(*)::int from public.expenses where trip_id = :'trip'), 0, 'non-member reads no expenses');
select is((select count(*)::int from public.expense_allocations where trip_id = :'trip'), 0, 'non-member reads no allocations');
select throws_ok(format($$ select public.create_expense(%L, %L) $$, :'trip', :'p1'), '42501', 'not_trip_member', 'non-member cannot create');
select throws_ok(format($$ select public.delete_expense(%L, 4) $$, :'e1'::jsonb ->> 'id'), '42501', 'not_trip_member', 'non-member cannot delete');

-- Archived trips are read-only.
select tests.authenticate_as(:'ua');
select public.set_trip_archived(:'trip', true) as archived \gset
select throws_ok(format($$ select public.create_expense(%L, tests.expense_payload(%L, 500, jsonb_build_array(jsonb_build_object('participant_id', %L, 'amount_minor', 500)))) $$, :'trip', :'pa', :'pa'),
  'PT409', 'trip_archived', 'archived trip rejects new expenses');

select * from finish();
rollback;
