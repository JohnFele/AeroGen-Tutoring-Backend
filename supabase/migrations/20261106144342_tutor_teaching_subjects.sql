alter table public.tutor_subjects add column curriculum_codes text[] not null default '{}';

create function private.teaching_topic_key(label text) returns text
language sql immutable set search_path = '' as $$
  select case normalized when 'english first additional' then 'english first additional language' else normalized end
  from (select btrim(regexp_replace(replace(replace(lower(label),'(9-1)',''),'&',' and '),'[^a-z0-9]+',' ','g')) as normalized) t;
$$;
revoke all on function private.teaching_topic_key(text) from public, anon, authenticated;
grant execute on function private.teaching_topic_key(text) to authenticated;

-- Structured curricula use their official subjects. Provider-specific pathways
-- without a national module list use the catalogue's education-level links.
create view public.teaching_subject_options with (security_invoker=true) as
with routes as (
  select p.code,p.details,
    coalesce(source.details,p.details) as syllabus
  from public.education_pathways p
  left join public.education_pathways source on source.code=p.details->>'subjectSource'
  where p.code <> 'other'
), official as (
  select distinct route.code, private.teaching_topic_key(item->>'name') as topic
  from routes route
  cross join lateral jsonb_array_elements(coalesce(route.details->'levels','[]')) as level(code)
  cross join lateral jsonb_array_elements(coalesce(route.syllabus->'subjects'->(level.code #>> '{}'),
    route.syllabus->'sharedSubjects','[]')) as entry(item)
)
select o.code as curriculum_code,s.id as subject_id
from official o join public.subjects s on s.is_active and private.teaching_topic_key(s.name)=o.topic
union
select route.code,s.id
from routes route
join public.subject_education_levels l on (route.details->'levels') ? l.level_code
join public.subjects s on s.id=l.subject_id and s.is_active
where route.details->>'institutionSpecific'='true' and not exists(select 1 from official o where o.code=route.code);
revoke all on public.teaching_subject_options from public, anon, authenticated;
grant select on public.teaching_subject_options to authenticated;

-- Preserve old listings. Assign a saved subject only when there is one clear
-- match among the tutor's saved curricula. Ambiguous rows stay general.
with matches as (
  select ts.tutor_id,ts.subject_id,array_agg(o.curriculum_code) as codes
  from public.tutor_subjects ts
  join public.profiles p on p.id=ts.tutor_id
  join public.teaching_subject_options o on o.subject_id=ts.subject_id and o.curriculum_code=any(p.curriculum_codes)
  group by ts.tutor_id,ts.subject_id
  having count(*)=1
)
update public.tutor_subjects ts set curriculum_codes=m.codes
from matches m where ts.tutor_id=m.tutor_id and ts.subject_id=m.subject_id;

-- Application approvals and administrator additions keep a subject when its
-- assignment is unambiguous. A tutor reviews any remaining unassigned rows.
create function private.assign_tutor_subject_curriculum() returns trigger
language plpgsql security definer set search_path='' as $$
declare codes text[];
begin
  select array_agg(o.curriculum_code) into codes
  from public.profiles p join public.teaching_subject_options o on o.curriculum_code=any(p.curriculum_codes)
  where p.id=new.tutor_id and p.role='tutor' and o.subject_id=new.subject_id
  having count(*)=1;
  new.curriculum_codes := coalesce(codes,'{}');
  return new;
end;
$$;
create trigger assign_tutor_subject_curriculum before insert on public.tutor_subjects
for each row when (cardinality(new.curriculum_codes)=0) execute function private.assign_tutor_subject_curriculum();
revoke all on function private.assign_tutor_subject_curriculum() from public,anon,authenticated;

create function private.keep_teaching_curricula() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.role='tutor' and exists (
    select 1 from public.tutor_subjects ts where ts.tutor_id=new.id and not (ts.curriculum_codes <@ new.curriculum_codes)
  ) then
    raise exception 'Move or remove subjects from that curriculum in Teaching subjects before removing it.' using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger keep_teaching_curricula before update of curriculum_codes on public.profiles
for each row execute function private.keep_teaching_curricula();
revoke all on function private.keep_teaching_curricula() from public,anon,authenticated;

create function public.save_my_teaching_subjects(_curricula text[],_subjects jsonb,_expected_updated_at timestamptz)
returns timestamptz language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); listing public.tutor_profiles%rowtype;
begin
  perform private.assert_platform_available();
  perform 1 from public.profiles where id=actor and role='tutor' for update;
  if not found then raise exception 'Tutor access required.' using errcode='42501'; end if;
  select * into listing from public.tutor_profiles where user_id=actor for update;
  if not found or not listing.is_approved then raise exception 'Tutor approval required.' using errcode='42501'; end if;
  if _expected_updated_at is distinct from listing.updated_at then
    raise exception 'Your teaching profile changed. Reload it before saving.' using errcode='PT409';
  end if;
  if _curricula is null or jsonb_typeof(_subjects) is distinct from 'array' then
    raise exception 'Choose valid curricula and teaching subjects.' using errcode='22023';
  end if;
  if jsonb_array_length(_subjects) not between 1 and 100 then
    raise exception 'Choose between 1 and 100 teaching subjects.' using errcode='22023';
  end if;
  if jsonb_array_length(_subjects) <> (select count(distinct subject_id) from jsonb_to_recordset(_subjects) as x(subject_id bigint))
    or exists (
      select 1 from jsonb_to_recordset(_subjects) as x(subject_id bigint,curriculum_codes text[])
      left join public.subjects s on s.id=x.subject_id and s.is_active
      where s.id is null or x.curriculum_codes is null
        or (cardinality(_curricula)>0 and cardinality(x.curriculum_codes)=0)
        or not (x.curriculum_codes <@ _curricula)
        or cardinality(x.curriculum_codes) <> (
          select count(*) from public.teaching_subject_options o
          where o.subject_id=x.subject_id and o.curriculum_code=any(x.curriculum_codes)
        )
    ) then
    raise exception 'Assign every subject to a compatible curriculum, or remove it.' using errcode='22023';
  end if;

  delete from public.tutor_subjects where tutor_id=actor;
  update public.profiles set curriculum_codes=_curricula where id=actor;
  insert into public.tutor_subjects(tutor_id,subject_id,curriculum_codes)
    select actor,x.subject_id,x.curriculum_codes from jsonb_to_recordset(_subjects) as x(subject_id bigint,curriculum_codes text[]);
  update public.tutor_profiles set updated_at=now() where user_id=actor returning updated_at into listing.updated_at;
  return listing.updated_at;
