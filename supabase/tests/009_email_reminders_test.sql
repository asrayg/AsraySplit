begin;
\ir helpers/test_helpers.psql
select plan(11);

select tests.create_user('em1@example.com', 'Maya') as creditor \gset
select tests.create_user('em2@example.com', 'Sam') as debtor \gset
select tests.create_user('em3@example.com', 'Out') as outsider \gset
select '77777777-0000-0000-0000-000000000001'::uuid as trip \gset

select tests.authenticate_as(:'creditor');
select public.create_trip(:'trip', 'Porto', 'EUR', '🍷', '23C58A', '2026-09-01', '2026-09-05', 'Europe/Lisbon') as t \gset
select public.create_invite(:'trip') as inv \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'creditor') as pc \gset
select tests.authenticate_as(:'debtor');
select public.accept_invite(:'inv'::jsonb ->> 'token') as j \gset
select (select id from public.trip_participants where trip_id = :'trip' and user_id = :'debtor') as pd \gset
select tests.authenticate_as(:'creditor');
select public.create_expense(:'trip', tests.expense_payload(:'pc', 8000, jsonb_build_array(
  jsonb_build_object('participant_id', :'pc', 'amount_minor', 4000), jsonb_build_object('participant_id', :'pd', 'amount_minor', 4000)), 'EUR')) as e \gset

-- Remind button
select is((public.request_payment_reminder(:'trip', :'pd') ->> 'queued')::boolean, true, 'creditor can remind debtor');
select is((public.request_payment_reminder(:'trip', :'pd') ->> 'reason'), 'already_reminded_today', 'one reminder per day');
select tests.reset_role();
select is((select (data ->> 'amount_minor')::bigint from public.email_jobs where kind = 'payment_request'), 4000::bigint, 'job captures amount owed');
select is((select data -> 'pay_to' -> 0 ->> 'name' from public.email_jobs where kind = 'payment_request'), 'Maya', 'job says who to pay');
select is((select user_id from public.email_jobs where kind = 'payment_request'), :'debtor'::uuid, 'email goes to the debtor');

select tests.authenticate_as(:'debtor');
select throws_ok(format($$ select public.request_payment_reminder(%L, %L) $$, :'trip', :'pc'), 'PT409', 'nothing_owed', 'cannot remind someone who owes you nothing');
select tests.authenticate_as(:'outsider');
select throws_ok(format($$ select public.request_payment_reminder(%L, %L) $$, :'trip', :'pd'), '42501', 'not_trip_member', 'outsiders cannot send reminders');
select throws_ok($$ select * from public.email_jobs $$, '42501', null, 'email jobs are not readable by users');

-- Daily settle-up reminders for an ended trip
select tests.reset_role();
select is(public.enqueue_settle_up_reminders(), 1, 'debtor in an ended trip is queued');
select is(public.enqueue_settle_up_reminders(), 0, 'not queued again within 3 days');

-- Opt-out
select public.disable_email_reminders(:'debtor');
delete from public.email_jobs;
select tests.authenticate_as(:'creditor');
select is((public.request_payment_reminder(:'trip', :'pd') ->> 'reason'), 'opted_out', 'opted-out users get no reminder emails');

select * from finish();
rollback;
