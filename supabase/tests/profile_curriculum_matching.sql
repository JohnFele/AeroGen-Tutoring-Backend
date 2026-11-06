begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
select ('d6210000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'curriculum-'||i||'@example.test','{}','{}'
from generate_series(1,4) as fixtures(i);
update public.profiles set role='tutor' where id in
  ('d6210000-0000-4000-8000-000000000002','d6210000-0000-4000-8000-000000000003');
update public.profiles set demo_dataset='curriculum-demo' where id in
  ('d6210000-0000-4000-8000-000000000003','d6210000-0000-4000-8000-000000000004');
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,demo_dataset)
values ('d6210000-0000-4000-8000-000000000002','Curriculum Tutor',true,true,null),
       ('d6210000-0000-4000-8000-000000000003','Demo Curriculum Tutor',true,true,'curriculum-demo');
update public.profiles set curriculum_codes=array['caps-sacai'] where id='d6210000-0000-4000-8000-000000000003';

set local role authenticated;
select set_config('request.jwt.claim.sub','d6210000-0000-4000-8000-000000000001',true);
update public.profiles set curriculum_codes=array['caps-ieb'] where id=auth.uid();
do $$
begin
  if (select curriculum_codes from public.profiles where id=auth.uid()) is distinct from array['caps-ieb'] then
    raise exception 'The learner selection was not saved';
  end if;
  begin
    update public.profiles set curriculum_codes=array['caps-ieb','caps-dbe'] where id=auth.uid();
    raise exception 'Multiple curricula were accepted for a learner';
  exception when invalid_parameter_value then null;
  end;
  begin
    update public.profiles set curriculum_codes=array['missing-pathway'] where id=auth.uid();
    raise exception 'An unknown pathway was accepted';
  exception when invalid_parameter_value then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub','d6210000-0000-4000-8000-000000000002',true);
update public.profiles set curriculum_codes=array['caps-ieb','cambridge-igcse'] where id=auth.uid();
do $$
begin
  if exists (select 1 from public.profiles where id='d6210000-0000-4000-8000-000000000001')
    or private.directory_tutor_curricula('d6210000-0000-4000-8000-000000000001') <> '{}'::text[] then
    raise exception 'A student curriculum was disclosed';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','d6210000-0000-4000-8000-000000000004',true);
do $$
begin
  if (select curriculum_codes from public.tutor_directory where id='d6210000-0000-4000-8000-000000000003') is distinct from array['caps-sacai'] then
    raise exception 'The demo audience could not read its tutor curriculum';
  end if;
end;
$$;

reset role;
select set_config('request.jwt.claim.sub','',true);
set local role anon;
do $$
begin
  if (select curriculum_codes from public.tutor_directory where id='d6210000-0000-4000-8000-000000000002')
    is distinct from array['caps-ieb','cambridge-igcse'] then
    raise exception 'The directory did not expose the approved tutor selections';
  end if;
  if coalesce((select curriculum_codes from public.tutor_directory where id='d6210000-0000-4000-8000-000000000003'), '{}') <> '{}'::text[] then
    raise exception 'A demo tutor curriculum was disclosed';
  end if;
end;
$$;
rollback;
