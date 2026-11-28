begin;
\ir helpers/test_helpers.psql
select plan(11);

select tests.create_user('p1@example.com', 'Asray') as u1 \gset
select tests.create_user('p2@example.com', 'Anoop') as u2 \gset
select '99999999-0000-0000-0000-0000000000bb'::uuid as trip \gset
select '99999999-0000-0000-0000-0000000000b1'::uuid as photo \gset

select ok(not has_table_privilege('authenticated', 'public.trip_photos', 'insert')
       and not has_table_privilege('authenticated', 'public.trip_photos', 'delete'), 'authenticated cannot write photo rows directly');
select ok(not has_function_privilege('anon', 'public.list_trip_photos(uuid)', 'execute'), 'anon cannot list photos');
select is(private.photo_path_trip(:'trip' || '/' || :'photo' || '.jpg'), :'trip'::uuid, 'valid photo path maps to trip');
select is(private.photo_path_trip('../x/' || :'photo' || '.jpg'), null, 'malformed path maps to nothing');

select tests.authenticate_as(:'u1');
select public.create_trip(:'trip', 'PR', 'USD') as t \gset
select throws_ok(format($$ select public.register_trip_photo(%L, %L, 100, 100, 1000) $$, :'trip', :'photo'), '22023', 'photo_not_uploaded',
  'cannot register a photo that was not uploaded');

-- Simulate the storage upload.
select tests.reset_role();
insert into storage.objects (bucket_id, name, owner_id) values ('trip-photos', :'trip' || '/' || :'photo' || '.jpg', :'u1');
select tests.authenticate_as(:'u1');

select is(public.register_trip_photo(:'trip', :'photo', 2048, 1536, 500000) ->> 'uploader_name', 'Asray', 'member registers photo');
select is(public.register_trip_photo(:'trip', :'photo', 2048, 1536, 500000) ->> 'id', :'photo', 'registration is idempotent');
select is(jsonb_array_length(public.list_trip_photos(:'trip')), 1, 'member lists photos');

select tests.authenticate_as(:'u2');
select is((select count(*)::int from public.trip_photos), 0, 'non-member reads no photo rows');
select throws_ok(format($$ select public.list_trip_photos(%L) $$, :'trip'), '42501', 'not_trip_member', 'non-member cannot list');
select throws_ok(format($$ select public.delete_trip_photo(%L) $$, :'photo'), '42501', 'not_trip_member', 'non-member cannot delete');

select * from finish();
rollback;
