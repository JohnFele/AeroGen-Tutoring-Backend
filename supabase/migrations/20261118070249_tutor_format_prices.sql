alter table public.tutor_profiles add column online_hourly_rate numeric(10,2), add column in_person_hourly_rate numeric(10,2);
update public.tutor_profiles set online_hourly_rate=hourly_rate,in_person_hourly_rate=hourly_rate;
alter table public.tutor_profiles add constraint tutor_online_rate_positive check(online_hourly_rate>0 and online_hourly_rate<100000000),
  add constraint tutor_in_person_rate_positive check(in_person_hourly_rate>0 and in_person_hourly_rate<100000000);
create function private.sync_tutor_format_prices() returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='UPDATE' and new.hourly_rate is distinct from old.hourly_rate
    and new.online_hourly_rate is not distinct from old.online_hourly_rate
    and new.in_person_hourly_rate is not distinct from old.in_person_hourly_rate
    and new.teaching_modes is not distinct from old.teaching_modes then
    new.online_hourly_rate:=new.hourly_rate; new.in_person_hourly_rate:=new.hourly_rate;
  end if;
  new.online_hourly_rate:=coalesce(new.online_hourly_rate,new.hourly_rate);
  new.in_person_hourly_rate:=coalesce(new.in_person_hourly_rate,new.hourly_rate);
  new.hourly_rate:=case when new.teaching_modes=array['online'] then new.online_hourly_rate
    when new.teaching_modes=array['in-person'] then new.in_person_hourly_rate
    else least(new.online_hourly_rate,new.in_person_hourly_rate) end;
  return new;
end; $$;
create trigger tutor_format_prices before insert or update of hourly_rate,online_hourly_rate,in_person_hourly_rate,teaching_modes
on public.tutor_profiles for each row execute function private.sync_tutor_format_prices();
revoke all on function private.sync_tutor_format_prices() from public,anon,authenticated;
grant update(online_hourly_rate,in_person_hourly_rate) on public.tutor_profiles to authenticated;

CREATE OR REPLACE FUNCTION public.save_my_tutor_listing(_details jsonb, _expected_updated_at timestamp with time zone)
 RETURNS timestamp with time zone
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := (select auth.uid()); current_listing public.tutor_profiles; edited public.tutor_profiles;
begin
  perform private.assert_platform_available();
  perform 1 from public.profiles where id=actor and role='tutor' for update;
  if not found then raise exception 'Tutor access required.' using errcode='42501'; end if;
  select * into current_listing from public.tutor_profiles where user_id=actor for update;
  if not found or not current_listing.is_approved then raise exception 'Tutor approval required.' using errcode='42501'; end if;
  if _expected_updated_at is distinct from current_listing.updated_at then
    raise exception 'Your teaching profile changed. Reload it before saving.' using errcode='PT409';
  end if;
  if jsonb_typeof(_details) is distinct from 'object' then
    raise exception 'Enter valid teaching details.' using errcode='22023';
  end if;
  if exists (select 1 from jsonb_object_keys(_details) as field(key) where key not in
    ('public_name','bio','city','province','teaching_style','teaching_modes','hourly_rate','online_hourly_rate','in_person_hourly_rate','students_per_session')) then
    raise exception 'Only public teaching details can be changed here.' using errcode='22023';
  end if;
  edited := jsonb_populate_record(current_listing,_details);
  if ('online'=any(edited.teaching_modes) and (edited.online_hourly_rate is null or edited.online_hourly_rate<=0 or edited.online_hourly_rate>=100000000))
    or ('in-person'=any(edited.teaching_modes) and (edited.in_person_hourly_rate is null or edited.in_person_hourly_rate<=0 or edited.in_person_hourly_rate>=100000000)) then
    raise exception 'Enter a positive hourly price for each selected lesson format.' using errcode='22023';
  end if;
  if length(btrim(coalesce(edited.public_name,''))) not between 2 and 120
    or edited.bio is null or length(edited.bio)>2000 or length(coalesce(edited.teaching_style,''))>2000
    or length(coalesce(edited.city,''))>150
    or edited.hourly_rate is null or edited.hourly_rate <= 0 or edited.hourly_rate::text in ('NaN','Infinity','-Infinity')
    or coalesce(edited.students_per_session,'') not in ('1','2-4','5-8','9+')
    or coalesce(cardinality(edited.teaching_modes),0) not between 1 and 2
    or not (edited.teaching_modes <@ array['online','in-person']::text[])
    or cardinality(edited.teaching_modes) <> (select count(distinct mode) from unnest(edited.teaching_modes) as modes(mode))
    or (edited.province is not null and edited.province not in ('Eastern Cape','Free State','Gauteng','KwaZulu-Natal','Limpopo','Mpumalanga','Northern Cape','North West','Western Cape'))
    or ('in-person'=any(edited.teaching_modes) and (nullif(btrim(edited.city),'') is null or edited.province is null)) then
    raise exception 'Check your public name, lesson rate, formats, group size and teaching area.' using errcode='22023';
  end if;
  update public.tutor_profiles
  set public_name=btrim(edited.public_name),bio=btrim(edited.bio),city=nullif(btrim(edited.city),''),
      province=edited.province,teaching_style=nullif(btrim(edited.teaching_style),''),
      teaching_modes=edited.teaching_modes,
      online_hourly_rate=edited.online_hourly_rate,in_person_hourly_rate=edited.in_person_hourly_rate,
      hourly_rate=edited.hourly_rate,students_per_session=edited.students_per_session
  where user_id=actor returning updated_at into edited.updated_at;
  return edited.updated_at;
