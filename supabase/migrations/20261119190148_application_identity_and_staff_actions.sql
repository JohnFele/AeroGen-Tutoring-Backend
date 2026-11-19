alter table public.profiles add column identity_correction_required boolean not null default false;
alter table public.tutor_applications add column online_hourly_rate numeric(10,2),add column in_person_hourly_rate numeric(10,2);
alter table public.tutor_applications add constraint application_format_rates_valid check(
 (online_hourly_rate is null or online_hourly_rate between 1 and 10000) and
 (in_person_hourly_rate is null or in_person_hourly_rate between 1 and 10000));

create function private.identity_key(_number text) returns text language sql immutable set search_path='' as $$
 select encode(sha256(convert_to(upper(regexp_replace(coalesce(_number,''),'[^a-zA-Z0-9]','','g')),'UTF8')),'hex');
$$;
revoke all on function private.identity_key(text) from public,anon,authenticated;
create table private.tutor_identity_claims(identity_key text primary key,owner uuid not null references public.profiles(id) on delete cascade,created_at timestamptz not null default now());
create index tutor_identity_claims_owner on private.tutor_identity_claims(owner);
create table private.tutor_identity_conflicts(identity_key text not null,owner uuid not null references public.profiles(id) on delete cascade,primary key(identity_key,owner));
create index tutor_identity_conflicts_owner on private.tutor_identity_conflicts(owner);
alter table private.tutor_identity_claims enable row level security;
alter table private.tutor_identity_conflicts enable row level security;
revoke all on private.tutor_identity_claims,private.tutor_identity_conflicts from public,anon,authenticated;
insert into private.tutor_identity_conflicts
 select distinct private.identity_key(a.id_number),a.user_id from public.tutor_applications a
 where nullif(btrim(a.id_number),'') is not null and private.identity_key(a.id_number) in
 (select private.identity_key(id_number) from public.tutor_applications where nullif(btrim(id_number),'') is not null
  group by 1 having count(distinct user_id)>1);
insert into private.tutor_identity_claims(identity_key,owner)
 select private.identity_key(id_number),min(user_id::text)::uuid from public.tutor_applications
 where nullif(btrim(id_number),'') is not null group by 1 having count(distinct user_id)=1;
-- Preserve all existing ID values; affected owners must provide their own correction.
update public.profiles set identity_correction_required=true where id in(select owner from private.tutor_identity_conflicts);
create function private.tutor_identity_is_clear(_user uuid) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select not identity_correction_required from public.profiles where id=_user),false);
$$;
revoke all on function private.tutor_identity_is_clear(uuid) from public,anon,authenticated;
grant execute on function private.tutor_identity_is_clear(uuid) to anon,authenticated;
alter policy "Approved tutors are discoverable" on public.tutor_profiles
 using(is_approved and is_accepting_students and demo_dataset is null and private.tutor_identity_is_clear(user_id));
create or replace function private.booking_tutor_visible(_tutor uuid,_viewer uuid) returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.tutor_profiles t join public.profiles p on p.id=t.user_id
  where t.user_id=_tutor and p.role='tutor' and not p.identity_correction_required and t.is_approved and t.is_accepting_students
   and (t.demo_dataset is null or t.demo_dataset=(select demo_dataset from public.profiles where id=_viewer)));
$$;

create function private.claim_tutor_identity() returns trigger language plpgsql security definer set search_path='' as $$
declare fingerprint text; owner_id uuid; correcting boolean;
begin
 if tg_op='UPDATE' and new.id_number is not distinct from old.id_number and new.user_id=old.user_id then return new;end if;
 if length(regexp_replace(coalesce(new.id_number,''),'[^a-zA-Z0-9]','','g')) not between 4 and 100 then
  raise exception 'Enter the ID or passport number shown on your identity document.' using errcode='PT422';end if;
 fingerprint:=private.identity_key(new.id_number);
 perform pg_advisory_xact_lock(hashtextextended(fingerprint,0));
 if exists(select 1 from private.tutor_identity_conflicts where identity_key=fingerprint) then
  raise exception 'This identity number needs correction or a support review. Use the number on your own document; do not invent a different ID.' using errcode='PT422';end if;
 insert into private.tutor_identity_claims(identity_key,owner) values(fingerprint,new.user_id) on conflict do nothing;
 select owner into owner_id from private.tutor_identity_claims where identity_key=fingerprint;
 if owner_id<>new.user_id then raise exception 'This identity number is already linked to an account. Sign in to that account or contact support.' using errcode='PT422';end if;
 select identity_correction_required into correcting from public.profiles where id=new.user_id for update;
 if correcting then
  update public.tutor_profiles set is_featured=false,is_accepting_students=false,is_approved=false where user_id=new.user_id;
  update public.profiles set identity_correction_required=false where id=new.user_id;
 end if;
 return new;
