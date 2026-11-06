begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('c9300000-0000-4000-8000-000000000001','age-adult@example.test','{}','{}'),
  ('c9300000-0000-4000-8000-000000000002','age-minor@example.test','{}','{}'),
  ('c9300000-0000-4000-8000-000000000003','age-tutor@example.test','{}','{}'),
  ('c9300000-0000-4000-8000-000000000004','age-super@example.test','{}','{}'),
  ('c9300000-0000-4000-8000-000000000005','age-legacy@example.test','{}','{}');
update public.profiles set role='tutor' where id='c9300000-0000-4000-8000-000000000003';
update public.profiles set role='superUser' where id='c9300000-0000-4000-8000-000000000004';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
values ('c9300000-0000-4000-8000-000000000003','Age Test Tutor',true,180,array['online']);
insert into private.learning_clearances(student_id,basis,needs_profile_age)
values ('c9300000-0000-4000-8000-000000000005','adult_declaration',true);

set local role authenticated;
do $$
declare
  adult text := 'c9300000-0000-4000-8000-000000000001';
  minor text := 'c9300000-0000-4000-8000-000000000002';
  tutor text := 'c9300000-0000-4000-8000-000000000003';
  staff text := 'c9300000-0000-4000-8000-000000000004';
  legacy text := 'c9300000-0000-4000-8000-000000000005';
  today date := (now() at time zone 'Africa/Johannesburg')::date;
  saved jsonb;
begin
  perform set_config('request.jwt.claim.sub',adult,true);
  if public.my_learning_progress()->>'ageState' is distinct from 'missing_birth_date'
    or public.my_learning_progress()->>'tutorialSeen' is distinct from 'false' then
    raise exception 'A new learner did not start with missing age and an unseen tutorial';
  end if;
  begin
    perform public.apply_learning_action('enable',null,null,gen_random_uuid(),'{"adult":true}');
    raise exception 'The old checkbox bypassed the profile age rule';
  exception when insufficient_privilege then null; end;
  begin
    perform public.save_my_learner_age_profile(today+1);
    raise exception 'A future birth date was accepted';
  exception when invalid_parameter_value then null; end;

  saved := public.save_my_learner_age_profile((today-interval '22 years')::date);
  if saved->>'ageState' is distinct from 'enabled'
    or public.my_learning_progress()->>'enabled' is distinct from 'true' then
    raise exception 'An eligible learner did not get access from their saved profile';
  end if;
  if saved is distinct from public.save_my_learner_age_profile((today-interval '22 years')::date)
    or public.my_learning_progress() ? 'birthDate' then
    raise exception 'A profile retry changed the birth date or progress exposed it';
  end if;
  begin
    perform public.save_my_learner_age_profile((today-interval '20 years')::date);
    raise exception 'The learner silently replaced their saved birth date';
  exception when sqlstate 'PT409' then null; end;

  perform public.mark_learning_tutorial_seen();
  perform public.mark_learning_tutorial_seen();
  if public.my_learning_progress()->>'tutorialSeen' is distinct from 'true' then
    raise exception 'The tutorial completion was not persisted';
  end if;

  perform set_config('request.jwt.claim.sub',minor,true);
  saved := public.save_my_learner_age_profile(((today-interval '18 years')::date)+1);
  if saved->>'ageState' is distinct from 'guardian_required' or public.my_learning_progress()->>'enabled' is distinct from 'false'
    or public.my_learning_progress()->>'tutorialSeen' is distinct from 'false' then
    raise exception 'A minor was enabled automatically or received another learner’s tutorial setting';
  end if;
  begin
    perform public.apply_learning_action('enable',null,null,gen_random_uuid(),'{"adult":true}');
    raise exception 'A minor enabled access with a supplied adult flag';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub',staff,true);
  perform public.manage_learning_clearance(minor::uuid,'approve','TEST-GUARDIAN-01');
  perform set_config('request.jwt.claim.sub',minor,true);
  if public.my_learning_progress()->>'enabled' is distinct from 'true' then raise exception 'Documented authorisation did not enable the minor'; end if;

  perform set_config('request.jwt.claim.sub',tutor,true);
  begin
    perform public.my_learner_age_profile();
    raise exception 'A tutor was allowed to use the private learner age endpoint';
  exception when insufficient_privilege then null; end;
  begin
    perform private.apply_learning_action('enable',null,null,gen_random_uuid(),'{"adult":true}');
    raise exception 'The previous private activation endpoint remained exposed';
  exception when insufficient_privilege then null; end;
  perform public.mark_learning_tutorial_seen();
  if public.my_learning_progress()->>'tutorialSeen' is distinct from 'true' then raise exception 'Tutor tutorial completion was not saved'; end if;

  perform set_config('request.jwt.claim.sub',legacy,true);
  if public.my_learning_progress()->>'enabled' is distinct from 'true'
    or public.my_learning_progress()->>'ageState' is distinct from 'missing_birth_date' then
    raise exception 'Legacy learner lost existing access before the profile review';
  end if;
  perform set_config('request.jwt.claim.sub',staff,true);
  perform public.manage_learning_clearance(legacy::uuid,'revoke');
  perform set_config('request.jwt.claim.sub',legacy,true);
  saved := public.save_my_learner_age_profile((today-interval '22 years')::date);
  if saved->>'ageState' is distinct from 'restricted' or public.my_learning_progress()->>'enabled' is distinct from 'false' then
    raise exception 'A profile update overrode an explicit staff revocation';
  end if;
end;
$$;

reset role;
rollback;