end;
$$;
revoke all on function public.save_my_teaching_subjects(text[],jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.save_my_teaching_subjects(text[],jsonb,timestamptz) to authenticated;

grant execute on function private.directory_tutor_curricula(uuid) to anon, authenticated;

create or replace view public.tutor_directory with (security_invoker=true) as
select tp.user_id as id,tp.public_name,tp.bio,tp.city,tp.province,tp.qualification,tp.institution,tp.year_completed,
  tp.certifications,tp.years_experience,tp.teaching_style,tp.student_age_groups,tp.availability_slots,tp.teaching_modes,
  tp.hourly_rate,tp.students_per_session,tp.is_featured,tp.avatar_url,tp.demo_dataset,tp.updated_at,
  coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'slug',s.slug,'aliases',s.aliases,'curriculum_codes',ts.curriculum_codes) order by s.name)
    from public.tutor_subjects ts join public.subjects s on s.id=ts.subject_id and s.is_active
    where ts.tutor_id=tp.user_id and (cardinality(ts.curriculum_codes)>0
      or cardinality(private.directory_tutor_curricula(tp.user_id))=0)),'[]'::jsonb) as subjects,
  coalesce(stats.review_count,0) as review_count,round(stats.average_rating,1) as rating,
  coalesce(stats.completed_sessions,0) as completed_sessions,coalesce(stats.reviewed_students,0) as reviewed_students,
  tp.first_approved_at,
  coalesce(stats.average_rating>=4.8 and stats.reviewed_students>=5 and stats.completed_sessions>=10
    and tp.first_approved_at<=now()-interval '30 days',false) as is_top_rated,
  coalesce(tp.first_approved_at>now()-interval '90 days' and coalesce(stats.completed_sessions,0)<10,false) as is_new,
  private.directory_tutor_curricula(tp.user_id) as curriculum_codes
from public.tutor_profiles tp left join public.tutor_public_stats stats on stats.tutor_id=tp.user_id
where tp.is_approved and tp.is_accepting_students;
notify pgrst,'reload schema';

alter table public.bookings add column curriculum_code text references public.education_pathways(code) on delete restrict;

