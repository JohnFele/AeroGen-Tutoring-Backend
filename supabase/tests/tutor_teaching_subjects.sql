begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('d6310000-0000-4000-8000-000000000001','teaching-tutor@example.test','{}','{}'),
  ('d6310000-0000-4000-8000-000000000002','teaching-student@example.test','{}','{}');
update public.profiles set role='tutor' where id='d6310000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,teaching_modes)
values ('d6310000-0000-4000-8000-000000000001','Teaching Tutor',true,true,250,array['online']);

set local role authenticated;
select set_config('request.jwt.claim.sub','d6310000-0000-4000-8000-000000000001',true);
do $$
declare
  tutor uuid := auth.uid();
  stamp timestamptz := (select updated_at from public.tutor_profiles where user_id=tutor);
  physical bigint := (select id from public.subjects where slug='physical-sciences');
  physics bigint := (select id from public.subjects where slug='physics');
begin
  if not exists(select 1 from public.teaching_subject_options where curriculum_code='caps-dbe' and subject_id=physical)
    or not exists(select 1 from public.teaching_subject_options where curriculum_code='caps-ieb' and subject_id=physical)
    or not exists(select 1 from public.teaching_subject_options where curriculum_code='cambridge-igcse' and subject_id=physics)
    or exists(select 1 from public.teaching_subject_options where curriculum_code='caps-dbe' and subject_id=physics) then
    raise exception 'Shared CAPS subjects and Cambridge Physics were not separated correctly';
  end if;
  perform public.save_my_teaching_subjects(array['caps-dbe','caps-ieb'],
    jsonb_build_array(jsonb_build_object('subject_id',physical,'curriculum_codes',array['caps-dbe','caps-ieb'])),stamp);
  begin
    perform public.save_my_teaching_subjects(array['caps-dbe'],
      jsonb_build_array(jsonb_build_object('subject_id',physics,'curriculum_codes',array['caps-dbe'])),stamp);
    raise exception 'The DBE tutor saved Cambridge Physics';
  exception when invalid_parameter_value then null;
  end;
  if (select curriculum_codes from public.tutor_subjects where tutor_id=tutor and subject_id=physical)
    is distinct from array['caps-dbe','caps-ieb'] then
    raise exception 'A failed save altered the previous teaching assignments';
  end if;
  begin
    update public.profiles set curriculum_codes=array['caps-dbe'] where id=tutor;
    raise exception 'A linked curriculum was removed outside the editor';
  exception when invalid_parameter_value then null;
  end;
end;
$$;
reset role;
insert into public.tutor_subjects(tutor_id,subject_id)
select 'd6310000-0000-4000-8000-000000000001',id from public.subjects where slug='mathematics';
do $$
begin
  if (select ts.curriculum_codes from public.tutor_subjects ts join public.subjects s on s.id=ts.subject_id
      where ts.tutor_id='d6310000-0000-4000-8000-000000000001' and s.slug='mathematics')
    is distinct from array['caps-dbe','caps-ieb'] then
    raise exception 'A shared CAPS subject was not carried over to both declared routes';
  end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub','d6310000-0000-4000-8000-000000000002',true);
do $$
declare
  tutor uuid := 'd6310000-0000-4000-8000-000000000001';
  physical bigint := (select id from public.subjects where slug='physical-sciences');
begin
  begin
    perform public.save_my_teaching_subjects(array['caps-dbe'],'[]',now());
    raise exception 'A student edited teaching subjects';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.request_tutoring_booking(tutor,auth.uid(),physical,now()+interval '2 days',60,'online','individual','','cambridge-igcse');
    raise exception 'An unmatched curriculum could be booked';
  exception when invalid_parameter_value then null;
  end;
end;
$$;
rollback;
