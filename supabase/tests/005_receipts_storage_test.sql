begin;
\ir helpers/test_helpers.sql
select plan(17);

select tests.create_user('r1@example.com', 'Rae') as u1 \gset
select tests.create_user('r2@example.com', 'Rio') as u2 \gset
select 'dddddddd-0000-0000-0000-000000000001'::uuid as trip \gset
select 'eeeeeeee-0000-0000-0000-000000000001'::uuid as rid \gset
select 'eeeeeeee-0000-0000-0000-000000000002'::uuid as rid2 \gset

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'Receipts', 'USD') as t \gset

-- Storage policies: members may upload into their trip folder only.
select lives_ok(format($$ insert into storage.objects (bucket_id, name, owner_id) values ('receipts', '%s/%s.jpg', %L) $$, :'trip', :'rid', :'u1'),
  'member uploads into trip folder');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner_id) values ('receipts', '%s/%s.jpg', %L) $$, gen_random_uuid(), :'rid', :'u1'),
  '42501', null, 'upload into another trip folder denied');
select throws_ok(format($$ insert into storage.objects (bucket_id, name, owner_id) values ('receipts', '../%s.jpg', %L) $$, :'rid', :'u1'),
  '42501', null, 'malformed path denied');

select public.register_receipt(jsonb_build_object('id', :'rid', 'trip_id', :'trip', 'object_path', :'trip' || '/' || :'rid' || '.jpg',
  'mime_type', 'image/jpeg', 'byte_size', 120000, 'width', 1200, 'height', 2400, 'sha256', repeat('a', 64), 'perceptual_hash', 'ffff0000ffff0000')) as r1 \gset
select is(jsonb_array_length(:'r1'::jsonb -> 'duplicates'), 0, 'first receipt has no duplicates');
select throws_ok(format($$ select public.register_receipt(jsonb_build_object('id', %L, 'trip_id', %L, 'object_path', '%s/other.jpg', 'mime_type', 'image/jpeg', 'byte_size', 1, 'sha256', repeat('b', 64))) $$, :'rid2', :'trip', :'trip'),
  '42501', 'invalid_receipt_path', 'path must match receipt id');
select throws_ok(format($$ select public.register_receipt(jsonb_build_object('id', %L, 'trip_id', %L, 'object_path', '%s/%s.jpg', 'mime_type', 'image/png', 'byte_size', 1, 'sha256', repeat('b', 64))) $$, :'rid2', :'trip', :'trip', :'rid2'),
  '22023', 'invalid_receipt_type', 'mime type must match extension');
select public.register_receipt(jsonb_build_object('id', :'rid2', 'trip_id', :'trip', 'object_path', :'trip' || '/' || :'rid2' || '.jpg',
  'mime_type', 'image/jpeg', 'byte_size', 120000, 'sha256', repeat('c', 64), 'perceptual_hash', 'ffff0000ffff0000')) as r2 \gset
select is((:'r2'::jsonb -> 'duplicates' -> 0 ->> 'receipt_id')::uuid, :'rid'::uuid, 'perceptual duplicate detected');

-- Non-members cannot see receipt rows or objects.
select tests.authenticate_as(:'u2');
select is((select count(*)::int from public.receipts where trip_id = :'trip'), 0, 'non-member cannot read receipt rows');
select is((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'non-member cannot read receipt objects');
select throws_ok(format($$ select public.begin_receipt_scan(%L) $$, :'rid'), '42501', 'not_trip_member', 'non-member cannot scan');
select throws_ok(format($$ select public.delete_receipt(%L) $$, :'rid'), '42501', 'not_trip_member', 'non-member cannot delete receipt');

-- Scan bookkeeping + quota.
select tests.authenticate_as(:'u1');
select public.begin_receipt_scan(:'rid') as scan \gset
select is((select scan_status from public.receipts where id = :'rid'), 'processing', 'scan marks receipt processing');
select throws_ok($$ select public.complete_receipt_scan(null, null, 'succeeded', '{}', 'm', 1, 1, 1, null) $$, '42501', null, 'users cannot complete scans');
select tests.as_service();
select lives_ok(format($$ select public.complete_receipt_scan(%L, %L, 'succeeded', '{"merchant": "Cafe"}', 'test-model', 900, 1000, 200, null) $$, :'rid', :'scan'::jsonb ->> 'usage_id'),
  'service role completes scan');
select tests.reset_role();
insert into public.ai_usage (user_id, outcome) select :'u1', 'succeeded' from generate_series(1, 30);
select tests.authenticate_as(:'u1');
select throws_ok(format($$ select public.begin_receipt_scan(%L) $$, :'rid2'), 'PT429', 'scan_quota_exceeded', 'per-user daily scan quota enforced');

-- Deleting a receipt hides it and queues the private object for removal.
select lives_ok(format($$ select public.delete_receipt(%L) $$, :'rid'), 'uploader deletes receipt');
select tests.reset_role();
select is((select count(*)::int from private.storage_cleanup_queue where object_path = :'trip' || '/' || :'rid' || '.jpg'), 1, 'object queued for deletion');

select * from finish();
rollback;
