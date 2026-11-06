begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('d6610000-0000-4000-8000-000000000001','live-profile-tutor@example.test','{}','{}'),
  ('d6610000-0000-4000-8000-000000000002','live-profile-student@example.test','{}','{}'),
  ('d6610000-0000-4000-8000-000000000003','live-profile-unrelated@example.test','{}','{}');
update public.profiles set role='tutor' where id='d6610000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate)
values ('d6610000-0000-4000-8000-000000000001','Live Profile Tutor',true,true,250);
insert into public.bookings(student_id,tutor_id,subject_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select 'd6610000-0000-4000-8000-000000000002','d6610000-0000-4000-8000-000000000001',id,
  now()+interval '2 days',now()+interval '2 days 1 hour','pending','online',60,250,250
from public.subjects where slug='mathematics';
insert into public.bookings(student_id,tutor_id,subject_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount,proposed_by)
select 'd6610000-0000-4000-8000-000000000003','d6610000-0000-4000-8000-000000000001',id,
  now()+interval '3 days',now()+interval '3 days 1 hour','pending','online',60,250,250,
  'd6610000-0000-4000-8000-000000000001'
from public.subjects where slug='mathematics';

create temporary table signals_before as select user_id,version from public.workspace_signals;
set local role authenticated;
select set_config('request.jwt.claim.sub','d6610000-0000-4000-8000-000000000002',true);
update public.profiles set study_grade=11,study_level_code='fet',curriculum_codes=array['caps-ieb'],
  study_subject_ids=array[(select id from public.subjects where slug='physical-sciences')],
  study_institution='Private study institution' where id=auth.uid();
select set_config('request.jwt.claim.sub','d6610000-0000-4000-8000-000000000001',true);
do $$
declare study jsonb := public.my_tutoring_workspace()->'student_study_profiles';
begin
  if (study->'d6610000-0000-4000-8000-000000000002'->>'grade')::int is distinct from 11
    or study->'d6610000-0000-4000-8000-000000000002'->'subjects' is distinct from '["Physical Sciences"]'::jsonb
    or study ? 'd6610000-0000-4000-8000-000000000003'
    or study->'d6610000-0000-4000-8000-000000000002' ? 'study_institution' then
    raise exception 'The workspace did not project the expected study details: %',study;
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','d6610000-0000-4000-8000-000000000003',true);
do $$
begin
  if public.my_tutoring_workspace()->'student_study_profiles' is distinct from '{}'::jsonb then
    raise exception 'A different account can read student study details';
  end if;
end;
$$;
reset role;
do $$
begin
  if not exists (
    select 1 from public.workspace_signals s left join signals_before b using(user_id)
    where s.user_id='d6610000-0000-4000-8000-000000000001' and s.version>coalesce(b.version,0)
  ) then raise exception 'A student edit did not refresh the related tutor workspace'; end if;
end;
$$;
truncate signals_before;
insert into signals_before select user_id,version from public.workspace_signals;
update public.tutor_profiles set public_name='Updated Tutor Name' where user_id='d6610000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','d6610000-0000-4000-8000-000000000002',true);
do $$
begin
  if public.my_tutoring_workspace()->'bookings'->0->>'tutor_name' is distinct from 'Updated Tutor Name' then
    raise exception 'The student workspace kept the old tutor name';
  end if;
end;
$$;
reset role;
do $$
begin
  if not exists (
    select 1 from public.workspace_signals s left join signals_before b using(user_id)
    where s.user_id='d6610000-0000-4000-8000-000000000002' and s.version>coalesce(b.version,0)
  ) then raise exception 'A tutor edit did not refresh the related student workspace'; end if;
end;
$$;
rollback;
