begin;
\ir helpers/test_helpers.psql
select plan(38);

select tests.create_user('owner@example.com', 'Olivia') as owner \gset
select tests.create_user('friend@example.com', 'Farah') as friend \gset
select tests.create_user('stranger@example.com', 'Sid') as stranger \gset
select 'aaaaaaaa-0000-0000-0000-000000000001'::uuid as trip \gset

-- Profiles are created automatically from auth metadata.
select is((select display_name from public.profiles where id = :'owner'), 'Olivia', 'profile created on sign-up');

-- Anonymous callers cannot create trips.
select tests.as_anon();
select throws_ok($$ select public.create_trip('aaaaaaaa-0000-0000-0000-000000000009', 'x', 'USD') $$, '42501', null, 'anon cannot call create_trip');

select tests.authenticate_as(:'owner');
select lives_ok(format($$ select public.create_trip(%L, 'Lisbon', 'EUR', '🌊', '23C58A', '2026-11-01', '2026-11-08', 'Europe/Lisbon', 150000, array['Guest Gus']) $$, :'trip'),
  'owner creates a trip');
select is((select count(*)::int from public.trips where id = :'trip'), 1, 'owner can read the trip');
select is((select count(*)::int from public.trip_participants where trip_id = :'trip'), 2, 'owner participant + guest participant created');
select is((select role from public.trip_members where trip_id = :'trip' and user_id = :'owner'), 'owner', 'creator is owner');
select is((public.create_trip(:'trip', 'Lisbon', 'EUR') ->> 'name'), 'Lisbon', 'create_trip replay is idempotent');
select throws_ok($$ select public.create_trip('aaaaaaaa-0000-0000-0000-000000000002', 'Bad tz', 'USD', '✈️', '23C58A', null, null, 'Mars/Base') $$,
  '22023', 'invalid_timezone', 'invalid time zone rejected');
select throws_ok($$ select public.create_trip('aaaaaaaa-0000-0000-0000-000000000003', 'Bad ccy', 'XYZ') $$,
  '22023', 'unsupported_currency', 'unknown currency rejected');
select throws_ok($$ insert into public.trips (id, name, base_currency) values (gen_random_uuid(), 'direct', 'USD') $$,
  '42501', null, 'direct trip insert denied');

-- Strangers see nothing and cannot mutate.
select tests.authenticate_as(:'stranger');
select is((select count(*)::int from public.trips where id = :'trip'), 0, 'non-member cannot read trip');
select is((select count(*)::int from public.trip_participants where trip_id = :'trip'), 0, 'non-member cannot read participants');
select is((select count(*)::int from public.activity_events where trip_id = :'trip'), 0, 'non-member cannot read activity');
select is((select count(*)::int from public.profiles where id = :'owner'), 0, 'non-member cannot read owner profile');
select throws_ok(format($$ select public.create_invite(%L) $$, :'trip'), '42501', 'not_trip_member', 'non-member cannot create invite');
select throws_ok(format($$ select public.add_participant(%L, gen_random_uuid(), 'Mallory') $$, :'trip'), '42501', 'not_trip_member', 'non-member cannot add participants');

-- Owner creates an invite; secrets are returned once and stored hashed.
select tests.authenticate_as(:'owner');
select public.create_invite(:'trip', 'member', 24, 1) as invite \gset
select ok((:'invite'::jsonb ->> 'token') is not null and char_length(:'invite'::jsonb ->> 'code') = 8, 'invite returns token and 8-char code');
select tests.reset_role();
select is((select count(*)::int from public.trip_invites where token_hash = extensions.digest(convert_to(:'invite'::jsonb ->> 'token', 'UTF8'), 'sha256')), 1, 'token stored only as hash');