end;$$;
revoke all on function private.claim_tutor_identity() from public,anon,authenticated;
create trigger claim_tutor_identity before insert or update of id_number,user_id on public.tutor_applications
 for each row execute function private.claim_tutor_identity();

create table private.staff_role_audit(id uuid primary key default gen_random_uuid(),actor uuid not null references public.profiles(id),target uuid not null references public.profiles(id),previous_role text not null,new_role text not null,created_at timestamptz not null default now());
create index staff_role_audit_target on private.staff_role_audit(target,created_at desc);
create index staff_role_audit_actor on private.staff_role_audit(actor,created_at desc);
alter table private.staff_role_audit enable row level security;
revoke all on private.staff_role_audit from public,anon,authenticated;
create function public.promote_platform_admin(_user uuid,_expected timestamptz) returns jsonb
language plpgsql security definer set search_path='' as $$
declare target public.profiles;
begin
 if not private.is_platform_admin() then raise exception 'Verified administrator access required.' using errcode='42501';end if;
 select * into target from public.profiles where id=_user for update;
 if target.id is null or target.demo_dataset is not null then raise exception 'User unavailable.' using errcode='PT404';end if;
 if target.role='admin' then return jsonb_build_object('id',target.id,'role','admin');end if;
 if target.identity_correction_required then raise exception 'This user must correct their identity information before access can be changed.' using errcode='42501';end if;
 if target.id=auth.uid() or target.role not in('student','tutor') then raise exception 'Only student or tutor accounts can be promoted to administrator.' using errcode='42501';end if;
 if target.updated_at is distinct from _expected then raise exception 'The account changed. Reload before changing access.' using errcode='PT409';end if;
 update public.profiles set role='admin' where id=target.id;
 if target.role='tutor' then update public.tutor_profiles set is_featured=false,is_accepting_students=false where user_id=target.id;end if;
 insert into private.staff_role_audit(actor,target,previous_role,new_role) values(auth.uid(),target.id,target.role,'admin');
 insert into public.notifications(user_id,kind,title,body,data) values(target.id,'system','Administrator access granted','Your account now has administrator access. An authenticator is required before opening the admin dashboard.',jsonb_build_object('tab','overview'));
 return jsonb_build_object('id',target.id,'role','admin');
end;$$;
revoke all on function public.promote_platform_admin(uuid,timestamptz) from public,anon,authenticated;
grant execute on function public.promote_platform_admin(uuid,timestamptz) to authenticated;

create function public.record_booking_action_failure(_booking uuid,_action text,_request uuid) returns uuid
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null or _action not in('accept','decline','cancel') or _request is null or not exists(
  select 1 from public.bookings where id=_booking and auth.uid() in(student_id,tutor_id)) then raise exception 'Booking unavailable.' using errcode='42501';end if;
 if (select count(*) from public.notifications where user_id=auth.uid() and data->>'actionFailure'='true' and created_at>now()-interval '1 day')>=20 then return null;end if;
 insert into public.notifications(id,user_id,kind,title,body,data) values(_request,auth.uid(),'system','Lesson update was not saved',
  'Your attempt to '||_action||' the lesson was not confirmed. Review the current booking before trying again.',jsonb_build_object('tab','calendar','bookingId',_booking,'actionFailure',true,'event','booking_action_failed')) on conflict(id) do nothing;
 return _request;
