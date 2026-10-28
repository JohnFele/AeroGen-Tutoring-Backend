-- Applications are submitted atomically after their private files are uploaded.
alter table public.tutor_applications
  add column first_name text,
  add column last_name text,
  add column contact_email text,
  add column id_number text,
  add column experience_range text;
create unique index tutor_applications_one_open_per_user on public.tutor_applications(user_id)
  where status in ('submitted','under_review');
revoke insert on public.tutor_applications,public.tutor_application_subjects,public.tutor_application_documents from authenticated;
revoke delete on public.tutor_application_subjects from authenticated;
create policy "Admins can read application document metadata" on public.tutor_application_documents
  for select to authenticated using ((select private.is_platform_admin()));
create policy "Admins can view application files" on storage.objects for select to authenticated
  using (bucket_id='tutor-application-documents' and (select private.is_platform_admin())
    and exists(select 1 from public.tutor_application_documents d where d.storage_path=name));
create policy "Applicants can clean up unattached uploads" on storage.objects for delete to authenticated
  using(bucket_id='tutor-application-documents' and (storage.foldername(name))[1]=(select auth.uid())::text
    and not exists(select 1 from public.tutor_application_documents d where d.storage_path=name));
update storage.buckets set allowed_mime_types=array['application/pdf','image/jpeg','image/png','application/vnd.openxmlformats-officedocument.wordprocessingml.document']
  where id='tutor-application-documents';

create table public.tutor_application_reviews (
  id bigint generated always as identity primary key,
  application_id uuid not null references public.tutor_applications(id) on delete cascade,
  reviewer_id uuid references public.profiles(id) on delete set null,
  previous_status text not null,
  status text not null,
  notes text not null default '',
  created_at timestamptz not null default now()
);
create index tutor_application_reviews_application_idx on public.tutor_application_reviews(application_id,created_at desc);
create index tutor_application_reviews_reviewer_idx on public.tutor_application_reviews(reviewer_id);
alter table public.tutor_application_reviews enable row level security;
revoke all on public.tutor_application_reviews from public,anon,authenticated;
grant select on public.tutor_application_reviews to authenticated;
create policy "Admins can read application review history" on public.tutor_application_reviews for select to authenticated
  using((select private.is_platform_admin()));