-- Friend previews and joins with the short code (case/dash-insensitive), claiming the guest participant.
select tests.authenticate_as(:'friend');
select is((public.preview_invite(lower(substr(:'invite'::jsonb ->> 'code', 1, 4) || '-' || substr(:'invite'::jsonb ->> 'code', 5))) ->> 'name'), 'Lisbon', 'preview by code');
select (public.preview_invite(:'invite'::jsonb ->> 'token') -> 'claimable_participants' -> 0 ->> 'id') as guest \gset
select is((public.accept_invite(:'invite'::jsonb ->> 'token', :'guest') ->> 'id')::uuid, :'trip'::uuid, 'friend joins via token');
select is((select user_id from public.trip_participants where id = :'guest'), :'friend'::uuid, 'guest participant linked to friend');
select is((select count(*)::int from public.trips where id = :'trip'), 1, 'friend can now read the trip');
select is((select count(*)::int from public.profiles where id = :'owner'), 1, 'co-members can read each other''s profile');
select is((public.accept_invite(:'invite'::jsonb ->> 'token') ->> 'id')::uuid, :'trip'::uuid, 're-accepting as a member is idempotent');
select throws_ok(format($$ select public.create_invite(%L) $$, :'trip'), '42501', 'admin_required', 'members cannot create invites');

-- The single-use invite is now exhausted for anyone else.
select tests.authenticate_as(:'stranger');
select is((public.accept_invite(:'invite'::jsonb ->> 'code') ->> 'error'), 'invite_exhausted', 'exhausted invite rejected');
select is((public.accept_invite('NOTACODE') ->> 'error'), 'invite_invalid', 'unknown code rejected');
select tests.reset_role();
select is((select count(*)::int from private.invite_attempts where user_id = :'stranger' and not succeeded), 1, 'failed attempt recorded for rate limiting');

-- Expired and revoked invites fail safely.
select tests.authenticate_as(:'owner');
select public.create_invite(:'trip', 'member', 1, 5) as expiring \gset
select public.create_invite(:'trip', 'member', 24, 5) as revoked \gset
select lives_ok(format($$ select public.revoke_invite(%L) $$, :'revoked'::jsonb ->> 'id'), 'owner revokes invite');
select tests.reset_role();
update public.trip_invites set expires_at = now() - interval '1 minute' where id = (:'expiring'::jsonb ->> 'id')::uuid;
select tests.authenticate_as(:'stranger');
select is((public.accept_invite(:'expiring'::jsonb ->> 'token') ->> 'error'), 'invite_expired', 'expired invite rejected');
select is((public.accept_invite(:'revoked'::jsonb ->> 'token') ->> 'error'), 'invite_revoked', 'revoked invite rejected');
select is((select count(*)::int from public.trips where id = :'trip'), 0, 'failed joins grant no access');

-- Brute force protection.
select tests.reset_role();
insert into private.invite_attempts (user_id, succeeded) select :'stranger', false from generate_series(1, 25);
select tests.authenticate_as(:'stranger');
select throws_ok($$ select public.preview_invite('ZZZZZZZZ') $$, 'PT429', 'rate_limited', 'invite guessing is rate limited');

-- Removing a member immediately removes access but keeps their participant label.
select tests.authenticate_as(:'owner');
select lives_ok(format($$ select public.remove_member(%L, %L) $$, :'trip', :'friend'), 'owner removes friend');
select tests.authenticate_as(:'friend');
select is((select count(*)::int from public.trips where id = :'trip'), 0, 'removed member loses read access');
select throws_ok(format($$ select public.add_participant(%L, gen_random_uuid(), 'X') $$, :'trip'), '42501', 'not_trip_member', 'removed member cannot write');
select tests.authenticate_as(:'owner');
select is((select display_name from public.trip_participants where id = :'guest'), 'Guest Gus', 'historical participant label retained');

-- Owners must transfer before leaving.
select throws_ok(format($$ select public.leave_trip(%L) $$, :'trip'), 'PT409', 'owner_must_transfer', 'owner cannot leave without transferring');

select * from finish();
rollback;
