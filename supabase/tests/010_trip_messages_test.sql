begin;
\ir helpers/test_helpers.psql
select plan(12);

select tests.create_user('m1@example.com', 'Asray') as u1 \gset
select tests.create_user('m2@example.com', 'Anoop') as u2 \gset
select '99999999-0000-0000-0000-0000000000aa'::uuid as trip \gset
select '99999999-0000-0000-0000-0000000000a1'::uuid as msg \gset

-- Grants: authenticated may only read; anon nothing.
select ok(not has_table_privilege('authenticated', 'public.trip_messages', 'insert')
       and not has_table_privilege('authenticated', 'public.trip_messages', 'update')
       and not has_table_privilege('authenticated', 'public.trip_messages', 'delete'), 'authenticated cannot write messages directly');
select ok(not has_table_privilege('anon', 'public.trip_messages', 'select'), 'anon cannot read messages');
select ok(not has_function_privilege('anon', 'public.post_trip_message(uuid, uuid, text, timestamptz)', 'execute'), 'anon cannot post');

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'PR', 'USD') as t \gset

select is(public.post_trip_message(:'trip', :'msg', '  hola  ') ->> 'body', 'hola', 'member posts (trimmed)');
select is(public.post_trip_message(:'trip', :'msg', 'different') ->> 'body', 'hola', 'reposting the same id is idempotent');
select is((select count(*)::int from public.trip_messages where trip_id = :'trip'), 1, 'stored once');
select lives_ok(format($$ select public.post_trip_message(%L, gen_random_uuid(), 'future', now() + interval '1 day') $$, :'trip'), 'future client timestamp accepted');
select ok((select max(sent_at) <= now() from public.trip_messages where trip_id = :'trip'), 'future client clocks are clamped');
select throws_ok(format($$ select public.post_trip_message(%L, gen_random_uuid(), '   ') $$, :'trip'), '22023', 'invalid_message', 'blank message rejected');

-- Non-member sees nothing and cannot post or hijack an id.
select tests.authenticate_as(:'u2');
select is((select count(*)::int from public.trip_messages), 0, 'non-member reads no messages');
select throws_ok(format($$ select public.post_trip_message(%L, gen_random_uuid(), 'hi') $$, :'trip'), '42501', 'not_trip_member', 'non-member cannot post');
select throws_ok(format($$ select public.list_trip_messages(%L) $$, :'trip'), '42501', 'not_trip_member', 'non-member cannot list');

select * from finish();
rollback;
