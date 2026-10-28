-- Run this entire file only after application_review.sql has been applied.
-- All application, object-metadata, role and profile changes roll back.
begin;
insert into storage.objects(bucket_id,name,metadata) values
 ('tutor-application-documents','de000000-0000-4000-8000-000000000106/cf000000-0000-4000-8000-000000000001/identity.pdf','{"mimetype":"application/pdf","size":100}'),
 ('tutor-application-documents','de000000-0000-4000-8000-000000000106/cf000000-0000-4000-8000-000000000001/qualification.pdf','{"mimetype":"application/pdf","size":100}');
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000106',true);
set local role authenticated;
do $$ declare created_id uuid; begin
  if has_table_privilege('authenticated','public.tutor_applications','INSERT') then raise exception 'Raw application insertion must be disabled'; end if;
  created_id:=public.submit_tutor_application('cf000000-0000-4000-8000-000000000001',
    '{"first_name":"Demo","last_name":"Applicant","contact_email":"applicant@example.test","id_number":"TEST-ONLY","phone":"+27620000000","street_address":"Example address","city":"Johannesburg","province":"Gauteng","highest_qualification":"Demonstration BSc","institution":"Example Institution","year_completed":2025,"years_experience":2,"student_age_groups":["High school"],"teaching_style":"Explain and review understanding.","availability_slots":["Weekday Evenings"],"teaching_modes":["online"],"hourly_rate":250}',
    array[(select id from public.subjects where name='Mathematics')],
    '[{"document_type":"identity","storage_path":"de000000-0000-4000-8000-000000000106/cf000000-0000-4000-8000-000000000001/identity.pdf","original_filename":"identity.pdf","mime_type":"application/pdf","size_bytes":100},{"document_type":"qualification","storage_path":"de000000-0000-4000-8000-000000000106/cf000000-0000-4000-8000-000000000001/qualification.pdf","original_filename":"qualification.pdf","mime_type":"application/pdf","size_bytes":100}]');
  if not exists(select 1 from public.tutor_applications where id=created_id and status='submitted' and reviewer_id is null) then raise exception 'Submission missing or self-approved'; end if;
  if (select count(*) from public.tutor_application_documents where application_id='cf000000-0000-4000-8000-000000000001')<>2 then raise exception 'Documents were not registered atomically'; end if;
  begin perform public.review_tutor_application(created_id,'approved','Unauthorized',now());raise exception 'Applicant approved own application';exception when insufficient_privilege then null;end;
  begin perform public.admin_update_student('de000000-0000-4000-8000-000000000101','{"first_name":"Unauthorized"}',now());raise exception 'Student edited another student';exception when insufficient_privilege then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.sub',(select id::text from public.profiles where role in ('admin','superUser') order by id limit 1),true);
set local role authenticated;
do $$ declare stamp timestamptz; target uuid:='cf000000-0000-4000-8000-000000000001'; begin
  select updated_at into stamp from public.tutor_applications where id=target;
  perform public.review_tutor_application(target,'under_review','Checking documents',stamp);
  begin perform public.review_tutor_application(target,'approved','Checked',stamp-interval '1 microsecond');raise exception 'Outdated review was accepted';exception when sqlstate 'PT409' then null;end;
  select updated_at into stamp from public.tutor_applications where id=target;
  perform public.review_tutor_application(target,'approved','Documents checked and approved.',stamp);
  if not exists(select 1 from public.tutor_directory where id='de000000-0000-4000-8000-000000000106' and public_name='Demo Applicant' and not is_featured and hourly_rate=250) then raise exception 'Approval did not publish submitted profile'; end if;
  if not exists(select 1 from public.profiles where id='de000000-0000-4000-8000-000000000106' and role='tutor') then raise exception 'Tutor dashboard access not granted'; end if;
  if (select count(*) from public.tutor_application_reviews where application_id=target)<>2 then raise exception 'Review history missing'; end if;
  begin perform public.review_tutor_application(target,'rejected','Cannot reverse a final decision',stamp);raise exception 'Final review was changed';exception when sqlstate 'PT409' then null;end;
  select updated_at into stamp from public.profiles where id='de000000-0000-4000-8000-000000000101';
  perform public.admin_update_student('de000000-0000-4000-8000-000000000101','{"first_name":"Demo Edited"}',stamp);
  if not exists(select 1 from public.profiles where id='de000000-0000-4000-8000-000000000101' and first_name='Demo Edited' and role='student') then raise exception 'Student edit failed'; end if;
  begin perform public.admin_update_student('de000000-0000-4000-8000-000000000101','{"role":"superUser"}',stamp);raise exception 'Role change was accepted';exception when invalid_parameter_value then null;end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','de000000-0000-4000-8000-000000000101',true);
set local role authenticated;
do $$ begin
  if exists(select 1 from public.tutor_applications where id='cf000000-0000-4000-8000-000000000001') then raise exception 'Another student can read private application'; end if;
  if exists(select 1 from storage.objects where name like '%cf000000-0000-4000-8000-000000000001%') then raise exception 'Another student can read application files'; end if;
end $$;
reset role;
set local role anon;
do $$ begin
  if has_function_privilege('anon','public.review_tutor_application(uuid,text,text,timestamptz)','EXECUTE') then raise exception 'Anonymous review permission'; end if;
  if has_function_privilege('anon','public.submit_tutor_application(uuid,jsonb,bigint[],jsonb)','EXECUTE') then raise exception 'Anonymous submission permission'; end if;
end $$;
rollback;