exception
  when data_exception then
    if sqlstate='22023' then raise; end if;
    raise exception 'Enter valid teaching details.' using errcode='22023';
end;
$function$;

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
    if field <> all(array['public_name','bio','city','province','qualification','institution','year_completed','certifications','years_experience','teaching_style','student_age_groups','availability_slots','teaching_modes','hourly_rate','online_hourly_rate','in_person_hourly_rate','students_per_session','is_approved','is_accepting_students','is_featured','avatar_url']) then raise exception 'Unsupported tutor field: %',field using errcode='22023'; end if;
  end loop;
  select * into previous from public.tutor_profiles where user_id=_tutor_id for update;
  if not found then raise exception 'Tutor not found' using errcode='P0002'; end if;
  if _expected_updated_at is not null and previous.updated_at is distinct from _expected_updated_at then raise exception 'This tutor was changed by another administrator. Reload before saving.' using errcode='PT409'; end if;
  edited := jsonb_populate_record(previous,_patch);
  if _patch ? 'online_hourly_rate' or _patch ? 'in_person_hourly_rate' then edited.hourly_rate:=case when edited.teaching_modes=array['online'] then edited.online_hourly_rate when edited.teaching_modes=array['in-person'] then edited.in_person_hourly_rate else least(edited.online_hourly_rate,edited.in_person_hourly_rate) end; end if;
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
    online_hourly_rate=edited.online_hourly_rate,in_person_hourly_rate=edited.in_person_hourly_rate,
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
$function$;

CREATE OR REPLACE FUNCTION public.request_tutoring_booking(_tutor uuid, _student uuid, _subject bigint, _starts_at timestamp with time zone, _duration integer, _mode text, _type text, _notes text, _curriculum text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  select case _mode when 'online' then online_hourly_rate when 'in-person' then in_person_hourly_rate end, teaching_modes, students_per_session into rate, modes, capacity
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
$function$;

create or replace view public.tutor_directory with(security_barrier=true) as
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
) listing join public.tutor_profiles prices on prices.user_id=listing.id;


create function public.my_student_tutors() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if actor is null or not exists(select 1 from public.profiles where id=actor and role='student') then
    raise exception 'Use your own student account to manage tutors.' using errcode='42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(listing)||jsonb_build_object('online_hourly_rate',prices.online_hourly_rate,
    'in_person_hourly_rate',prices.in_person_hourly_rate,'is_accepting_students',prices.is_accepting_students) order by listing.public_name),'[]'::jsonb)
    into result from (SELECT tp.user_id AS id,
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
  WHERE tp.is_approved AND (exists(select 1 from public.saved_tutors st where st.user_id=actor and st.tutor_id=tp.user_id)
 or exists(select 1 from public.bookings b where b.student_id=actor and b.tutor_id=tp.user_id and b.status in ('pending','confirmed','completed','no_show') and b.starts_at>=now()-interval '90 days'))) listing join public.tutor_profiles prices on prices.user_id=listing.id;
  return result;
end; $$;
revoke all on function public.my_student_tutors() from public,anon;
grant execute on function public.my_student_tutors() to authenticated;