create function private.submit_tutor_application(_id uuid,_data jsonb,_subjects bigint[],_documents jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare caller uuid:=(select auth.uid()); account public.profiles; a public.tutor_applications; d jsonb; key text;
begin
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select * into account from public.profiles where id=caller for update;
  if not found or account.role not in ('student','tutor') then raise exception 'Only student or tutor accounts can apply' using errcode='42501'; end if;
  if exists(select 1 from public.tutor_applications where id=_id and user_id=caller) then return _id; end if;
  if exists(select 1 from public.tutor_profiles where user_id=caller and is_approved) then raise exception 'You already have an approved tutor profile' using errcode='PT409'; end if;
  if exists(select 1 from public.tutor_applications where user_id=caller and status in ('submitted','under_review')) then raise exception 'An application is already awaiting review' using errcode='PT409'; end if;
  if jsonb_typeof(_data) is distinct from 'object' or octet_length(_data::text)>30000 then raise exception 'Invalid application' using errcode='22023'; end if;
  for key in select jsonb_object_keys(_data) loop
    if key <> all(array['first_name','last_name','contact_email','id_number','phone','street_address','city','province','highest_qualification','institution','year_completed','certifications','years_experience','experience_range','previous_platforms','student_age_groups','teaching_style','availability_slots','teaching_modes','hourly_rate','students_per_session']) then raise exception 'Unsupported application field' using errcode='22023'; end if;
  end loop;
  a:=jsonb_populate_record(null::public.tutor_applications,_data);
  if length(btrim(coalesce(a.first_name,''))) not between 1 and 60 or length(btrim(coalesce(a.last_name,''))) not between 1 and 60
    or length(coalesce(a.contact_email,'')) not between 3 and 254 or a.contact_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    or length(btrim(coalesce(a.id_number,''))) not between 1 and 100 or length(btrim(coalesce(a.phone,''))) not between 9 and 22
    or a.province is null or a.phone !~ '^\+?[0-9 ()-]{9,22}$'
    or length(regexp_replace(a.phone,'[^0-9]','','g')) not between 9 and 15
    or length(btrim(coalesce(a.street_address,''))) not between 1 and 1000 or length(btrim(coalesce(a.city,''))) not between 1 and 160
    or length(btrim(coalesce(a.highest_qualification,''))) not between 1 and 250 or length(btrim(coalesce(a.institution,''))) not between 1 and 250
    or a.year_completed is null or a.year_completed not between 1950 and extract(year from current_date)::int
    or a.years_experience is null or a.years_experience not between 0 and 80
    or a.hourly_rate is null or a.hourly_rate not between 100 and 1000
    or length(btrim(coalesce(a.teaching_style,''))) not between 1 and 4000
    or coalesce(cardinality(a.teaching_modes),0) not between 1 and 2
    or coalesce(cardinality(a.student_age_groups),0) not between 1 and 30
    or coalesce(cardinality(a.availability_slots),0) not between 1 and 30
    or coalesce(cardinality(_subjects),0) not between 1 and 100
    or exists(select 1 from unnest(_subjects) wanted(id) where not exists(select 1 from public.subjects s where s.id=wanted.id and s.is_active))
    then raise exception 'Complete all required application details and active subjects' using errcode='22023'; end if;
  if jsonb_typeof(_documents) is distinct from 'array' or octet_length(_documents::text)>6000 or jsonb_array_length(_documents) not between 2 and 3
    or not exists(select 1 from jsonb_array_elements(_documents) v where v->>'document_type'='identity')
    or not exists(select 1 from jsonb_array_elements(_documents) v where v->>'document_type'='qualification')
    or (select count(distinct v->>'document_type') from jsonb_array_elements(_documents) v)<>jsonb_array_length(_documents)
    then raise exception 'Identity and qualification documents are required' using errcode='22023'; end if;
  for d in select value from jsonb_array_elements(_documents) loop
    if d->>'document_type' not in ('identity','qualification','resume') or d->>'document_type' is null
      or d->>'storage_path' not like caller::text||'/'||_id::text||'/%'
      or length(coalesce(d->>'original_filename','')) not between 1 and 120
      or coalesce((d->>'size_bytes')::bigint,0) not between 1 and (case when d->>'document_type'='qualification' then 10485760 else 5242880 end)
      or coalesce(d->>'mime_type','') not in ('application/pdf','image/jpeg','image/png','application/vnd.openxmlformats-officedocument.wordprocessingml.document')
      or (d->>'mime_type'='application/vnd.openxmlformats-officedocument.wordprocessingml.document' and d->>'document_type'<>'resume')
      or not exists(select 1 from storage.objects o where o.bucket_id='tutor-application-documents' and o.name=d->>'storage_path'
        and o.metadata->>'mimetype'=d->>'mime_type' and (o.metadata->>'size')::bigint=(d->>'size_bytes')::bigint)
      then raise exception 'Upload the required private documents first' using errcode='22023'; end if;
  end loop;
  insert into public.tutor_applications(id,user_id,status,first_name,last_name,contact_email,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,certifications,years_experience,experience_range,previous_platforms,student_age_groups,teaching_style,availability_slots,teaching_modes,hourly_rate,students_per_session,submitted_at)
    values(_id,caller,'submitted',a.first_name,a.last_name,a.contact_email,a.id_number,a.phone,a.street_address,a.city,a.province,a.highest_qualification,a.institution,a.year_completed,a.certifications,a.years_experience,a.experience_range,a.previous_platforms,a.student_age_groups,a.teaching_style,a.availability_slots,a.teaching_modes,a.hourly_rate,a.students_per_session,now());
  insert into public.tutor_application_subjects(application_id,subject_id) select _id,id from (select distinct unnest(_subjects) id) s;
  insert into public.tutor_application_documents(application_id,document_type,storage_path,original_filename,mime_type,size_bytes)
    select _id,v->>'document_type',v->>'storage_path',v->>'original_filename',v->>'mime_type',(v->>'size_bytes')::bigint from jsonb_array_elements(_documents) v;
  insert into public.notifications(user_id,kind,title,body,data)
    select p.id,'application','New tutor application',a.first_name||' '||a.last_name||' submitted a tutor application.',jsonb_build_object('tab','applications','applicationId',_id)
    from public.profiles p where p.role in ('admin','superUser');
  return _id;
end; $;
revoke all on function private.submit_tutor_application(uuid,jsonb,bigint[],jsonb) from public,anon;
grant execute on function private.submit_tutor_application(uuid,jsonb,bigint[],jsonb) to authenticated;
create function public.submit_tutor_application(_id uuid,_data jsonb,_subjects bigint[],_documents jsonb)
returns uuid language sql security invoker set search_path='' as $$ select private.submit_tutor_application(_id,_data,_subjects,_documents); $$;
revoke all on function public.submit_tutor_application(uuid,jsonb,bigint[],jsonb) from public,anon;
grant execute on function public.submit_tutor_application(uuid,jsonb,bigint[],jsonb) to authenticated;

create function private.review_tutor_application(_id uuid,_status text,_notes text,_expected_updated_at timestamptz)
returns uuid language plpgsql security definer set search_path='' as $$
declare a public.tutor_applications; account public.profiles; tutor public.tutor_profiles; subject_ids bigint[];
begin
  if (select auth.uid()) is null or not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if _status is null or _status not in ('under_review','approved','rejected') or length(coalesce(_notes,''))>4000 then raise exception 'Choose a review decision and valid notes' using errcode='22023'; end if;
  if _status='rejected' and length(btrim(coalesce(_notes,'')))<5 then raise exception 'Explain the reason for rejection' using errcode='22023'; end if;
  select * into a from public.tutor_applications where id=_id;
  if not found then raise exception 'Application not found' using errcode='P0002'; end if;
  select * into account from public.profiles where id=a.user_id for update;
  select * into a from public.tutor_applications where id=_id for update;
  if _expected_updated_at is null or a.updated_at is distinct from _expected_updated_at then raise exception 'This application changed. Reload it before reviewing.' using errcode='PT409'; end if;
  if a.status not in ('submitted','under_review') then raise exception 'This application already has a final decision' using errcode='PT409'; end if;
  if _status='approved' then
    if account.role not in ('student','tutor') then raise exception 'This account cannot be converted to a tutor' using errcode='22023'; end if;
    select array_agg(s.id) into subject_ids from public.tutor_application_subjects link join public.subjects s on s.id=link.subject_id and s.is_active where link.application_id=_id;
    if coalesce(cardinality(subject_ids),0)=0 or coalesce(a.hourly_rate,0)<=0 or a.highest_qualification is null or a.institution is null
      or not exists(select 1 from public.tutor_application_documents d join storage.objects o on o.bucket_id='tutor-application-documents' and o.name=d.storage_path where d.application_id=_id and d.document_type='identity')
      or not exists(select 1 from public.tutor_application_documents d join storage.objects o on o.bucket_id='tutor-application-documents' and o.name=d.storage_path where d.application_id=_id and d.document_type='qualification')
      then raise exception 'Approval requires qualifications, a rate, active subjects and both uploaded verification documents' using errcode='22023'; end if;
    select * into tutor from public.tutor_profiles where user_id=a.user_id for update;
    if found and tutor.is_approved then raise exception 'This tutor is already approved; use tutor management to edit the profile' using errcode='PT409'; end if;
    insert into public.tutor_profiles(user_id,public_name,bio,city,province,qualification,institution,year_completed,certifications,years_experience,teaching_style,student_age_groups,availability_slots,teaching_modes,hourly_rate,students_per_session,is_approved,is_accepting_students,is_featured,demo_dataset)
      values(a.user_id,concat_ws(' ',coalesce(a.first_name,account.first_name),coalesce(a.last_name,account.last_name)),coalesce(a.teaching_style,''),a.city,a.province,a.highest_qualification,a.institution,a.year_completed,a.certifications,a.years_experience,a.teaching_style,a.student_age_groups,a.availability_slots,a.teaching_modes,a.hourly_rate,a.students_per_session,true,true,false,account.demo_dataset)
      on conflict(user_id) do update set public_name=excluded.public_name,bio=excluded.bio,city=excluded.city,province=excluded.province,qualification=excluded.qualification,institution=excluded.institution,year_completed=excluded.year_completed,certifications=excluded.certifications,years_experience=excluded.years_experience,teaching_style=excluded.teaching_style,student_age_groups=excluded.student_age_groups,availability_slots=excluded.availability_slots,teaching_modes=excluded.teaching_modes,hourly_rate=excluded.hourly_rate,students_per_session=excluded.students_per_session,is_approved=true,is_accepting_students=true,is_featured=false;
    delete from public.tutor_subjects where tutor_id=a.user_id;
    insert into public.tutor_subjects(tutor_id,subject_id) select a.user_id,unnest(subject_ids);
    update public.profiles set role='tutor' where id=a.user_id;
    insert into public.tutor_profile_audit(tutor_id,actor_id,before_data,after_data)
      values(a.user_id,(select auth.uid()),coalesce(to_jsonb(tutor),'{}'::jsonb),(select to_jsonb(tp) from public.tutor_profiles tp where tp.user_id=a.user_id));
  end if;
  update public.tutor_applications set status=_status,review_notes=coalesce(_notes,''),reviewer_id=(select auth.uid()),reviewed_at=now() where id=_id;
  insert into public.tutor_application_reviews(application_id,reviewer_id,previous_status,status,notes) values(_id,(select auth.uid()),a.status,_status,coalesce(_notes,''));
  insert into public.notifications(user_id,kind,title,body,data) values(a.user_id,'application','Tutor application update',case _status when 'approved' then 'Your tutor application was approved. Sign in again to open your tutor dashboard.' when 'rejected' then 'Your tutor application was not approved. View the review notes in your application.' else 'Your tutor application is being reviewed.' end,jsonb_build_object('applicationId',_id,'path','/tutor-application-form'));
  return a.user_id;
end; $;
revoke all on function private.review_tutor_application(uuid,text,text,timestamptz) from public,anon;
grant execute on function private.review_tutor_application(uuid,text,text,timestamptz) to authenticated;
create function public.review_tutor_application(_id uuid,_status text,_notes text,_expected_updated_at timestamptz)
returns uuid language sql security invoker set search_path='' as $$ select private.review_tutor_application(_id,_status,_notes,_expected_updated_at); $$;
revoke all on function public.review_tutor_application(uuid,text,text,timestamptz) from public,anon;
grant execute on function public.review_tutor_application(uuid,text,text,timestamptz) to authenticated;

create policy "Admins can edit student profiles" on public.profiles for update to authenticated
  using(role='student' and (select private.is_platform_admin())) with check(role='student' and (select private.is_platform_admin()));
create function public.admin_update_student(_id uuid,_patch jsonb,_expected_updated_at timestamptz)
returns uuid language plpgsql security invoker set search_path='' as $$
declare account public.profiles; edited public.profiles; key text;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if jsonb_typeof(_patch) is distinct from 'object' then raise exception 'Invalid profile changes' using errcode='22023'; end if;
  for key in select jsonb_object_keys(_patch) loop
    if key<>all(array['first_name','last_name','phone','location','bio']) then raise exception 'Unsupported student field' using errcode='22023'; end if;
  end loop;
  select * into account from public.profiles where id=_id and role='student' for update;
  if not found then raise exception 'Student not found' using errcode='P0002'; end if;
  if _expected_updated_at is null or account.updated_at is distinct from _expected_updated_at then raise exception 'This student changed. Reload before saving.' using errcode='PT409'; end if;
  edited:=jsonb_populate_record(account,_patch);
  if length(btrim(coalesce(edited.first_name,''))) not between 1 and 60 or length(btrim(coalesce(edited.last_name,''))) not between 1 and 60
    or length(coalesce(edited.phone,''))>22 or (coalesce(edited.phone,'')<>'' and edited.phone !~ '^\+?[0-9 ()-]{9,22}$') or length(coalesce(edited.location,''))>200 or length(coalesce(edited.bio,''))>2000 then raise exception 'Enter valid student profile details' using errcode='22023'; end if;
  update public.profiles set first_name=edited.first_name,last_name=edited.last_name,phone=edited.phone,location=edited.location,bio=edited.bio where id=_id;
  return _id;
end; $;
revoke all on function public.admin_update_student(uuid,jsonb,timestamptz) from public,anon;
grant execute on function public.admin_update_student(uuid,jsonb,timestamptz) to authenticated;
notify pgrst,'reload schema';
