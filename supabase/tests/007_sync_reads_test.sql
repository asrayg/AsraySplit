begin;
\ir helpers/test_helpers.sql
select plan(9);

select tests.create_user('s1@example.com', 'Sol') as u1 \gset
select tests.create_user('s2@example.com', 'Sky') as u2 \gset
select '99999999-0000-0000-0000-000000000001'::uuid as trip \gset

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'Sync', 'USD') as t \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'u1') as p1 \gset
select public.create_expense(:'trip', tests.expense_payload(:'p1', 100 * g, jsonb_build_array(jsonb_build_object('participant_id', :'p1', 'amount_minor', 100 * g))))
from generate_series(1, 5) g;

select is(jsonb_array_length(public.list_my_trips()), 1, 'member lists own trips');
select is(jsonb_array_length(public.list_expenses(:'trip')), 5, 'lists all expenses');
select is(jsonb_array_length(public.list_expenses(:'trip', null, null, 2)), 2, 'limit respected');
select public.list_expenses(:'trip', null, null, 2) as page1 \gset
select is(jsonb_array_length(public.list_expenses(:'trip', (:'page1'::jsonb -> 1 ->> 'updated_at')::timestamptz, (:'page1'::jsonb -> 1 ->> 'id')::uuid, 10)), 3,
  'keyset pagination continues after cursor');
select public.delete_expense((:'page1'::jsonb -> 0 ->> 'id')::uuid, 1) as d \gset
select ok((select bool_or((e ->> 'deleted_at') is not null) from jsonb_array_elements(public.list_expenses(:'trip')) e), 'tombstones included');
select is((public.get_trip(:'trip') ->> 'id')::uuid, :'trip'::uuid, 'get_trip for member');

select tests.authenticate_as(:'u2');
select is(jsonb_array_length(public.list_my_trips()), 0, 'non-member lists nothing');
select is(jsonb_array_length(public.list_expenses(:'trip')), 0, 'non-member gets no expenses');
select throws_ok(format($$ select public.get_trip(%L) $$, :'trip'), '42501', 'not_trip_member', 'get_trip denied to non-member');

select * from finish();
rollback;
