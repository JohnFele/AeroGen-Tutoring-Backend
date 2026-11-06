create table private.learner_age_profiles (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  birth_date date not null,
  recorded_at timestamptz not null default now()
);
create table private.learning_tutorial_views (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now()
);
alter table private.learner_age_profiles enable row level security;
alter table private.learning_tutorial_views enable row level security;
revoke all on private.learner_age_profiles,private.learning_tutorial_views from public,anon,authenticated;

alter table private.learning_clearances add column needs_profile_age boolean not null default false;
-- Keep existing plans accessible while requiring the profile field for new sharing.
update private.learning_clearances set needs_profile_age=true
where basis='adult_declaration' and revoked_at is null;

create function private.learning_adult(_birth_date date) returns boolean
language sql stable set search_path='' as $$
  select coalesce(extract(year from age((now() at time zone 'Africa/Johannesburg')::date,_birth_date))>=18,false);
$$;

create function private.learning_age_state(_student uuid) returns text
language plpgsql stable set search_path='' as $$
declare saved date; clearance private.learning_clearances%rowtype;
begin
  select birth_date into saved from private.learner_age_profiles where student_id=_student;
  select * into clearance from private.learning_clearances where student_id=_student;
  if clearance.student_id is not null and clearance.revoked_at is null
    and (clearance.basis='documented_authorisation' or not clearance.needs_profile_age) then return 'enabled'; end if;
  if clearance.revoked_at is not null and not (clearance.needs_profile_age and clearance.basis='adult_declaration') then
    return 'restricted';
  end if;
  if saved is null then return 'missing_birth_date'; end if;
  if private.learning_adult(saved) then return 'adult_eligible'; end if;
  return 'guardian_required';
end;
$$;

create function private.activate_learning_from_profile(_student uuid) returns void
language plpgsql set search_path='' as $$
begin
  if not exists(select 1 from private.learner_age_profiles where student_id=_student and private.learning_adult(birth_date)) then
    raise exception 'Learning access requires an eligible age in your profile or documented guardian authorisation.' using errcode='42501';
  end if;
  insert into private.learning_clearances(student_id,basis,recorded_by)
    values(_student,'adult_declaration',_student)
    on conflict(student_id) do update set revoked_at=null,needs_profile_age=false,recorded_at=now()
    where learning_clearances.needs_profile_age and learning_clearances.basis='adult_declaration';
  if private.learning_age_state(_student)<>'enabled' then
    raise exception 'Learning access is paused. Use Help for assistance.' using errcode='42501';
  end if;
end;
$$;

create function public.my_learner_age_profile() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); saved date;
begin
  if not exists(select 1 from public.profiles where id=actor and role='student') then
    raise exception 'A learner account is required.' using errcode='42501';
  end if;
  select birth_date into saved from private.learner_age_profiles where student_id=actor;
  return jsonb_build_object('birthDate',saved,'ageState',private.learning_age_state(actor));
end;
$$;

create function public.save_my_learner_age_profile(_birth_date date) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  actor uuid := (select auth.uid()); saved date;
  day date := (now() at time zone 'Africa/Johannesburg')::date;
  recipient record;
begin
  perform private.assert_platform_available();
  if not exists(select 1 from public.profiles where id=actor and role='student') then
    raise exception 'A learner account is required.' using errcode='42501';
  end if;
  if _birth_date is null or _birth_date>day or _birth_date<(day-interval '130 years')::date then
    raise exception 'Enter a valid date of birth.' using errcode='22023';
  end if;

  insert into private.learner_age_profiles(student_id,birth_date) values(actor,_birth_date) on conflict do nothing;
  select birth_date into saved from private.learner_age_profiles where student_id=actor for update;
  if saved is distinct from _birth_date then
    raise exception 'A date of birth is already recorded. Use Help if it needs to be corrected.' using errcode='PT409';
  end if;

  if private.learning_adult(saved) and private.learning_age_state(actor)='adult_eligible' then
    perform private.activate_learning_from_profile(actor);
  elsif not private.learning_adult(saved) then
    -- A corrected legacy self-declaration must stop any previous tutor sharing.
    update private.learning_clearances set revoked_at=now()
    where student_id=actor and basis='adult_declaration' and needs_profile_age and revoked_at is null;
    if found then
      for recipient in update private.learning_access a set status='revoked',updated_at=now() from private.learning_plans p
        where p.id=a.plan_id and p.student_id=actor and a.status in ('active','pending') returning a.tutor_id
      loop
        perform private.bump_workspace(recipient.tutor_id);
      end loop;
    end if;
  end if;
  perform private.bump_workspace(actor);
  return public.my_learner_age_profile();
