begin;
\ir helpers/test_helpers.psql
select plan(4);

select tests.create_user('ar1@example.com', 'Ari') as u1 \gset
select tests.create_user('ar2@example.com', 'Bo') as u2 \gset
select '88888888-0000-0000-0000-000000000001'::uuid as trip, '88888888-0000-0000-0000-000000000002'::uuid as other,
       '88888888-0000-0000-0000-0000000000a1'::uuid as rid \gset
select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'Attach', 'USD') as t \gset
select public.create_trip(:'other', 'Other', 'USD') as o \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'u1') as p1 \gset
select (select id from public.trip_participants where trip_id = :'other' and user_id = :'u1') as p2 \gset
select public.create_expense(:'trip', tests.expense_payload(:'p1', 500, jsonb_build_array(jsonb_build_object('participant_id', :'p1', 'amount_minor', 500)))) as e \gset
select public.create_expense(:'other', tests.expense_payload(:'p2', 500, jsonb_build_array(jsonb_build_object('participant_id', :'p2', 'amount_minor', 500)))) as e2 \gset
select public.register_receipt(jsonb_build_object('id', :'rid', 'trip_id', :'trip', 'object_path', :'trip' || '/' || :'rid' || '.jpg',
  'mime_type', 'image/jpeg', 'byte_size', 10, 'sha256', repeat('d', 64))) as r \gset

select is((public.attach_receipt(:'rid', (:'e'::jsonb ->> 'id')::uuid) -> 'receipt_ids' ->> 0)::uuid, :'rid'::uuid, 'returns canonical expense with the receipt');
select is((select expense_id from public.receipts where id = :'rid'), (:'e'::jsonb ->> 'id')::uuid, 'receipt attached');
select throws_ok(format($$ select public.attach_receipt(%L, %L) $$, :'rid', :'e2'::jsonb ->> 'id'), 'PT404', 'not_found', 'cannot attach across trips');
select tests.authenticate_as(:'u2');
select throws_ok(format($$ select public.attach_receipt(%L, %L) $$, :'rid', :'e'::jsonb ->> 'id'), '42501', 'not_trip_member', 'non-member cannot attach');

select * from finish();
rollback;
