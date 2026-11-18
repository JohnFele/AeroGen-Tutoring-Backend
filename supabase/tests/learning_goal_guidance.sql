begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values('c2400000-0000-4000-8000-000000000001','goal.practice@example.test','{}','{}');
update public.profiles set role='tutor' where id='c2400000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,teaching_modes,hourly_rate) values('c2400000-0000-4000-8000-000000000001','Goal Practice Tutor',true,array['online'],200);
set local role authenticated;
select set_config('request.jwt.claim.sub','c2400000-0000-4000-8000-000000000001',true);
do $$ declare course jsonb; result jsonb; begin
 select item into course from jsonb_array_elements(public.my_tutor_resource_library()->'courses')item where item->>'id'='goal-setting-lab';
 if jsonb_array_length(course->'lessons')<>3 then raise exception 'Missing goal-type guidance'; end if;
 if course->'lessons'->0 ? 'answer' then raise exception 'Training answer exposed'; end if;
 result:=public.answer_tutor_course_lesson('goal-setting-lab','score-evidence',0,(course->>'contentVersion')::integer);
 if (result->>'correct')::boolean then raise exception 'Invalid evidence was accepted'; end if;
 result:=public.answer_tutor_course_lesson('goal-setting-lab','score-evidence',1,(course->>'contentVersion')::integer);
 if not (result->>'correct')::boolean or not(public.my_tutor_resource_library()->'completedLessons' ? ('goal-setting-lab:'||(course->>'contentVersion')||':score-evidence')) then raise exception 'Practice progress was not saved'; end if;
end; $$;
reset role;
do $$ begin
 if exists(select 1 from private.learning_plans where student_id='c2400000-0000-4000-8000-000000000001') then raise exception 'Training created a real learner plan'; end if;
end; $$;
rollback;
