-- Owner-only edits to the mutable public teaching profile.
create or replace function public.save_my_tutor_listing(_details jsonb,_expected_updated_at timestamptz)
returns timestamptz language plpgsql security definer set search_path='' as $$
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
    ('public_name','bio','city','province','teaching_style','teaching_modes','hourly_rate','students_per_session')) then
    raise exception 'Only public teaching details can be changed here.' using errcode='22023';
  end if;
  edited := jsonb_populate_record(current_listing,_details);
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
      hourly_rate=edited.hourly_rate,students_per_session=edited.students_per_session
  where user_id=actor returning updated_at into edited.updated_at;
  return edited.updated_at;
exception
  when data_exception then
    if sqlstate='22023' then raise; end if;
    raise exception 'Enter valid teaching details.' using errcode='22023';
end;
$$;

alter table public.profiles
  add column teaching_level_codes text[] not null default '{}',
  add column study_level_code text references public.education_levels(code),
  add column study_grade smallint,
  add column study_subject_ids bigint[] not null default '{}',
  add column study_institution text,
  add column study_programme text,
  add column study_goals text;
grant update (study_level_code,study_grade,study_subject_ids,study_institution,study_programme,study_goals) on public.profiles to authenticated;

with mapped(label,code) as (values
  ('Primary School (Gr 1-3)','foundation'),('Primary School (Gr 4-7)','intermediate'),('Primary School (Gr 4-7)','senior'),
  ('High School (Gr 8-9)','senior'),('High School (Gr 10-12)','fet'),
  ('University/College','college'),('University/College','undergraduate'),('University/College','postgraduate'),('Adult Learners','adult')
), levels as (
  select t.user_id,array_agg(distinct m.code order by m.code) codes
  from public.tutor_profiles t join mapped m on m.label=any(t.student_age_groups)
  group by t.user_id
)
update public.profiles p set teaching_level_codes=l.codes
from levels l where p.id=l.user_id and p.role='tutor';

create view public.teaching_subject_options_by_level with (security_invoker=true) as
with routes as (
  select p.code,p.details,coalesce(source.details,p.details) as syllabus
  from public.education_pathways p
  left join public.education_pathways source on source.code=p.details->>'subjectSource'
  where p.code<>'other'
), official as (
  select distinct r.code,l.level_code,private.teaching_topic_key(entry.item->>'name') topic
  from routes r
  cross join lateral jsonb_array_elements_text(r.details->'levels') l(level_code)
  cross join lateral jsonb_array_elements(coalesce(r.syllabus->'subjects'->l.level_code,r.syllabus->'sharedSubjects','[]')) entry(item)
)
select o.code as curriculum_code,s.id as subject_id,o.level_code
from official o join public.subjects s on s.is_active and private.teaching_topic_key(s.name)=o.topic
union
select r.code,s.id,l.level_code
from routes r
join public.subject_education_levels l on (r.details->'levels') ? l.level_code
join public.subjects s on s.id=l.subject_id and s.is_active
where r.details->>'institutionSpecific'='true' and not exists(select 1 from official o where o.code=r.code);
revoke all on public.teaching_subject_options_by_level from public,anon,authenticated;
grant select on public.teaching_subject_options_by_level to authenticated;

