begin;
-- Successful staff workflows model a verified MFA session; denial cases are in staff_mfa.sql.
select set_config('request.jwt.claims','{"aal":"aal2"}',true);
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('c2200000-0000-4000-8000-000000000001','library.tutor@example.test','{}','{}'),
 ('c2200000-0000-4000-8000-000000000002','library.admin@example.test','{}','{}'),
 ('c2200000-0000-4000-8000-000000000003','library.student@example.test','{}','{}'),
 ('c2200000-0000-4000-8000-000000000004','library.other@example.test','{}','{}');
update public.profiles set role='tutor' where id in ('c2200000-0000-4000-8000-000000000001','c2200000-0000-4000-8000-000000000004');
update public.profiles set role='admin' where id='c2200000-0000-4000-8000-000000000002';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,teaching_modes,hourly_rate)
values('c2200000-0000-4000-8000-000000000001','Library Tutor',true,true,array['online'],200),
 ('c2200000-0000-4000-8000-000000000004','Another Tutor',true,true,array['online'],200);
set local role authenticated;
select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000002',true);
do $$
declare resource jsonb; course jsonb;
begin
 resource:=public.admin_save_tutor_library_item('{
  "id":"library-test-resource","kind":"resource","title":"Test resource","description":"A useful classroom resource for the test.",
  "category":"Teaching practice","format":"Guide","minutes":5,"status":"published",
  "sections":[{"heading":"Prepare","body":"Choose a useful task and ask the learner to explain it."}],"lessons":[]
 }',null);
 course:=public.admin_save_tutor_library_item('{
  "id":"library-test-course","kind":"course","title":"Test course","description":"Practise teaching with an observable outcome.",
  "category":"Teaching practice","format":"Course","minutes":10,"status":"published","sections":[],
  "supporting_resource_id":"library-test-resource",
  "lessons":[{"id":"library-test-lesson","title":"Test lesson","body":"Ask the learner to demonstrate their thinking.",
   "question":"What gives useful evidence?","options":["An independent task","Only time spent"],"answer":0,"explanation":"An independent task shows what the learner can do."}]
 }',null);
 perform set_config('test.library_course',course::text,true);
 perform set_config('test.library_resource',resource::text,true);
 begin
  perform public.admin_save_tutor_library_item(jsonb_build_object('id',course->>'id','kind','course','title','Stale edit'),99);
  raise exception 'A stale course edit succeeded';
 exception when sqlstate 'PT409' then null; end;
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000001',true);
do $$
declare library jsonb; course jsonb; result jsonb;
begin
 library:=public.my_tutor_resource_library();
 select item into course from jsonb_array_elements(library->'courses')item where item->>'id'='library-test-course';
 if course is null or course->'lessons'->0 ? 'answer' or course->'lessons'->0 ? 'explanation' then raise exception 'Course answers were missing or leaked to learners'; end if;
 perform public.save_tutor_library_item('library-test-resource',true);
 if not(public.my_tutor_resource_library()->'saved' ? 'library-test-resource') then raise exception 'A saved resource was not stored in the account'; end if;
 result:=public.answer_tutor_course_lesson('library-test-course','library-test-lesson',1,1);
 if result->>'correct'<>'false' or public.my_tutor_resource_library()->'completedLessons' ? 'library-test-course:1:library-test-lesson' then
  raise exception 'An incorrect answer completed a lesson'; end if;
 result:=public.answer_tutor_course_lesson('library-test-course','library-test-lesson',0,1);
 perform public.answer_tutor_course_lesson('library-test-course','library-test-lesson',0,1);
 if result->>'correct'<>'true' or not(public.my_tutor_resource_library()->'completedLessons' ? 'library-test-course:1:library-test-lesson') then raise exception 'A correct answer did not persist'; end if;
 begin perform public.admin_tutor_library(); raise exception 'Tutor could edit the administrator catalogue'; exception when insufficient_privilege then null; end;
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000004',true);
do $$ begin
 if public.my_tutor_resource_library()->'saved' ? 'library-test-resource'
  or public.my_tutor_resource_library()->'completedLessons' ? 'library-test-course:1:library-test-lesson' then
  raise exception 'Progress leaked between tutor accounts'; end if;
 perform public.import_tutor_library_progress(array['library-test-resource'],array['library-test-lesson','clear-outcomes']);
 if public.my_tutor_resource_library()->'completedLessons' ? 'library-test-course:1:library-test-lesson'
  or not(public.my_tutor_resource_library()->'completedLessons' ? 'effective-lessons:1:clear-outcomes') then
  raise exception 'Legacy import ignored valid records or bypassed checks for a new course'; end if;
 perform public.save_tutor_library_item('library-test-resource',false);
 perform public.import_tutor_library_progress(array['library-test-resource'],array['clear-outcomes']);
 if public.my_tutor_resource_library()->'saved' ? 'library-test-resource' then raise exception 'A repeated browser import overwrote a later preference'; end if;
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000003',true);
do $$ begin
 begin perform public.my_tutor_resource_library(); raise exception 'A student could read the private tutor library'; exception when insufficient_privilege then null; end;
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000002',true);
do $$
declare course jsonb:=current_setting('test.library_course')::jsonb; edited jsonb; payload jsonb;
begin
 payload:=course-'version'-'content_version'-'updated_by'-'created_at'-'updated_at';
 payload:=jsonb_set(payload,'{lessons,0,body}','"Use a fresh task to check the learner independently."');
 edited:=public.admin_save_tutor_library_item(payload,(course->>'version')::integer);
 if edited->>'content_version'<>'2' then raise exception 'Editing course content did not version the progress'; end if;
 perform set_config('test.library_course',edited::text,true);
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000001',true);
do $$ begin
 if public.my_tutor_resource_library()->'completedLessons' ? 'library-test-course:1:library-test-lesson' then
  raise exception 'Old quiz completion counted toward changed course content'; end if;
 begin perform public.answer_tutor_course_lesson('library-test-course','library-test-lesson',0,1);
  raise exception 'A stale course view saved completion'; exception when sqlstate 'PT409' then null; end;
end; $$;

select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000002',true);
select public.admin_archive_tutor_library_item('library-test-resource',1);
select public.admin_archive_tutor_library_item('library-test-course',2);
select set_config('request.jwt.claim.sub','c2200000-0000-4000-8000-000000000001',true);
do $$
declare library jsonb:=public.my_tutor_resource_library();
begin
 if exists(select 1 from jsonb_array_elements(library->'resources')item where item->>'id'='library-test-resource')
  or exists(select 1 from jsonb_array_elements(library->'courses')item where item->>'id'='library-test-course') then
  raise exception 'Archived items remained visible in the tutor library'; end if;
 begin perform public.save_tutor_library_item('library-test-resource',true);
  raise exception 'An archived resource could be saved'; exception when sqlstate 'PT404' then null; end;
end; $$;
reset role;
do $$ begin
 if (select count(*) from private.tutor_course_progress where owner='c2200000-0000-4000-8000-000000000001' and item_id='library-test-course')<>1 then
  raise exception 'Course progress was duplicated or lost when content was edited and archived'; end if;
end; $$;
rollback;
