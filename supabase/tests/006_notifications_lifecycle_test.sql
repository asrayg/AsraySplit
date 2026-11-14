begin;
\ir helpers/test_helpers.psql
select plan(16);

select tests.create_user('n1@example.com', 'Nia') as u1 \gset
select tests.create_user('n2@example.com', 'Noa') as u2 \gset
select tests.create_user('n3@example.com', 'Ned') as u3 \gset
select 'ffffffff-0000-0000-0000-000000000001'::uuid as trip \gset
select 'ffffffff-0000-0000-0000-000000000002'::uuid as solo \gset

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'Shared', 'USD') as t \gset
select public.create_trip(:'solo', 'Solo', 'USD') as s \gset
select public.create_invite(:'trip', 'member', 24, 10) as inv \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'u1') as p1 \gset
select tests.authenticate_as(:'u2');
select public.accept_invite(:'inv'::jsonb ->> 'token') as j \gset
select public.register_device(repeat('ab', 32), 'sandbox', 'com.asray.AsraySplit', '1.0', 'en_US', 'America/New_York') as d \gset
select tests.authenticate_as(:'u3');
select public.accept_invite(:'inv'::jsonb ->> 'token') as j3 \gset
select public.register_device(repeat('cd', 32), 'sandbox', 'com.asray.AsraySplit') as d3 \gset

-- u3 mutes this trip.
insert into public.trip_notification_settings (user_id, trip_id, muted) values (:'u3', :'trip', true);
select throws_ok(format($$ insert into public.trip_notification_settings (user_id, trip_id, muted) values (%L, %L, true) $$, :'u2', :'trip'),
  '42501', null, 'cannot write another user''s notification settings');

-- u1 adds an expense -> u2 gets exactly one push job; actor and muted user get none.
select tests.authenticate_as(:'u1');
select public.create_expense(:'trip', tests.expense_payload(:'p1', 4200, jsonb_build_array(jsonb_build_object('participant_id', :'p1', 'amount_minor', 4200)))) as e \gset
select tests.reset_role();
select is((select count(*)::int from public.push_jobs where user_id = :'u2' and kind = 'expense_created'), 1, 'other member gets one push job');
select is((select count(*)::int from public.push_jobs where user_id = :'u1'), 0, 'actor gets no push');
select is((select count(*)::int from public.push_jobs where user_id = :'u3'), 0, 'muted member gets no push');
select ok(not ((select payload from public.push_jobs where user_id = :'u2' limit 1) ? 'amount_minor'), 'push payload carries no amounts');

-- Replaying the same activity cannot double-enqueue.
select is((select count(*)::int from public.push_jobs where dedupe_key like 'activity:%'), (select count(distinct dedupe_key)::int from public.push_jobs), 'dedupe keys unique');

-- Users never see another trip's notifications: push_jobs are not readable at all.
select tests.authenticate_as(:'u2');
select throws_ok($$ select * from public.push_jobs $$, '42501', null, 'push jobs not readable by users');
select is((select count(*)::int from public.devices), 1, 'users see only their own devices');

-- Device token moves to whoever registers it last.
select tests.authenticate_as(:'u3');
select public.register_device(repeat('ab', 32), 'sandbox', 'com.asray.AsraySplit') as moved \gset
select tests.reset_role();
select is((select user_id from public.devices where apns_token = repeat('ab', 32)), :'u3'::uuid, 'token reassigned to new user');

-- Service role claims due jobs exactly once.
select tests.as_service();
select is((select count(*)::int from public.claim_push_jobs(10)), 1, 'dispatcher claims due jobs (expense; joins no longer notify in the crew build)');
select is((select count(*)::int from public.claim_push_jobs(10)), 0, 'claimed job not handed out twice');

-- Export returns the caller's data.
select tests.authenticate_as(:'u2');
select is(jsonb_array_length(public.export_my_data() -> 'trips'), 1, 'export contains the member''s trips only');

-- Account deletion: shared trip goes to the remaining member, solo trip is deleted, labels anonymized.
select tests.authenticate_as(:'u1');
select public.prepare_account_deletion() as del \gset
select is((:'del'::jsonb ->> 'trips_deleted')::int, 1, 'solo trip deleted');
select is((:'del'::jsonb ->> 'trips_transferred')::int, 1, 'shared trip transferred');
select tests.reset_role();
select is((select owner_id from public.trips where id = :'trip'), :'u2'::uuid, 'longest-standing member becomes owner');
select is((select display_name from public.trip_participants where id = :'p1'), 'Former traveler', 'deleted user''s participant anonymized');

select * from finish();
rollback;
