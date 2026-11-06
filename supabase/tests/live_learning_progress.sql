begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
select ('c9100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'learning-'||n||'@example.test','{}','{}'
from generate_series(1,5) n;
update public.profiles set role='tutor' where id in ('c9100000-0000-4000-8000-000000000002','c9100000-0000-4000-8000-000000000003');
update public.profiles set role='superUser' where id='c9100000-0000-4000-8000-000000000005';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
select id,'Learning tutor',true,180,array['online'] from public.profiles
where id in ('c9100000-0000-4000-8000-000000000002','c9100000-0000-4000-8000-000000000003');
with subject as (insert into public.subjects(name,category,slug)
  values ('Learning regression','General','learning-regression') returning id)
insert into public.bookings(id,student_id,tutor_id,subject_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('c9200000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'c9100000-0000-4000-8000-000000000001',
  ('c9100000-0000-4000-8000-'||lpad((n+1)::text,12,'0'))::uuid,id,now()-make_interval(days=>n),now()-make_interval(days=>n)+interval '1 hour',
  case when n=1 then 'completed' else 'confirmed' end,'online',60,180,180
from subject cross join generate_series(1,2) n;

set local role authenticated;
do $$
declare
  learner text := 'c9100000-0000-4000-8000-000000000001';
  tutor text := 'c9100000-0000-4000-8000-000000000002';
  second_tutor text := 'c9100000-0000-4000-8000-000000000003';
  other_learner text := 'c9100000-0000-4000-8000-000000000004';
  staff text := 'c9100000-0000-4000-8000-000000000005';
  booking uuid := 'c9200000-0000-4000-8000-000000000001';
  plan uuid; goal uuid; pending_assessment uuid; detail jsonb; result jsonb;
  request_key uuid := gen_random_uuid();
  version_no integer; payload jsonb; goal_data jsonb;
  day date := (now() at time zone 'Africa/Johannesburg')::date;
begin
  perform set_config('request.jwt.claim.sub',tutor,true);
  payload := jsonb_build_object('bookingId',booking,'title','Regression plan','reviewDate',day+7,'skills',jsonb_build_array('Equations'));
  begin
    perform public.apply_learning_action('startPlan',null,null,gen_random_uuid(),payload);
    raise exception 'Learning records were created before learner authorisation';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.sub',learner,true);
  if public.my_learning_progress()->>'enabled' is distinct from 'false' then raise exception 'Authorisation is missing its opt-in'; end if;
  perform public.save_my_learner_age_profile((day-interval '21 years')::date);
  perform set_config('request.jwt.claim.sub',tutor,true);
  result := public.apply_learning_action('startPlan',null,null,request_key,payload);
  if result is distinct from public.apply_learning_action('startPlan',null,null,request_key,payload) then
    raise exception 'Plan request replay changed the result';
  end if;
  plan := (result->>'planId')::uuid;
  detail := public.my_learning_progress(plan)->'plan';
  if detail->>'canRead' is distinct from 'false' or detail ? 'goals' then raise exception 'Pending tutor accessed academic data'; end if;

  perform set_config('request.jwt.claim.sub',other_learner,true);
  perform public.save_my_learner_age_profile((day-interval '21 years')::date);
  begin
    perform public.my_learning_progress(plan);
    raise exception 'Unrelated learner accessed the plan';
  exception when sqlstate 'PT404' then null; end;
  begin
    perform public.manage_learning_clearance(learner::uuid,'view');
    raise exception 'Unrelated learner accessed authorisation data';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.sub',learner,true);
  detail := public.my_learning_progress(plan)->'plan';
  perform public.apply_learning_action('approveAccess',plan,(detail->>'version')::integer,gen_random_uuid(),jsonb_build_object('tutorId',tutor));
  goal_data := jsonb_build_object('type','score','title','Algebra assessment','criteria','Independent comparable algebra tests',
    'dueDate',day+28,'target',80,'assessmentType','tutor_checkpoint','requiredChecks',2,'minGapDays',7,'minQuestions',10);
  perform set_config('request.jwt.claim.sub',tutor,true);
  version_no := (public.my_learning_progress(plan)->'plan'->>'version')::integer;
  perform public.apply_learning_action('saveGoal',plan,version_no,gen_random_uuid(),goal_data);
  detail := public.my_learning_progress(plan)->'plan';
  goal := (detail->'goals'->0->>'id')::uuid;
  begin
    perform public.apply_learning_action('approveGoal',plan,(detail->>'version')::integer,gen_random_uuid(),
      jsonb_build_object('id',goal,'version',1,'decision','accept'));
    raise exception 'Tutor approved their own goal proposal';
  exception when insufficient_privilege then null; end;
  begin
    perform public.apply_learning_action('saveGoal',plan,version_no,gen_random_uuid(),goal_data);
    raise exception 'A stale plan update was accepted';
  exception when sqlstate 'PT409' then null; end;
  perform set_config('request.jwt.claim.sub',learner,true);
  perform public.apply_learning_action('approveGoal',plan,(detail->>'version')::integer,gen_random_uuid(),
    jsonb_build_object('id',goal,'version',1,'decision','accept'));

  perform set_config('request.jwt.claim.sub',tutor,true);
  payload := jsonb_build_object('goalId',goal,'score',10,'maxScore',25,'category','tutor_checkpoint','questions',15,
    'conditions','Independent','title','Starting test','comparable',true,'notes','Comparable independent algebra assessment.','source','Tutor assessed','date',day-28);
  perform public.apply_learning_action('assessment',plan,(public.my_learning_progress(plan)->'plan'->>'version')::integer,gen_random_uuid(),payload);
  perform public.apply_learning_action('assessment',plan,(public.my_learning_progress(plan)->'plan'->>'version')::integer,gen_random_uuid(),
    payload || jsonb_build_object('score',21,'title','Follow-up test','date',day-15));

  perform set_config('request.jwt.claim.sub',learner,true);
  perform public.apply_learning_action('assessment',plan,(public.my_learning_progress(plan)->'plan'->>'version')::integer,gen_random_uuid(),
    payload || jsonb_build_object('score',22,'title','Submitted result','date',day-7));
  detail := public.my_learning_progress(plan)->'plan';
  result := detail->'goals'->0->'result';
  if (result->>'change')::numeric<>44 or result->>'eligible' is distinct from 'false' or result->>'status' is distinct from 'active'
    then raise exception 'Unverified work changed formal progress or mastery: %',result; end if;
  pending_assessment := (detail->'assessments'->0->>'id')::uuid;
  begin
    perform public.apply_learning_action('verifyAssessment',plan,(detail->>'version')::integer,gen_random_uuid(),
      jsonb_build_object('id',pending_assessment,'accepted',true,'feedback','Trying to verify own result'));
    raise exception 'Learner verified their own assessment';
  exception when insufficient_privilege then null; end;

  perform set_config('request.jwt.claim.sub',tutor,true);
  perform public.apply_learning_action('verifyAssessment',plan,(detail->>'version')::integer,gen_random_uuid(),
    jsonb_build_object('id',pending_assessment,'accepted',true,'feedback','Reviewed the result and its conditions.'));
  detail := public.my_learning_progress(plan)->'plan';
  result := detail->'goals'->0->'result';
  if result->>'eligible' is distinct from 'true' or (result->>'baseline')::numeric<>40 or (result->>'change')::numeric<>48
    or (result->>'previousChange')::numeric<>4 or result->>'status' is distinct from 'active' then
    raise exception 'Verified mastery or server calculation is wrong: %',result;
  end if;
  perform public.apply_learning_action('confirmGoal',plan,(detail->>'version')::integer,gen_random_uuid(),jsonb_build_object('id',goal));
  detail := public.my_learning_progress(plan)->'plan';
  if detail->'goals'->0->'result'->>'status' is distinct from 'achieved' then raise exception 'Formal achievement was not recorded'; end if;
  perform public.apply_learning_action('correctAssessment',plan,(detail->>'version')::integer,gen_random_uuid(),
    jsonb_build_object('id',pending_assessment,'score',18,'maxScore',25,'reason','Corrected a transcription error.'));
  detail := public.my_learning_progress(plan)->'plan';
  result := detail->'goals'->0->'result';
  if result->>'status' is distinct from 'active' or (result->>'previousChange')::numeric<>-12
    or (public.my_learning_history(plan)->'events'->0->'details'->'before'->>'score')::numeric<>22 then
    raise exception 'Correction failed to preserve old values or recalculate progress: %',result;
  end if;
  perform public.apply_learning_action('feedback',plan,(detail->>'version')::integer,gen_random_uuid(),
    jsonb_build_object('bookingId',booking,'title','Review algebra','notes','Recorded after a completed lesson.','nextStep','Practise two independent examples.'));

  perform set_config('request.jwt.claim.sub',second_tutor,true);
  begin
    perform public.my_learning_progress(plan);
    raise exception 'A separate confirmed booking granted access to marks';
  exception when sqlstate 'PT404' then null; end;
  perform set_config('request.jwt.claim.sub',learner,true);
  detail := public.my_learning_progress(plan)->'plan';
  if detail->'notes'->0->>'nextStep' is distinct from 'Practise two independent examples.' then
    raise exception 'Learner did not see tutor feedback';
  end if;
  perform public.apply_learning_action('revokeAccess',plan,(detail->>'version')::integer,gen_random_uuid(),jsonb_build_object('tutorId',tutor));
  if public.my_learning_progress(plan)->'plan'->'goals'->0->'result' is distinct from result then
    raise exception 'The learner lost progress history after revocation';
  end if;
  perform set_config('request.jwt.claim.sub',tutor,true);
  begin
    perform public.my_learning_progress(plan);
    raise exception 'Revoked tutor retained access';
  exception when sqlstate 'PT404' then null; end;
  perform set_config('request.jwt.claim.sub',staff,true);
  perform public.manage_learning_clearance(other_learner::uuid,'approve','TEST-AUTH-001');
  if public.manage_learning_clearance(other_learner::uuid,'view')->>'basis' is distinct from 'documented_authorisation' then
    raise exception 'Documented authorisation was not recorded';
  end if;
  perform public.manage_learning_clearance(other_learner::uuid,'revoke');
end;
$$;
reset role;
rollback;