create function private.validate_study_profile() returns trigger
language plpgsql set search_path='' as $$
declare chosen text := new.curriculum_codes[1]; phase public.education_levels;
begin
  if new.role<>'student' then
    if (new.study_level_code,new.study_grade,new.study_subject_ids,new.study_institution,new.study_programme,new.study_goals)
      is distinct from (old.study_level_code,old.study_grade,old.study_subject_ids,old.study_institution,old.study_programme,old.study_goals)
    then raise exception 'Study details can only be saved by students.' using errcode='22023'; end if;
    return new;
  end if;
  if new.study_level_code is not null then
    select * into phase from public.education_levels where code=new.study_level_code and is_active;
    if not found or (chosen is not null and not exists(select 1 from public.education_pathways p
        where p.code=chosen and (p.details->'levels') ? new.study_level_code)) then
      raise exception 'Choose an education phase offered by your curriculum.' using errcode='22023';
    end if;
  end if;
  if new.study_grade is not null and (phase.min_grade is null or new.study_grade not between phase.min_grade and phase.max_grade) then
    raise exception 'Choose a grade within your education phase.' using errcode='22023';
  end if;
  if cardinality(new.study_subject_ids)>30
    or length(coalesce(new.study_institution,''))>150 or length(coalesce(new.study_programme,''))>150
    or length(coalesce(new.study_goals,''))>2000
    or cardinality(new.study_subject_ids) <> (
      select count(*) from public.subjects s where s.id=any(new.study_subject_ids) and s.is_active
        and (case when chosen is null or chosen='other' then
          new.study_level_code is null or exists(select 1 from public.subject_education_levels l where l.subject_id=s.id and l.level_code=new.study_level_code)
        else exists(select 1 from public.teaching_subject_options_by_level o where o.subject_id=s.id and o.curriculum_code=chosen
          and (new.study_level_code is null or o.level_code=new.study_level_code)) end)
    ) then
    raise exception 'Choose up to 30 subjects that match your curriculum and phase, and check the length of your study details.' using errcode='22023';
  end if;
  return new;
end;
$$;
create trigger validate_study_profile before update of curriculum_codes,study_level_code,study_grade,study_subject_ids,study_institution,study_programme,study_goals
on public.profiles for each row execute function private.validate_study_profile();
revoke all on function private.validate_study_profile() from public,anon,authenticated;

create function public.save_my_teaching_subjects(_curricula text[],_levels text[],_subjects jsonb,_expected_updated_at timestamptz)
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
  if _curricula is null or _levels is null or cardinality(_levels) <> (select count(*) from public.education_levels e where e.is_active and e.code=any(_levels)) or jsonb_typeof(_subjects) is distinct from 'array' then
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
        or (cardinality(_levels)>0 and cardinality(x.curriculum_codes)=0 and not exists (
          select 1 from public.subject_education_levels link where link.subject_id=x.subject_id and link.level_code=any(_levels)
        ))
        or cardinality(x.curriculum_codes) <> (
          select count(distinct o.curriculum_code) from public.teaching_subject_options_by_level o
          where o.subject_id=x.subject_id and o.curriculum_code=any(x.curriculum_codes)
            and (cardinality(_levels)=0 or o.level_code=any(_levels))
        )
    ) then
    raise exception 'Assign every subject to a compatible curriculum and teaching phase, or remove it.' using errcode='22023';
  end if;

  delete from public.tutor_subjects where tutor_id=actor;
  update public.profiles set curriculum_codes=_curricula,teaching_level_codes=_levels where id=actor;
  insert into public.tutor_subjects(tutor_id,subject_id,curriculum_codes)
    select actor,x.subject_id,x.curriculum_codes from jsonb_to_recordset(_subjects) as x(subject_id bigint,curriculum_codes text[]);
  update public.tutor_profiles set updated_at=now() where user_id=actor returning updated_at into listing.updated_at;
  return listing.updated_at;
end;
$$;
revoke all on function public.save_my_teaching_subjects(text[],text[],jsonb,timestamptz) from public,anon,authenticated;
grant execute on function public.save_my_teaching_subjects(text[],text[],jsonb,timestamptz) to authenticated;

create or replace function public.save_my_teaching_subjects(_curricula text[],_subjects jsonb,_expected_updated_at timestamptz)
returns timestamptz language sql security invoker set search_path='' as $$
  select public.save_my_teaching_subjects(_curricula,
    coalesce((select teaching_level_codes from public.profiles where id=(select auth.uid())),'{}'),
    _subjects,_expected_updated_at);
$$;
notify pgrst,'reload schema';
