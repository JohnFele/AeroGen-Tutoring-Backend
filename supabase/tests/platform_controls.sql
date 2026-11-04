begin;
-- All flag changes, audit records and generated records roll back. No emails are sent.
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare v integer; snapshot jsonb; begin
  select version into v from public.platform_settings where id;
  snapshot=public.update_platform_settings('{"applications":false,"student_registration":false,"maintenance":false,"admin_email_notifications":false}',v);
  if (snapshot->>'version')::integer<>v+1 then raise exception 'Version did not advance'; end if;
  if not exists(select 1 from public.platform_settings_audit where actor_id=(select auth.uid()) and new_settings->>'version'=(v+1)::text) then raise exception 'Audit missing'; end if;
  begin perform public.update_platform_settings('{"applications":true,"student_registration":true,"maintenance":false,"admin_email_notifications":true}',v);raise exception 'Stale settings accepted';exception when sqlstate 'PT409' then null;end;
end; $$;
reset role;
do $$ begin
  begin insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values(gen_random_uuid(),'platform-sql@example.test','{"role":"admin"}','{}');raise exception 'Registration pause bypassed';exception when sqlstate 'P0001' then if sqlerrm not like 'New account registration%' then raise; end if;end;
  begin insert into public.tutor_applications(user_id,first_name,contact_email,status) values('de000000-0000-4000-8000-000000000106','Platform SQL','platform-sql@example.test','submitted');raise exception 'Application pause bypassed';exception when sqlstate 'PT403' then null;end;
end; $$;
select set_config('request.jwt.claims','{"sub":"de000000-0000-4000-8000-000000000106","role":"authenticated"}',true);
set local role authenticated;
do $$ begin
  begin update public.platform_settings set maintenance=false where id;raise exception 'Raw settings update allowed';exception when insufficient_privilege then null;end;
  begin perform public.update_platform_settings('{"applications":true,"student_registration":true,"maintenance":false,"admin_email_notifications":true}',1);raise exception 'Student settings change allowed';exception when insufficient_privilege then null;end;
  if exists(select 1 from public.platform_settings_audit) then raise exception 'Student can read admin audit'; end if;
end; $$;
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select id from public.profiles where role in ('admin','superUser') order by id limit 1),'role','authenticated')::text,true);
set local role authenticated;
do $$ declare v integer; begin
  select version into v from public.platform_settings where id;
  perform public.update_platform_settings('{"applications":false,"student_registration":false,"maintenance":true,"admin_email_notifications":false}',v);
  if not private.platform_runtime_allowed() then raise exception 'Admin locked out during maintenance'; end if;
  if not exists(select 1 from public.site_faqs) then raise exception 'Admin cannot read content during maintenance'; end if;
end; $$;
reset role;
select set_config('request.jwt.claims','{"sub":"de000000-0000-4000-8000-000000000106","role":"authenticated"}',true);
set local role authenticated;
do $$ begin
  if not exists(select 1 from public.profiles where id=(select auth.uid())) then raise exception 'Identity bootstrap blocked'; end if;
  if exists(select 1 from public.site_faqs) then raise exception 'Maintenance read bypassed'; end if;
  update public.profiles set bio='Maintenance bypass' where id=(select auth.uid());if found then raise exception 'Profile maintenance write bypassed'; end if;
  begin perform public.my_tutoring_workspace();raise exception 'Workspace maintenance bypassed';exception when sqlstate 'PT503' then null;end;
  begin perform public.send_tutoring_message(gen_random_uuid(),'Blocked maintenance message');raise exception 'Message maintenance bypassed';exception when sqlstate 'PT503' then null;end;
  begin insert into storage.objects(bucket_id,name) values('tutor-application-documents',(select auth.uid())::text||'/test/blocked.pdf');raise exception 'Storage maintenance bypassed';exception when insufficient_privilege then null;end;
end; $$;
reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
do $$ begin
  if not exists(select 1 from public.platform_settings where maintenance) then raise exception 'Public status unavailable'; end if;
  if not exists(select 1 from public.site_contact_settings) then raise exception 'Contact information unavailable'; end if;
  if exists(select 1 from public.tutor_directory) then raise exception 'Directory maintenance bypassed'; end if;
  begin perform public.submit_contact_enquiry(gen_random_uuid(),'Platform','Test','platform-sql@example.test','general','This enquiry must be denied during maintenance.');raise exception 'Enquiry maintenance bypassed';exception when sqlstate 'PT503' then null;end;
end; $$;
reset role;
rollback;
