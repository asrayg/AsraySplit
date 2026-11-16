begin;
\ir helpers/test_helpers.psql
select plan(10);

select 'c0ffee00-2026-4000-8000-00000000c0de'::uuid as trip \gset
select tests.create_user('r1@example.com', 'Asray') as asray \gset
select tests.create_user('r2@example.com', 'Anoop') as anoop \gset
select tests.create_user('r3@example.com', 'Outsider') as outsider \gset
select '99999999-0000-0000-0000-0000000000c1'::uuid as msg \gset
select '99999999-0000-0000-0000-0000000000c2'::uuid as reply \gset

select tests.reset_role();
insert into public.devices (user_id, apns_token, environment, bundle_id) values (:'asray', repeat('c', 64), 'sandbox', 'com.asray.AsraySplit');
select tests.authenticate_as(:'anoop'); select public.join_crew_trip('Anoop') as j \gset
select tests.authenticate_as(:'asray'); select public.join_crew_trip('Asray') as j \gset
select public.post_trip_message(:'trip', :'msg', 'dinner at 8?') as m \gset

select tests.authenticate_as(:'anoop');
select is(public.post_trip_message(:'trip', :'reply', 'yes', null, false, :'msg') ->> 'reply_to', :'msg'::text, 'reply links to original');
select lives_ok(format($$ select public.set_message_reaction(%L, '🔥') $$, :'msg'), 'member reacts');
select lives_ok(format($$ select public.set_message_reaction(%L, '🔥') $$, :'msg'), 'reacting twice is idempotent');
select is((select jsonb_array_length(m -> 'reactions') from jsonb_array_elements(public.list_trip_messages(:'trip')) m where (m ->> 'id')::uuid = :'msg'), 1,
  'list includes one reaction');
select tests.reset_role();
select is((select count(*)::int from public.push_jobs where kind = 'chat_reaction' and user_id = :'asray'), 1, 'sender gets one reaction notification');

select tests.authenticate_as(:'anoop');
select public.set_message_reaction(:'msg', '🔥', false) as off \gset
select is((select count(*)::int from public.trip_message_reactions), 0, 'un-react removes it');
select throws_ok(format($$ select public.set_message_reaction(%L, '') $$, :'msg'), '22023', 'invalid_reaction', 'empty emoji rejected');

select tests.authenticate_as(:'outsider');
select throws_ok(format($$ select public.set_message_reaction(%L, '👍') $$, :'msg'), '42501', 'not_trip_member', 'outsider cannot react');
select is((select count(*)::int from public.trip_message_reactions), 0, 'outsider sees no reactions');

select tests.authenticate_as(:'asray');
select is(public.post_trip_message(:'trip', gen_random_uuid(), 'x', null, false, gen_random_uuid()) ->> 'reply_to', null, 'reply to unknown message is dropped');

select * from finish();
rollback;
