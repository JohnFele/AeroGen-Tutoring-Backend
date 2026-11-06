begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('d6510000-0000-4000-8000-000000000001','phase-tutor@example.test','{}','{}'),
  ('d6510000-0000-4000-8000-000000000002','phase-student@example.test','{}','{}');
update public.profiles set role='tutor' where id='d6510000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,teaching_modes,students_per_session,years_experience,student_age_groups)
values ('d6510000-0000-4000-8000-000000000001','Phase Tutor',true,true,250,array['online'],'1',5,array['High School (Gr 10-12)']);

set local role authenticated;
select set_config('request.jwt.claim.sub','d6510000-0000-4000-8000-000000000001',true);
do $$
declare stamp timestamptz := (select updated_at from public.tutor_profiles where user_id=auth.uid());
  physical bigint := (select id from public.subjects where slug='physical-sciences');
  skills bigint := (select id from public.subjects where slug='life-skills');
begin
  if (select teaching_level_codes from public.profiles where id=auth.uid()) is distinct from array['fet'] then
    raise exception 'The approved application did not seed the tutor phases';
  end if;
  if skills is null or not exists(select 1 from public.teaching_subject_options_by_level where curriculum_code='caps-dbe' and subject_id=skills and level_code='foundation')
    or exists(select 1 from public.teaching_subject_options_by_level where curriculum_code='caps-dbe' and subject_id=skills and level_code='fet') then
    raise exception 'CAPS Life Skills phase mismatch';
  end if;
  begin
    perform public.save_my_tutor_listing('{"years_experience":10}',stamp);
    raise exception 'Tutor changed the admin-managed experience';
  exception when invalid_parameter_value then null;
  end;
  perform public.save_my_teaching_subjects(array['caps-dbe'],array['fet'],
    jsonb_build_array(jsonb_build_object('subject_id',physical,'curriculum_codes',array['caps-dbe'])),stamp);
  begin
    perform public.save_my_teaching_subjects(array['caps-dbe'],array['fet'],
      jsonb_build_array(jsonb_build_object('subject_id',skills,'curriculum_codes',array['caps-dbe'])),stamp);
    raise exception 'Tutor saved Life Skills under FET';
  exception when invalid_parameter_value then null;
  end;
  if (select teaching_level_codes from public.profiles where id=auth.uid()) is distinct from array['fet'] then
    raise exception 'Tutor phase preference was not saved';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','d6510000-0000-4000-8000-000000000002',true);
do $$
declare physical bigint := (select id from public.subjects where slug='physical-sciences');
begin
  update public.profiles set curriculum_codes=array['caps-ieb'],study_level_code='fet',study_grade=11,
    study_subject_ids=array[physical],study_institution='Example School',study_goals='Improve lab reports' where id=auth.uid();
  if (select study_subject_ids from public.profiles where id=auth.uid()) is distinct from array[physical] then
    raise exception 'Student study details were not saved';
  end if;
  begin
    update public.profiles set study_grade=7 where id=auth.uid();
    raise exception 'An incompatible grade was accepted';
  exception when invalid_parameter_value then null;
  end;
end;
$$;
rollback;
