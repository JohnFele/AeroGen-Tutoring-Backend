-- Transaction-only integration checks; all edits/messages are rolled back.
set local role anon;
do $$ begin
  if (select count(*) from public.tutor_directory where demo_dataset='aerogen-live-demo-v1')<>4 then raise exception 'Approved database tutors must be public'; end if;
  if exists(select 1 from public.tutor_directory where id='de000000-0000-4000-8000-000000000205') then raise exception 'Pending tutor leaked'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000101',true);
set local role authenticated;
do $$ begin
  begin perform public.admin_update_tutor('de000000-0000-4000-8000-000000000201','{"is_featured":false}'); raise exception 'Student was allowed to administer tutors'; exception when insufficient_privilege then null; end;
  if jsonb_array_length(public.my_tutoring_workspace()->'bookings')<>3 then raise exception 'Workspace booking scope failed'; end if;
  if public.my_tutoring_workspace()::text like '%@example.test%' then raise exception 'Workspace leaked private contact emails'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role in ('admin','superUser') order by id limit 1),true);
set local role authenticated;
do $$ declare stamp timestamptz; begin
  if not private.is_platform_admin() then raise exception 'Admin fixture is unavailable'; end if;
  if (select count(*) from public.tutor_profiles where demo_dataset='aerogen-live-demo-v1')<>5 then raise exception 'Admin must see pending tutors'; end if;
  select updated_at into stamp from public.tutor_profiles where user_id='de000000-0000-4000-8000-000000000201';
  perform public.admin_update_tutor('de000000-0000-4000-8000-000000000201','{"public_name":"Demo Maths Tutor — transaction test","is_featured":false}',null,stamp);
  if not exists(select 1 from public.tutor_directory where id='de000000-0000-4000-8000-000000000201' and public_name like '%transaction test' and not is_featured) then raise exception 'Saved edits did not reach discovery'; end if;
  if not exists(select 1 from public.tutor_profile_audit where tutor_id='de000000-0000-4000-8000-000000000201' and actor_id=(select auth.uid())) then raise exception 'Edit audit missing'; end if;
  begin perform public.admin_update_tutor('de000000-0000-4000-8000-000000000201','{"bio":"stale"}',null,stamp-interval '1 microsecond'); raise exception 'Stale update was accepted'; exception when sqlstate 'PT409' then null; end;
  begin perform public.admin_update_tutor('de000000-0000-4000-8000-000000000201','{}',array[999999999]::bigint[]); raise exception 'Invalid subject accepted'; exception when invalid_parameter_value then null; end;
  perform public.admin_update_tutor('de000000-0000-4000-8000-000000000205','{"is_approved":true,"is_accepting_students":true,"is_featured":true}');
  if not exists(select 1 from public.tutor_directory where id='de000000-0000-4000-8000-000000000205' and is_featured) then raise exception 'Approved pending tutor did not publish'; end if;
  perform public.admin_update_tutor('de000000-0000-4000-8000-000000000205','{"is_approved":false}');
  if exists(select 1 from public.tutor_directory where id='de000000-0000-4000-8000-000000000205') then raise exception 'Unapproved tutor remained public'; end if;
  if exists(select 1 from public.tutor_profiles where user_id='de000000-0000-4000-8000-000000000205' and is_featured) then raise exception 'Unapproved tutor stayed featured'; end if;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000103',true);
set local role authenticated;
do $$ declare own_conversation uuid; begin
  select conversation_id into own_conversation from public.conversation_members where user_id=(select auth.uid()) limit 1;
  perform public.send_tutoring_message(own_conversation,'Transaction-only integration test');
  if not exists(select 1 from public.messages where conversation_id=own_conversation and sender_id=(select auth.uid()) and body='Transaction-only integration test') then raise exception 'Message did not persist in transaction'; end if;
  begin perform public.send_tutoring_message('00000000-0000-4000-8000-000000000099','Forbidden'); raise exception 'Unrelated conversation was writable'; exception when insufficient_privilege then null; end;
end $$;
reset role;