create function public.request_tutoring_booking(_tutor uuid, _student uuid, _subject bigint, _starts_at timestamptz,
  _duration integer, _mode text, _type text, _notes text, _curriculum text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  caller uuid := (select auth.uid());
  rate numeric;
  modes text[];
  capacity text;
  booking_id uuid;
  finish timestamptz;
begin
  perform private.assert_platform_available();
  if caller is null or _tutor is null or _student is null or _student = _tutor or caller not in (_student, _tutor) then
    raise exception 'Only the student or tutor can make this request.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = _student and role = 'student') then
    raise exception 'Select a student account.' using errcode = '42501';
  end if;
  perform private.lock_booking_participants(_student, _tutor);
  select hourly_rate, teaching_modes, students_per_session into rate, modes, capacity
  from public.tutor_profiles where user_id = _tutor and is_approved and is_accepting_students
    and exists (select 1 from public.profiles where id = _tutor and role = 'tutor')
  for share;
  if not private.booking_pair_allowed(_tutor,_student) then raise exception 'This student is unavailable.' using errcode='PT404'; end if;
  if caller=_tutor and not private.has_open_booking_hours(_student,false) then
    raise exception 'The student needs to set their availability before receiving a request.' using errcode='PT409';
  end if;
  if rate is null or rate <= 0 then raise exception 'This tutor is not taking booking requests.' using errcode = 'PT409'; end if;
  if _duration is null or _duration not in (30,60,90,120) or _starts_at is null
    or _mode is null or not (_mode = any(modes))
    or _type is null or _type not in ('individual','small-group','medium-group')
    or (_type = 'small-group' and coalesce(capacity,'1') = '1')
    or (_type = 'medium-group' and coalesce(capacity,'1') not in ('5-8','9+'))
    or char_length(coalesce(_notes,'')) > 2000
    or not exists (
      select 1 from public.tutor_subjects ts
      join public.profiles p on p.id=ts.tutor_id
      join public.subjects s on s.id=ts.subject_id and s.is_active
      where ts.tutor_id=_tutor and ts.subject_id=_subject
        and (cardinality(ts.curriculum_codes)>0 or cardinality(p.curriculum_codes)=0)
        and (_curriculum is null or _curriculum=any(ts.curriculum_codes))
    )
  then raise exception 'Choose an offered subject, teaching format and duration.' using errcode = '22023'; end if;

  finish := _starts_at + make_interval(mins => _duration);
  select id into booking_id from public.bookings
  where student_id = _student and tutor_id = _tutor and proposed_by = caller and status in ('pending','confirmed')
    and starts_at = _starts_at and ends_at = finish and subject_id = _subject and curriculum_code is not distinct from _curriculum
    and teaching_mode = _mode and session_type = _type and coalesce(special_requests,'') = btrim(coalesce(_notes,''));
  if found then return booking_id; end if;
  if not private.booking_time_open(_tutor,_student,_starts_at,_duration)
  then raise exception 'That time is no longer available. Choose another time.' using errcode = 'PT409'; end if;
  if exists (select 1 from public.bookings where tutor_id = _tutor and student_id = _student and status = 'pending'
    and starts_at < finish and ends_at > _starts_at)
  then raise exception 'There is already a pending request for this time.' using errcode = 'PT409'; end if;
  insert into public.bookings(student_id,tutor_id,subject_id,starts_at,ends_at,teaching_mode,session_type,duration_minutes,
    hourly_rate,total_amount,special_requests,proposed_by,curriculum_code)
  values (_student,_tutor,_subject,_starts_at,finish,_mode,_type,_duration,rate,round(rate * _duration / 60,2),nullif(btrim(_notes),''),caller,_curriculum)
  returning id into booking_id;
  return booking_id;
end;
$$;
revoke all on function public.request_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text,text) from public,anon,authenticated;
grant execute on function public.request_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text,text) to authenticated;

create or replace function public.request_tutoring_booking(_tutor uuid,_student uuid,_subject bigint,_starts_at timestamptz,
  _duration integer,_mode text,_type text,_notes text) returns uuid
language sql security invoker set search_path='' as $$
  select public.request_tutoring_booking(_tutor,_student,_subject,_starts_at,_duration,_mode,_type,_notes,null::text);
$$;
notify pgrst,'reload schema';