end;
$$;

-- Keep the existing application API stable and stop accepting the old adult checkbox as authorisation.
alter function public.apply_learning_action(text,uuid,integer,uuid,jsonb) set schema private;
revoke all on function private.apply_learning_action(text,uuid,integer,uuid,jsonb) from public,anon,authenticated;
create function public.apply_learning_action(_action text,_plan uuid,_version integer,_request uuid,_data jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); lesson public.bookings%rowtype;
begin
  if _action='enable' then
    perform private.assert_platform_available();
    if not exists(select 1 from public.profiles where id=actor and role='student') then
      raise exception 'A learner account is required.' using errcode='42501';
    end if;
    perform private.activate_learning_from_profile(actor);
    perform private.bump_workspace(actor);
    return jsonb_build_object('enabled',true);
  elsif _action='startPlan' then
    perform private.assert_platform_available();
    lesson := private.learning_eligible_booking(actor,(_data->>'bookingId')::uuid);
    if private.learning_age_state(lesson.student_id)<>'enabled' then
      raise exception 'The learner must complete their profile and learning authorisation before sharing a new plan.' using errcode='42501';
    end if;
  end if;
  return private.apply_learning_action(_action,_plan,_version,_request,_data);
exception when invalid_text_representation then
  raise exception 'Choose a valid lesson.' using errcode='22023';
end;
$$;

alter function public.my_learning_progress(uuid) set schema private;
revoke all on function private.my_learning_progress(uuid) from public,anon,authenticated;
create function public.my_learning_progress(_plan uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); progress jsonb; age_state text;
begin
  progress := private.my_learning_progress(_plan);
  if _plan is not null then return progress; end if;
  if exists(select 1 from public.profiles where id=actor and role='student') then
    age_state := private.learning_age_state(actor);
  end if;
  return progress || jsonb_build_object(
    'ageState',age_state,
    'candidates',coalesce((select jsonb_agg(candidate || jsonb_build_object('ready',
      (candidate->>'ready')::boolean and private.learning_age_state((candidate->>'studentId')::uuid)='enabled') order by seq)
      from jsonb_array_elements(progress->'candidates') with ordinality as items(candidate,seq)),'[]'::jsonb),
    'tutorialSeen',exists(select 1 from private.learning_tutorial_views where user_id=actor)
  );
end;
$$;

create function public.mark_learning_tutorial_seen() returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid());
begin
  perform private.assert_platform_available();
  if not exists(select 1 from public.profiles where id=actor and (role='student' or (role='tutor' and private.learning_tutor_approved(actor)))) then
    raise exception 'A learner or approved tutor account is required.' using errcode='42501';
  end if;
  insert into private.learning_tutorial_views(user_id) values(actor) on conflict do nothing;
end;
$$;

revoke all on function private.learning_adult(date),private.learning_age_state(uuid),private.activate_learning_from_profile(uuid)
from public,anon,authenticated;
revoke all on function public.my_learner_age_profile(),public.save_my_learner_age_profile(date),
  public.apply_learning_action(text,uuid,integer,uuid,jsonb),public.my_learning_progress(uuid),public.mark_learning_tutorial_seen()
from public,anon,authenticated;
grant execute on function public.my_learner_age_profile(),public.save_my_learner_age_profile(date),
  public.apply_learning_action(text,uuid,integer,uuid,jsonb),public.my_learning_progress(uuid),public.mark_learning_tutorial_seen() to authenticated;
notify pgrst,'reload schema';
