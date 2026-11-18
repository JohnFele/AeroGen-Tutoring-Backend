begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
values ('c3200000-0000-4000-8000-000000000001','mfa.admin@example.test','{}','{}'),
       ('c3200000-0000-4000-8000-000000000002','mfa.learner@example.test','{}','{}');
update public.profiles set role='superUser' where id='c3200000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub','c3200000-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claims','{"sub":"c3200000-0000-4000-8000-000000000001","role":"authenticated"}',true);
do $$ begin
  if private.is_platform_admin() is distinct from false then raise exception 'Missing assurance must fail closed'; end if;
  if exists(select 1 from public.profiles where id='c3200000-0000-4000-8000-000000000002') then
    raise exception 'Admin without MFA can read another profile'; end if;
  begin
    perform public.manage_learning_clearance('c3200000-0000-4000-8000-000000000002','view');
    raise exception 'AAL1 superuser bypassed guardian authorisation';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claims','{"sub":"c3200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal1"}',true);
do $$ begin
  if private.is_platform_admin() is distinct from false then raise exception 'AAL1 admin accepted'; end if;
end $$;

select set_config('request.jwt.claims','{"sub":"c3200000-0000-4000-8000-000000000001","role":"authenticated","aal":"aal2"}',true);
do $$ begin
  if not private.is_platform_admin() then raise exception 'Verified admin rejected'; end if;
  if not exists(select 1 from public.profiles where id='c3200000-0000-4000-8000-000000000002') then
    raise exception 'Verified admin lost profile access'; end if;
  perform public.manage_learning_clearance('c3200000-0000-4000-8000-000000000002','view');
end $$;

select set_config('request.jwt.claim.sub','c3200000-0000-4000-8000-000000000002',true);
select set_config('request.jwt.claims','{"sub":"c3200000-0000-4000-8000-000000000002","role":"authenticated","aal":"aal2","user_metadata":{"role":"superUser"}}',true);
do $$ begin
  if private.is_platform_admin() then raise exception 'MFA or editable metadata granted a student admin rights'; end if;
end $$;
rollback;
