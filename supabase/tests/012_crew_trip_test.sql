begin;
\ir helpers/test_helpers.psql
select plan(9);

select 'c0ffee00-2026-4000-8000-00000000c0de'::uuid as trip \gset
select tests.create_user('c1@example.com', 'Asray') as u1 \gset
select tests.create_user('c2@example.com', 'Anoop') as u2 \gset
select tests.create_user('c3@example.com', 'Asray again') as u3 \gset

select ok(not has_function_privilege('anon', 'public.join_crew_trip(text)', 'execute'), 'anon cannot join');
select is((select count(*)::int from public.trip_participants where trip_id = :'trip'), 4, 'crew trip has four participants');

select tests.authenticate_as(:'u1');
select is(public.join_crew_trip('asray') ->> 'id', :'trip', 'joins by name, case-insensitive');
select ok(public.join_crew_trip('Asray') is not null, 'joining again is idempotent');
select throws_ok($$ select public.join_crew_trip('Mallory') $$, '22023', 'unknown_crew_member', 'unknown names rejected');
select public.create_expense(:'trip', tests.expense_payload('c0ffee00-2026-4000-8000-000000000001', 1000,
  jsonb_build_array(jsonb_build_object('participant_id', 'c0ffee00-2026-4000-8000-000000000001', 'amount_minor', 1000)))) as e \gset

select tests.authenticate_as(:'u2');
select public.join_crew_trip('Anoop') as j \gset
select is(jsonb_array_length(public.list_expenses(:'trip')), 1, 'second crew member sees shared expenses');

-- Reinstall: a new anonymous account claims "Asray" and inherits that participant.
select tests.authenticate_as(:'u3');
select public.join_crew_trip('Asray') as j \gset
select tests.reset_role();
select is((select user_id from public.trip_participants where id = 'c0ffee00-2026-4000-8000-000000000001'), :'u3'::uuid,
  'participant moves to the new account');
select is((select status from public.trip_members where trip_id = :'trip' and user_id = :'u1'), 'left', 'old account membership retired');

select tests.authenticate_as(:'u1');
select throws_ok(format($$ select public.get_trip(%L) $$, :'trip'), '42501', 'not_trip_member', 'old account loses access');

select * from finish();
rollback;
