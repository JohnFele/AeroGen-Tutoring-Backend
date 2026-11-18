begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
values ('c3100000-0000-4000-8000-000000000001','security.student@example.test','{"role":"superUser"}','{}'),
       ('c3100000-0000-4000-8000-000000000002','security.hidden@example.test','{}','{}'),
       ('c3100000-0000-4000-8000-000000000003','security.public@example.test','{}','{}');
update public.profiles set role='tutor' where id in ('c3100000-0000-4000-8000-000000000002','c3100000-0000-4000-8000-000000000003');
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate)
values ('c3100000-0000-4000-8000-000000000002','Hidden security fixture',false,false,200),
       ('c3100000-0000-4000-8000-000000000003','Public security fixture',true,true,200);

set local role anon;
do $$ begin
  if not exists(select 1 from public.tutor_directory where id='c3100000-0000-4000-8000-000000000003') then
    raise exception 'Anonymous tutor discovery is broken'; end if;
  if exists(select 1 from public.tutor_directory where id='c3100000-0000-4000-8000-000000000002') then
    raise exception 'Unapproved tutor leaked through directory'; end if;
  begin
    perform * from public.profiles;
    raise exception 'Anonymous profiles must not be readable';
  exception when insufficient_privilege then null; end;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','c3100000-0000-4000-8000-000000000001',true);
do $$ begin
  if (select role from public.profiles where id=auth.uid()) <> 'student' then
    raise exception 'Signup metadata elevated privileges'; end if;
  if exists(select 1 from public.profiles where id<>auth.uid()) then
    raise exception 'Another account profile is visible to a student'; end if;
  if exists(select 1 from public.tutor_directory where id='c3100000-0000-4000-8000-000000000002') then
    raise exception 'Unapproved tutor is visible to a student'; end if;
  begin
    update public.profiles set role='superUser' where id=auth.uid();
    raise exception 'Student must not change their platform role';
  exception when insufficient_privilege then null; end;
  update public.profiles set first_name='Forbidden edit' where id='c3100000-0000-4000-8000-000000000002';
  if found then raise exception 'A student changed another account'; end if;
end $$;
rollback;
