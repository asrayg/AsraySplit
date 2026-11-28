begin;
\ir helpers/test_helpers.psql
select plan(9);

select 'c0ffee00-2026-4000-8000-00000000c0de'::uuid as trip \gset
select tests.create_user('e1@example.com', 'Asray') as asray \gset
select tests.create_user('e2@example.com', 'Anoop') as anoop \gset
select '99999999-0000-0000-0000-0000000000e1'::uuid as msg \gset

select tests.authenticate_as(:'anoop'); select public.join_crew_trip('Anoop') as j \gset
select tests.authenticate_as(:'asray'); select public.join_crew_trip('Asray') as j \gset
select public.post_trip_message(:'trip', :'msg', 'meet at 8') as m \gset
select tests.reset_role();
select count(*)::int as pushes_before from public.push_jobs \gset

select tests.authenticate_as(:'asray');
select is(public.edit_trip_message(:'msg', ' meet at 9 ') ->> 'body', 'meet at 9', 'sender edits');
select ok((select edited_at is not null from public.trip_messages where id = :'msg'), 'edited_at set');
select throws_ok(format($$ select public.edit_trip_message(%L, '   ') $$, :'msg'), '22023', 'invalid_message', 'blank edit rejected');

select tests.authenticate_as(:'anoop');
select throws_ok(format($$ select public.edit_trip_message(%L, 'hacked') $$, :'msg'), '42501', 'not_your_message', 'others cannot edit');
select throws_ok(format($$ select public.delete_trip_message(%L) $$, :'msg'), '42501', 'not_your_message', 'others cannot delete');

select tests.authenticate_as(:'asray');
select ok((public.delete_trip_message(:'msg') ->> 'deleted_at') is not null, 'sender deletes');
select is((select body from public.trip_messages where id = :'msg'), '', 'deleted body is cleared');
select ok((select bool_or((m ->> 'deleted_at') is not null) from jsonb_array_elements(public.list_trip_messages(:'trip')) m), 'tombstone is listed so phones remove it');

select tests.reset_role();
select is((select count(*)::int from public.push_jobs), :'pushes_before', 'edits and deletes send no notifications');

select * from finish();
rollback;