CREATE OR REPLACE FUNCTION public.admin_update_tutor(_tutor_id uuid, _patch jsonb, _subject_ids bigint[] DEFAULT NULL::bigint[], _expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare previous public.tutor_profiles; edited public.tutor_profiles; field text; before_subjects jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required' using errcode='42501'; end if;
  if jsonb_typeof(_patch) is distinct from 'object' then raise exception 'Profile changes must be an object' using errcode='22023'; end if;
  for field in select jsonb_object_keys(_patch) loop
    if field <> all(array['public_name','bio','city','province','qualification','institution','year_completed','certifications','years_experience','teaching_style','student_age_groups','availability_slots','teaching_modes','hourly_rate','students_per_session','is_approved','is_accepting_students','is_featured','avatar_url']) then raise exception 'Unsupported tutor field: %',field using errcode='22023'; end if;
  end loop;
  select * into previous from public.tutor_profiles where user_id=_tutor_id for update;
  if not found then raise exception 'Tutor not found' using errcode='P0002'; end if;
  if _expected_updated_at is not null and previous.updated_at is distinct from _expected_updated_at then raise exception 'This tutor was changed by another administrator. Reload before saving.' using errcode='PT409'; end if;
  edited := jsonb_populate_record(previous,_patch);
  edited.is_featured := edited.is_featured and edited.is_approved and edited.is_accepting_students;
  if edited.is_approved and (length(btrim(coalesce(edited.public_name,'')))<2 or coalesce(edited.hourly_rate,0)<=0) then raise exception 'Approved tutors need a public name and positive hourly rate' using errcode='22023'; end if;
  if edited.avatar_url is not null and (length(edited.avatar_url)>2048 or edited.avatar_url !~ '^https://') then raise exception 'Use an HTTPS image URL or leave it empty' using errcode='22023'; end if;
  if _subject_ids is not null and (cardinality(_subject_ids)>100 or exists(select 1 from unnest(_subject_ids) as requested(subject_id) where not exists(select 1 from public.subjects s where s.id=requested.subject_id and s.is_active))) then raise exception 'Choose valid active subjects' using errcode='22023'; end if;
  if edited.is_approved and ((_subject_ids is not null and cardinality(_subject_ids)=0) or (_subject_ids is null and not exists(select 1 from public.tutor_subjects where tutor_id=_tutor_id))) then raise exception 'Approved tutors need at least one subject' using errcode='22023'; end if;
  select coalesce(jsonb_agg(subject_id order by subject_id),'[]'::jsonb) into before_subjects from public.tutor_subjects where tutor_id=_tutor_id;
  update public.tutor_profiles set public_name=edited.public_name,bio=edited.bio,city=edited.city,province=edited.province,
    qualification=edited.qualification,institution=edited.institution,year_completed=edited.year_completed,certifications=edited.certifications,
    years_experience=edited.years_experience,teaching_style=edited.teaching_style,student_age_groups=edited.student_age_groups,
    availability_slots=edited.availability_slots,teaching_modes=edited.teaching_modes,hourly_rate=edited.hourly_rate,
    students_per_session=edited.students_per_session,is_approved=edited.is_approved,is_accepting_students=edited.is_accepting_students,
    is_featured=edited.is_featured,avatar_url=edited.avatar_url where user_id=_tutor_id returning * into edited;
  if _subject_ids is not null then
    delete from public.tutor_subjects where tutor_id=_tutor_id and not (subject_id=any(_subject_ids));
    insert into public.tutor_subjects(tutor_id,subject_id) select _tutor_id,id from (select distinct unnest(_subject_ids) as id) s
    on conflict (tutor_id,subject_id) do nothing;
  end if;
  if previous.is_approved is distinct from edited.is_approved then
    update public.tutor_applications set status=case when edited.is_approved then 'approved' else 'under_review' end,reviewer_id=(select auth.uid()),reviewed_at=now()
      where id=(select id from public.tutor_applications where user_id=_tutor_id order by created_at desc,id desc limit 1);
  end if;
  insert into public.tutor_profile_audit(tutor_id,actor_id,before_data,after_data)
    values(_tutor_id,(select auth.uid()),to_jsonb(previous)||jsonb_build_object('subject_ids',before_subjects),
      to_jsonb(edited)||jsonb_build_object('subject_ids',(select coalesce(jsonb_agg(subject_id order by subject_id),'[]'::jsonb) from public.tutor_subjects where tutor_id=_tutor_id)));
  return jsonb_build_object('id',edited.user_id,'updated_at',edited.updated_at);
end;
$function$

;
notify pgrst,'reload schema';
