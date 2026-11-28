begin;
\ir helpers/test_helpers.psql
select plan(13);

select 'c0ffee00-2026-4000-8000-00000000c0de'::uuid as trip \gset
select tests.create_user('a@example.com', 'Asray') as asray \gset
select tests.create_user('b@example.com', 'Anoop') as anoop \gset
select tests.create_user('x@example.com', 'Outsider') as outsider \gset

-- Both crew members have a device so pushes fan out.
select tests.reset_role();
insert into public.devices (user_id, apns_token, environment, bundle_id) values
  (:'asray', repeat('a', 64), 'sandbox', 'com.asray.AsraySplit'),
  (:'anoop', repeat('b', 64), 'sandbox', 'com.asray.AsraySplit');

select tests.authenticate_as(:'asray');  select public.join_crew_trip('Asray') as j \gset
select tests.authenticate_as(:'anoop');  select public.join_crew_trip('Anoop') as j \gset

-- Chat → push to everyone except the sender, with readable text.
select public.post_trip_message(:'trip', gen_random_uuid(), 'where u at') as m \gset
select tests.reset_role();
select is((select count(*)::int from public.push_jobs where kind = 'chat_message' and user_id = :'asray'), 1, 'chat notifies the other member');
select is((select count(*)::int from public.push_jobs where kind = 'chat_message' and user_id = :'anoop'), 0, 'sender is not notified');
select is((select payload ->> 'body' from public.push_jobs where kind = 'chat_message'), 'where u at', 'push body is the message');

-- Announcements: only Asray.
select tests.authenticate_as(:'anoop');
select throws_ok(format($$ select public.post_trip_message(%L, gen_random_uuid(), 'hi all', null, true) $$, :'trip'),
  '42501', 'announcements_restricted', 'non-lead cannot announce');
select tests.authenticate_as(:'asray');
select ok((public.post_trip_message(:'trip', gen_random_uuid(), 'Leaving at 7', null, true) ->> 'is_announcement')::boolean, 'Asray can announce');
select tests.reset_role();
select is((select payload ->> 'title' from public.push_jobs where kind = 'announcement' and user_id = :'anoop'), '📣 Asray', 'announcement title');

-- Expense → readable split notification.
select tests.authenticate_as(:'asray');
select public.create_expense(:'trip', tests.expense_payload('c0ffee00-2026-4000-8000-000000000001', 8400,
  jsonb_build_array(jsonb_build_object('participant_id', 'c0ffee00-2026-4000-8000-000000000001', 'amount_minor', 8400)))) as e \gset
select tests.reset_role();
select is((select payload ->> 'body' from public.push_jobs where kind = 'expense_created' and user_id = :'anoop'), 'Asray added Dinner · $84.00',
  'split push names who, what and how much');

-- Photos: a dump of three photos sends one notification.
insert into storage.objects (bucket_id, name, owner_id)
select 'trip-photos', :'trip' || '/' || id || '.jpg', :'anoop' from (values
  ('99999999-0000-0000-0000-0000000000f1'::uuid), ('99999999-0000-0000-0000-0000000000f2'::uuid), ('99999999-0000-0000-0000-0000000000f3'::uuid)) v(id);
select tests.authenticate_as(:'anoop');
select public.register_trip_photo(:'trip', id, 100, 100, 1000) from (values
  ('99999999-0000-0000-0000-0000000000f1'::uuid), ('99999999-0000-0000-0000-0000000000f2'::uuid), ('99999999-0000-0000-0000-0000000000f3'::uuid)) v(id);
select tests.reset_role();
select is((select count(*)::int from public.push_jobs where kind = 'photos_added' and user_id = :'asray'), 1, 'photo dump is one notification');

-- Locations.
select tests.authenticate_as(:'anoop');
select public.update_my_location(:'trip', 18.4655, -66.1057, 10, now()) as l \gset
select public.update_my_location(:'trip', 0, 0, 10, now() - interval '1 hour') as l \gset
select is((select (public.list_member_locations(:'trip') -> 0 ->> 'latitude')::numeric), 18.4655::numeric, 'older queued fix does not overwrite newer one');
select throws_ok(format($$ select public.update_my_location(%L, 91, 0) $$, :'trip'), '22023', 'invalid_location', 'out-of-range rejected');
select tests.authenticate_as(:'outsider');
select is((select count(*)::int from public.member_locations), 0, 'outsiders see no locations');
select throws_ok(format($$ select public.list_member_locations(%L) $$, :'trip'), '42501', 'not_trip_member', 'outsiders cannot list');
select tests.authenticate_as(:'anoop');
select public.stop_sharing_location(:'trip') as s \gset
select is(jsonb_array_length(public.list_member_locations(:'trip')), 0, 'stop sharing removes my location');

select * from finish();
rollback;