end;$$;
revoke all on function public.record_booking_action_failure(uuid,text,uuid) from public,anon,authenticated;
grant execute on function public.record_booking_action_failure(uuid,text,uuid) to authenticated;
CREATE OR REPLACE FUNCTION private.notification_preference()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare preference public.user_notification_preferences; actor uuid := (select auth.uid());
begin
  if new.kind='booking' and current_setting('aerogen.creating_booking_series',true)='yes' then return null; end if;
  if new.user_id=actor and coalesce(new.data->>'event','') not in ('ticket_opened','subscription_renewal','daily_reminder','booking_action_failed') then return null; end if;
  select * into preference from public.user_notification_preferences where user_id=new.user_id;
  if (new.kind='message' and not coalesce(preference.push_messages,true))
    or (new.kind in ('booking','calendar') and not coalesce(preference.push_booking_updates,true))
    or (new.kind='payment' and not coalesce(preference.push_payment_updates,true)) then return null; end if;
  return new;
end; $function$;


create function public.my_logout_summary() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid:=auth.uid(); account_role text; lessons integer; hours numeric; people integer; resolved integer; assigned integer;
begin
 if actor is null then raise exception 'Sign in required.' using errcode='42501';end if;
 select role into account_role from public.profiles where id=actor;
 if account_role in('admin','superUser') then
  select count(*) filter(where status='resolved'),count(*) filter(where status<>'resolved') into resolved,assigned
   from public.booking_safety_cases where assigned_to=actor;
  return jsonb_build_object('role',account_role,'stats',jsonb_build_array(jsonb_build_object('label','Tickets resolved','value',resolved),jsonb_build_object('label','Open assigned tickets','value',assigned)));
 end if;
 select count(*),coalesce(round(sum(duration_minutes)/60.0,1),0),count(distinct case when account_role='tutor' then student_id else tutor_id end)
  into lessons,hours,people from public.bookings where status='completed' and case when account_role='tutor' then tutor_id=actor else student_id=actor end;
 return jsonb_build_object('role',account_role,'stats',jsonb_build_array(jsonb_build_object('label','Lessons completed','value',lessons),
  jsonb_build_object('label',case when account_role='tutor' then 'Teaching hours' else 'Learning hours' end,'value',hours),
  jsonb_build_object('label',case when account_role='tutor' then 'Learners helped' else 'Tutors learned with' end,'value',people)));
