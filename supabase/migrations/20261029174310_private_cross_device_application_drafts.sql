create table public.tutor_application_drafts (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  id uuid not null unique,
  application jsonb not null default '{}'::jsonb,
  documents jsonb not null default '[]'::jsonb,
  step integer not null default 1 check(step between 1 and 5),
  furthest_step integer not null default 1 check(furthest_step between 1 and 5),
  version integer not null default 1,
  save_id uuid not null,
  updated_at timestamptz not null default now(),
  check(jsonb_typeof(application)='object' and octet_length(application::text)<=30000),
  check(jsonb_typeof(documents)='array' and jsonb_array_length(documents)<=3 and octet_length(documents::text)<=6000)
);
alter table public.tutor_application_drafts enable row level security;
revoke all on public.tutor_application_drafts from public,anon,authenticated;
grant select on public.tutor_application_drafts to authenticated;
create policy "Applicants read only their own draft" on public.tutor_application_drafts for select to authenticated
  using(user_id=(select auth.uid()));

create function private.save_tutor_application_draft(_id uuid,_application jsonb,_documents jsonb,_step integer,_furthest_step integer,_expected_version integer,_save_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare caller uuid:=(select auth.uid()); previous public.tutor_application_drafts; result public.tutor_application_drafts; item jsonb; field record;
begin
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  perform 1 from public.profiles where id=caller and role in ('student','tutor') for update;
  if not found then raise exception 'Only student or tutor accounts can apply' using errcode='42501'; end if;
  if exists(select 1 from public.tutor_applications where user_id=caller and status in ('submitted','under_review'))
    or exists(select 1 from public.tutor_profiles where user_id=caller and is_approved)
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
    elsif field.key=any(array['firstName','lastName','email','phone','idNumber','address','city','province','highestQualification','institution','yearCompleted','certifications','yearsExperience','previousPlatforms','teachingStyle','hourlyRate','studentsPerSession']) then
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
end; $$;
revoke all on function private.save_tutor_application_draft(uuid,jsonb,jsonb,integer,integer,integer,uuid) from public,anon;
grant execute on function private.save_tutor_application_draft(uuid,jsonb,jsonb,integer,integer,integer,uuid) to authenticated;
create function public.save_tutor_application_draft(_id uuid,_application jsonb,_documents jsonb,_step integer,_furthest_step integer,_expected_version integer,_save_id uuid)
returns jsonb language sql security invoker set search_path='' as $$
  select private.save_tutor_application_draft(_id,_application,_documents,_step,_furthest_step,_expected_version,_save_id);
$$;
revoke all on function public.save_tutor_application_draft(uuid,jsonb,jsonb,integer,integer,integer,uuid) from public,anon;
grant execute on function public.save_tutor_application_draft(uuid,jsonb,jsonb,integer,integer,integer,uuid) to authenticated;

create function private.submit_tutor_application_draft(_id uuid,_data jsonb,_subjects bigint[],_documents jsonb,_draft_version integer)
returns uuid language plpgsql security definer set search_path='' as $$
declare caller uuid:=(select auth.uid());
begin
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  perform 1 from public.profiles where id=caller for update;
  if exists(select 1 from public.tutor_applications where id=_id and user_id=caller) then return _id; end if;
  if not exists(select 1 from public.tutor_application_drafts where user_id=caller and id=_id and version=_draft_version)
    then raise exception 'A newer draft exists. Reload the saved draft before submitting.' using errcode='PT409'; end if;
  return private.submit_tutor_application(_id,_data,_subjects,_documents);
end; $$;
revoke all on function private.submit_tutor_application_draft(uuid,jsonb,bigint[],jsonb,integer) from public,anon;
grant execute on function private.submit_tutor_application_draft(uuid,jsonb,bigint[],jsonb,integer) to authenticated;
create function public.submit_tutor_application_draft(_id uuid,_data jsonb,_subjects bigint[],_documents jsonb,_draft_version integer)
returns uuid language sql security invoker set search_path='' as $$ select private.submit_tutor_application_draft(_id,_data,_subjects,_documents,_draft_version); $$;
revoke all on function public.submit_tutor_application_draft(uuid,jsonb,bigint[],jsonb,integer) from public,anon;
grant execute on function public.submit_tutor_application_draft(uuid,jsonb,bigint[],jsonb,integer) to authenticated;

create function private.clear_submitted_application_draft() returns trigger
language plpgsql security definer set search_path='' as $$ begin
  delete from public.tutor_application_drafts where user_id=new.user_id;
  return new;
end; $$;
revoke all on function private.clear_submitted_application_draft() from public,anon,authenticated;
create trigger clear_submitted_application_draft after insert on public.tutor_applications
  for each row when(new.status='submitted') execute function private.clear_submitted_application_draft();
notify pgrst,'reload schema';
