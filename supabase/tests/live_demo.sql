-- Run inside a transaction after the optional demo fixture.
do $$ begin
  if (select count(*) from public.profiles where demo_dataset='aerogen-live-demo-v1') <> 11 then raise exception 'Expected 11 demo profiles'; end if;
  if (select count(*) from public.tutor_profiles where demo_dataset='aerogen-live-demo-v1') <> 5 then raise exception 'Expected 5 demo tutors'; end if;
  if (select count(*) from public.bookings b join public.profiles p on p.id=b.student_id where p.demo_dataset='aerogen-live-demo-v1') <> 12 then raise exception 'Expected 12 demo bookings'; end if;
  if exists(select 1 from public.profiles p where p.demo_dataset='aerogen-live-demo-v1' and p.role not in ('student','tutor')) then raise exception 'Demo accounts must not have elevated roles'; end if;
  if has_column_privilege('authenticated','public.profiles','demo_dataset','UPDATE') then raise exception 'Demo marker must not be user editable'; end if;
end $$;
set local role anon;
do $$ begin
  if exists(select 1 from public.tutor_profiles where demo_dataset is not null) then raise exception 'Demo tutors leaked to public discovery'; end if;
  if exists(select 1 from public.reviews where body like '[DEMO]%') then raise exception 'Demo reviews leaked to public discovery'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000101',true);
set local role authenticated;
do $$ begin
  if (select count(*) from public.profiles) <> 1 then raise exception 'Demo student can read other private profiles'; end if;
  if (select count(*) from public.bookings) <> 3 then raise exception 'Demo primary student booking scope is wrong'; end if;
  if (select count(*) from public.payments) <> 3 then raise exception 'Demo primary student payment scope is wrong'; end if;
  if (select count(*) from public.messages) <> 3 then raise exception 'Demo primary student message scope is wrong'; end if;
  if (select count(*) from public.notifications) <> 1 then raise exception 'Demo primary student notification scope is wrong'; end if;
  if (select count(*) from public.tutor_profiles where demo_dataset='aerogen-live-demo-v1') <> 4 then raise exception 'Demo students should discover four approved demo tutors'; end if;
  if exists(select 1 from public.bookings where student_id='de000000-0000-4000-8000-000000000103') then raise exception 'Cross-student booking leak'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000106',true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.bookings) or exists(select 1 from public.messages) or exists(select 1 from public.notifications) then raise exception 'New student should have an empty workspace'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000205',true);
set local role authenticated;
do $$ begin
  if (select count(*) from public.tutor_profiles where user_id=(select auth.uid()) and not is_approved) <> 1 then raise exception 'Pending tutor cannot see own profile'; end if;
  if (select count(*) from public.tutor_subjects where tutor_id=(select auth.uid())) <> 2 then raise exception 'Pending tutor cannot see own subjects'; end if;
  if (select count(*) from public.tutor_applications) <> 1 then raise exception 'Pending tutor application scope failed'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000099',true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.tutor_profiles where demo_dataset is not null) then raise exception 'Demo tutors leaked to non-demo identity'; end if;
  if exists(select 1 from public.messages) or exists(select 1 from public.bookings) then raise exception 'Unrelated identity can read demo activity'; end if;
end $$;
reset role;