end;$$;
revoke all on function public.my_logout_summary() from public,anon,authenticated;
grant execute on function public.my_logout_summary() to authenticated;
CREATE OR REPLACE FUNCTION private.save_tutor_application_draft(_id uuid, _application jsonb, _documents jsonb, _step integer, _furthest_step integer, _expected_version integer, _save_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare caller uuid:=(select auth.uid()); previous public.tutor_application_drafts; result public.tutor_application_drafts; item jsonb; field record;
begin
  perform private.assert_platform_available();
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  perform 1 from public.profiles where id=caller and role in ('student','tutor') for update;
  if not found then raise exception 'Only student or tutor accounts can apply' using errcode='42501'; end if;
  if (exists(select 1 from public.tutor_applications where user_id=caller and status in ('submitted','under_review'))
    or exists(select 1 from public.tutor_profiles where user_id=caller and is_approved)) and not exists(select 1 from public.profiles where id=caller and identity_correction_required)
    then raise exception 'An application is already submitted or approved' using errcode='PT409'; end if;
  select * into previous from public.tutor_application_drafts where user_id=caller for update;
  if found then
    if previous.save_id=_save_id then return to_jsonb(previous); end if;
    if previous.version is distinct from _expected_version or previous.id<>_id then
      raise exception 'A newer draft was saved on another device. Reload the saved draft before saving again.' using errcode='PT409'; end if;
  elsif _expected_version is not null then raise exception 'This draft changed. Reload it before saving.' using errcode='PT409'; end if;
  if _id is null or _save_id is null or _step is null or _step not between 1 and 5 or _furthest_step is null or _furthest_step not between _step and 5
    or jsonb_typeof(_application) is distinct from 'object' or octet_length(_application::text)>30000
    then raise exception 'Invalid draft details' using errcode='22023'; end if;
  for field in select * from jsonb_each(_application) loop
    if field.key=any(array['subjects','studentAgeGroups','availability','teachingMode']) then
      if jsonb_typeof(field.value)<>'array' or jsonb_array_length(field.value)>30 then raise exception 'Invalid draft choices' using errcode='22023'; end if;
      if exists(select 1 from jsonb_array_elements(field.value) v where jsonb_typeof(v)<>'string' or length(v#>>'{}')>100) then raise exception 'Invalid draft choice' using errcode='22023'; end if;
    elsif field.key=any(array['firstName','lastName','email','phone','idNumber','address','city','province','highestQualification','institution','yearCompleted','certifications','yearsExperience','previousPlatforms','teachingStyle','hourlyRate','onlineHourlyRate','inPersonHourlyRate','studentsPerSession']) then
      if jsonb_typeof(field.value)<>'string' or length(field.value#>>'{}')>2000 then raise exception 'Invalid draft text' using errcode='22023'; end if;
    else raise exception 'Unsupported draft field' using errcode='22023'; end if;
  end loop;
  if jsonb_typeof(_documents) is distinct from 'array' or jsonb_array_length(_documents)>3 or octet_length(_documents::text)>6000
    then raise exception 'Invalid draft documents' using errcode='22023'; end if;
  if (select count(distinct v->>'kind') from jsonb_array_elements(_documents) v)<>jsonb_array_length(_documents)
    then raise exception 'Choose one file for each document type' using errcode='22023'; end if;
  for item in select * from jsonb_array_elements(_documents) loop
    if coalesce(item->>'kind','') not in ('idDocument','qualificationDocument','resume')
      or (item->>'id')::uuid is null or length(coalesce(item->>'name','')) not between 1 and 120
      or coalesce(item->>'path','') not like caller::text||'/'||_id::text||'/%'
      or coalesce((item->>'size')::bigint,0) not between 1 and (case when item->>'kind'='qualificationDocument' then 10485760 else 5242880 end)
      or coalesce(item->>'mime','') not in ('application/pdf','image/jpeg','image/png','application/vnd.openxmlformats-officedocument.wordprocessingml.document')
      or (item->>'mime'='application/vnd.openxmlformats-officedocument.wordprocessingml.document' and item->>'kind'<>'resume')
      or not exists(select 1 from storage.objects o where o.bucket_id='tutor-application-documents' and o.name=item->>'path'
        and o.metadata->>'mimetype'=item->>'mime' and (o.metadata->>'size')::bigint=(item->>'size')::bigint)
      then raise exception 'Upload valid private draft files first' using errcode='22023'; end if;
  end loop;
  insert into public.tutor_application_drafts(user_id,id,application,documents,step,furthest_step,version,save_id)
    values(caller,_id,_application,_documents,_step,_furthest_step,coalesce(previous.version,0)+1,_save_id)
    on conflict(user_id) do update set application=excluded.application,documents=excluded.documents,step=excluded.step,
      furthest_step=excluded.furthest_step,version=excluded.version,save_id=excluded.save_id,updated_at=now()
    returning * into result;
  return to_jsonb(result);
end; $function$;

CREATE OR REPLACE FUNCTION private.submit_tutor_application(_id uuid, _data jsonb, _subjects bigint[], _documents jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare caller uuid:=(select auth.uid()); account public.profiles; a public.tutor_applications; d jsonb; key text;
begin
  perform private.assert_platform_available();
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select * into account from public.profiles where id=caller for update;
  if not found or account.role not in ('student','tutor') then raise exception 'Only student or tutor accounts can apply' using errcode='42501'; end if;
  if exists(select 1 from public.tutor_applications where id=_id and user_id=caller) then return _id; end if;
  if exists(select 1 from public.tutor_profiles where user_id=caller and is_approved) and not account.identity_correction_required then raise exception 'You already have an approved tutor profile' using errcode='PT409'; end if;
  if exists(select 1 from public.tutor_applications where user_id=caller and status in ('submitted','under_review')) and not account.identity_correction_required then raise exception 'An application is already awaiting review' using errcode='PT409'; end if;
  if jsonb_typeof(_data) is distinct from 'object' or octet_length(_data::text)>30000 then raise exception 'Invalid application' using errcode='22023'; end if;
  for key in select jsonb_object_keys(_data) loop
    if key <> all(array['first_name','last_name','contact_email','id_number','phone','street_address','city','province','highest_qualification','institution','year_completed','certifications','years_experience','experience_range','previous_platforms','student_age_groups','teaching_style','availability_slots','teaching_modes','hourly_rate','online_hourly_rate','in_person_hourly_rate','students_per_session']) then raise exception 'Unsupported application field' using errcode='22023'; end if;
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
    or a.hourly_rate is null or a.hourly_rate not between 1 and 10000
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
  if account.identity_correction_required then update public.tutor_applications set status='rejected',review_notes='Identity details require correction; replaced by the owner’s corrected submission.' where user_id=caller and status in ('submitted','under_review'); end if;
  insert into public.tutor_applications(id,user_id,status,first_name,last_name,contact_email,id_number,phone,street_address,city,province,highest_qualification,institution,year_completed,certifications,years_experience,experience_range,previous_platforms,student_age_groups,teaching_style,availability_slots,teaching_modes,hourly_rate,online_hourly_rate,in_person_hourly_rate,students_per_session,submitted_at)
    values(_id,caller,'submitted',a.first_name,a.last_name,a.contact_email,a.id_number,a.phone,a.street_address,a.city,a.province,a.highest_qualification,a.institution,a.year_completed,a.certifications,a.years_experience,a.experience_range,a.previous_platforms,a.student_age_groups,a.teaching_style,a.availability_slots,a.teaching_modes,a.hourly_rate,case when 'online'=any(a.teaching_modes) then coalesce(a.online_hourly_rate,a.hourly_rate) end,case when 'in-person'=any(a.teaching_modes) then coalesce(a.in_person_hourly_rate,a.hourly_rate) end,a.students_per_session,now());
  insert into public.tutor_application_subjects(application_id,subject_id) select _id,id from (select distinct unnest(_subjects) id) s;
  insert into public.tutor_application_documents(application_id,document_type,storage_path,original_filename,mime_type,size_bytes)
    select _id,v->>'document_type',v->>'storage_path',v->>'original_filename',v->>'mime_type',(v->>'size_bytes')::bigint from jsonb_array_elements(_documents) v;
  insert into public.notifications(user_id,kind,title,body,data)
    select p.id,'application','New tutor application',a.first_name||' '||a.last_name||' submitted a tutor application.',jsonb_build_object('tab','applications','applicationId',_id)
    from public.profiles p where p.role in ('admin','superUser');
  return _id;
end; $function$;
CREATE OR REPLACE FUNCTION private.review_tutor_application(_id uuid, _status text, _notes text, _expected_updated_at timestamp with time zone)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    if account.identity_correction_required then raise exception 'The applicant must correct their identity details before approval.' using errcode='PT422';end if;
    if account.role not in ('student','tutor') then raise exception 'This account cannot be converted to a tutor' using errcode='22023'; end if;
    select array_agg(s.id) into subject_ids from public.tutor_application_subjects link join public.subjects s on s.id=link.subject_id and s.is_active where link.application_id=_id;
    if coalesce(cardinality(subject_ids),0)=0 or coalesce(a.hourly_rate,0)<=0 or a.highest_qualification is null or a.institution is null
      or not exists(select 1 from public.tutor_application_documents d join storage.objects o on o.bucket_id='tutor-application-documents' and o.name=d.storage_path where d.application_id=_id and d.document_type='identity')
      or not exists(select 1 from public.tutor_application_documents d join storage.objects o on o.bucket_id='tutor-application-documents' and o.name=d.storage_path where d.application_id=_id and d.document_type='qualification')
      then raise exception 'Approval requires qualifications, a rate, active subjects and both uploaded verification documents' using errcode='22023'; end if;
    select * into tutor from public.tutor_profiles where user_id=a.user_id for update;
    if found and tutor.is_approved then raise exception 'This tutor is already approved; use tutor management to edit the profile' using errcode='PT409'; end if;
    insert into public.tutor_profiles(user_id,public_name,bio,city,province,qualification,institution,year_completed,certifications,years_experience,teaching_style,student_age_groups,availability_slots,teaching_modes,hourly_rate,online_hourly_rate,in_person_hourly_rate,students_per_session,is_approved,is_accepting_students,is_featured,demo_dataset)
      values(a.user_id,concat_ws(' ',coalesce(a.first_name,account.first_name),coalesce(a.last_name,account.last_name)),coalesce(a.teaching_style,''),a.city,a.province,a.highest_qualification,a.institution,a.year_completed,a.certifications,a.years_experience,a.teaching_style,a.student_age_groups,a.availability_slots,a.teaching_modes,a.hourly_rate,case when 'online'=any(a.teaching_modes) then coalesce(a.online_hourly_rate,a.hourly_rate) end,case when 'in-person'=any(a.teaching_modes) then coalesce(a.in_person_hourly_rate,a.hourly_rate) end,a.students_per_session,true,true,false,account.demo_dataset)
      on conflict(user_id) do update set public_name=excluded.public_name,bio=excluded.bio,city=excluded.city,province=excluded.province,qualification=excluded.qualification,institution=excluded.institution,year_completed=excluded.year_completed,certifications=excluded.certifications,years_experience=excluded.years_experience,teaching_style=excluded.teaching_style,student_age_groups=excluded.student_age_groups,availability_slots=excluded.availability_slots,teaching_modes=excluded.teaching_modes,hourly_rate=excluded.hourly_rate,online_hourly_rate=excluded.online_hourly_rate,in_person_hourly_rate=excluded.in_person_hourly_rate,students_per_session=excluded.students_per_session,is_approved=true,is_accepting_students=true,is_featured=false;
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
end; $function$;
notify pgrst,'reload schema';

create or replace view public.tutor_directory with(security_invoker=true,security_barrier=true) as
select listing.*, prices.online_hourly_rate, prices.in_person_hourly_rate from (
SELECT tp.user_id AS id,
    tp.public_name,
    tp.bio,
    tp.city,
    tp.province,
    tp.qualification,
    tp.institution,
    tp.year_completed,
    tp.certifications,
    tp.years_experience,
    tp.teaching_style,
    tp.student_age_groups,
    tp.availability_slots,
    tp.teaching_modes,
    tp.hourly_rate,
    tp.students_per_session,
    tp.is_featured,
    tp.avatar_url,
    tp.demo_dataset,
    tp.updated_at,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'slug', s.slug, 'aliases', s.aliases, 'curriculum_codes', ts.curriculum_codes) ORDER BY s.name) AS jsonb_agg
           FROM public.tutor_subjects ts
             JOIN public.subjects s ON s.id = ts.subject_id AND s.is_active
          WHERE ts.tutor_id = tp.user_id AND (cardinality(ts.curriculum_codes) > 0 OR cardinality(private.directory_tutor_curricula(tp.user_id)) = 0)), '[]'::jsonb) AS subjects,
    COALESCE(stats.review_count, 0) AS review_count,
    round(stats.average_rating, 1) AS rating,
    COALESCE(stats.completed_sessions, 0) AS completed_sessions,
    COALESCE(stats.reviewed_students, 0) AS reviewed_students,
    tp.first_approved_at,
    COALESCE(stats.average_rating >= 4.8 AND stats.reviewed_students >= 5 AND stats.completed_sessions >= 10 AND tp.first_approved_at <= (now() - '30 days'::interval), false) AS is_top_rated,
    COALESCE(tp.first_approved_at > (now() - '90 days'::interval) AND COALESCE(stats.completed_sessions, 0) < 10, false) AS is_new,
    private.directory_tutor_curricula(tp.user_id) AS curriculum_codes
   FROM public.tutor_profiles tp
     LEFT JOIN public.tutor_public_stats stats ON stats.tutor_id = tp.user_id
  WHERE tp.is_approved AND tp.is_accepting_students
) listing join public.tutor_profiles prices on prices.user_id=listing.id where listing.demo_dataset is null and private.tutor_identity_is_clear(listing.id);




notify pgrst,'reload schema';
