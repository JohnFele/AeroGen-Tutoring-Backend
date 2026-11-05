create table private.booking_day_overrides (
  owner uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  start_minute smallint,
  end_minute smallint,
  primary key (owner, day),
  check ((start_minute is null and end_minute is null) or
    (start_minute is not null and end_minute is not null and start_minute between 0 and 1410
      and end_minute between 30 and 1440 and start_minute % 30 = 0 and end_minute % 30 = 0 and end_minute > start_minute))
);
alter table private.booking_day_overrides enable row level security;
revoke all on private.booking_day_overrides from public,anon,authenticated;

-- Convert the known demo seed's two legacy labels into sample hours.
-- Live tutor schedules are only published by their owners.
insert into public.tutor_booking_hours(tutor_id,weekday,start_minute,end_minute)
select t.user_id,d,780,1200
from public.tutor_profiles t cross join generate_series(1,5) d
where t.demo_dataset='aerogen-live-demo-v1' and t.is_approved and t.is_accepting_students
  and t.availability_slots @> array['Weekday Afternoons','Weekday Evenings']
  and not exists(select 1 from public.tutor_booking_hours h where h.tutor_id=t.user_id)
on conflict do nothing;

create function private.booking_local_today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone 'Africa/Johannesburg')::date;
$$;

create function private.booking_day_hours(_owner uuid,_day date,_tutor boolean)
returns table(start_minute smallint,end_minute smallint)
language sql stable set search_path = '' as $$
  with specific as (
    select d.start_minute,d.end_minute from private.booking_day_overrides d where d.owner=_owner and d.day=_day
  )
  select start_minute,end_minute from specific where start_minute is not null
  union all
  select h.start_minute,h.end_minute from public.tutor_booking_hours h
  where _tutor and h.tutor_id=_owner and h.weekday=extract(isodow from _day) and not exists(select 1 from specific)
  union all
  select h.start_minute,h.end_minute from private.student_booking_hours h
  where not _tutor and h.student_id=_owner and h.weekday=extract(isodow from _day) and not exists(select 1 from specific);
$$;

create function private.has_open_booking_hours(_owner uuid,_tutor boolean) returns boolean
language sql stable set search_path = '' as $$
  select exists(select 1 from private.booking_day_overrides d where d.owner=_owner and d.day>=private.booking_local_today()
    and d.start_minute is not null)
    or case when _tutor then exists(select 1 from public.tutor_booking_hours where tutor_id=_owner)
      else exists(select 1 from private.student_booking_hours where student_id=_owner) end;
$$;

create function public.my_booking_day(_day date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); tutor boolean; entry private.booking_day_overrides%rowtype; hours jsonb;
begin
  perform private.assert_platform_available();
  if _day is null or not isfinite(_day) then raise exception 'Choose a valid date.' using errcode='22023'; end if;
  select p.role='tutor' into tutor from public.profiles p where p.id=actor;
  select * into entry from private.booking_day_overrides d where d.owner=actor and d.day=_day;
  select to_jsonb(h) into hours from private.booking_day_hours(actor,_day,tutor) h;
  return jsonb_build_object('mode',case when entry.day is null then 'weekly' when entry.start_minute is null then 'closed' else 'custom' end,
    'hours',hours,'editable',_day between private.booking_local_today() and private.booking_local_today()+365);
end;
$$;

create function public.save_booking_day(_day date,_mode text,_start integer,_end integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account();
begin
  perform private.assert_platform_available();
  if _day is null or _day not between private.booking_local_today() and private.booking_local_today()+365
    or _mode is null or _mode not in ('weekly','closed','custom') then
    raise exception 'Choose a date in the next year and a valid availability option.' using errcode='22023';
  end if;
  if _mode='custom' and (_start is null or _end is null or _start<0 or _end>1440 or _start>=_end
    or _start%30<>0 or _end%30<>0) then
    raise exception 'Choose a valid start and end time in 30-minute increments.' using errcode='22023';
  end if;
  if exists(select 1 from public.profiles where id=actor and role='tutor') and
    not exists(select 1 from public.tutor_profiles where user_id=actor and is_approved) then
    raise exception 'Only approved tutors can publish booking hours.' using errcode='42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,367));
  if _mode='weekly' then
    delete from private.booking_day_overrides where owner=actor and day=_day;
  else
    insert into private.booking_day_overrides(owner,day,start_minute,end_minute)
    values(actor,_day,case when _mode='custom' then _start end,case when _mode='custom' then _end end)
    on conflict(owner,day) do update set start_minute=excluded.start_minute,end_minute=excluded.end_minute;
  end if;
  return public.my_booking_day(_day);
end;
$$;

create or replace function private.booking_time_open(_tutor uuid,_student uuid,_starts timestamptz,_duration integer) returns boolean
language sql stable set search_path = '' as $$
  with local_time as (
    select _starts at time zone 'Africa/Johannesburg' as starts,_starts+make_interval(mins=>_duration) as ends
  ), slot as (
    select starts::date as day,extract(hour from starts)::integer*60+extract(minute from starts)::integer as minute,ends
    from local_time where _duration in (30,60,90,120) and _starts>=now()+interval '2 hours'
      and starts::date<=private.booking_local_today()+29 and extract(second from starts)=0 and extract(minute from starts) in (0,30)
  )
  select exists(select 1 from slot s
    where exists(select 1 from private.booking_day_hours(_tutor,s.day,true) h
      where h.start_minute<=s.minute and h.end_minute>=s.minute+_duration)
    and (_student is null or (
      not exists(select 1 from private.student_booking_preferences where student_id=_student)
      and not private.has_open_booking_hours(_student,false)
      and not exists(select 1 from private.booking_day_overrides d where d.owner=_student and d.day=s.day)
    ) or exists(select 1 from private.booking_day_hours(_student,s.day,false) h
      where h.start_minute<=s.minute and h.end_minute>=s.minute+_duration))
    and not exists(select 1 from public.bookings b where b.status='confirmed' and b.tutor_id=_tutor and b.starts_at<s.ends and b.ends_at>_starts)
    and not exists(select 1 from public.bookings b where b.status='confirmed' and b.student_id=_student and b.starts_at<s.ends and b.ends_at>_starts));
$$;

create or replace function private.matching_booking_starts(_tutor uuid,_student uuid,_duration integer) returns setof timestamptz
language sql stable set search_path = '' as $$
  select slot.starts_at
  from generate_series(0,29) d(offset_day)
  cross join lateral private.booking_day_hours(_tutor,private.booking_local_today()+d.offset_day,true) h
  cross join lateral generate_series(h.start_minute::integer,h.end_minute-_duration,30) m(minute_of_day)
  cross join lateral (
    select ((private.booking_local_today()+d.offset_day+make_interval(mins=>m.minute_of_day))
      at time zone 'Africa/Johannesburg') as starts_at
  ) slot
  where _duration in (30,60,90,120) and private.booking_time_open(_tutor,_student,slot.starts_at,_duration)
  order by slot.starts_at;
$$;

revoke all on function private.booking_local_today(), private.booking_day_hours(uuid,date,boolean),
  private.has_open_booking_hours(uuid,boolean),public.my_booking_day(date),public.save_booking_day(date,text,integer,integer)
  from public,anon,authenticated;
grant execute on function public.my_booking_day(date),public.save_booking_day(date,text,integer,integer) to authenticated;

create or replace function public.booking_slot_options(_tutor uuid,_student uuid,_duration integer) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := (select auth.uid()); published boolean; student_ready boolean;
begin
  perform private.assert_platform_available();
  if _duration is null or _duration not in (30,60,90,120) then
    raise exception 'Choose a valid duration.' using errcode='22023';
  end if;
  if not private.booking_tutor_visible(_tutor,actor) or (_student is not null and (
    (actor is distinct from _student and actor is distinct from _tutor) or not private.booking_pair_allowed(_tutor,_student)
  )) then raise exception 'This booking schedule is unavailable.' using errcode='PT404'; end if;
  published := private.has_open_booking_hours(_tutor,true);
  student_ready := _student is null or actor=_student or private.has_open_booking_hours(_student,false);
  return jsonb_build_object('tutorPublished',published,'studentReady',student_ready,'slots',
    case when published and student_ready then coalesce((select jsonb_agg(s order by s)
      from private.matching_booking_starts(_tutor,_student,_duration) s),'[]'::jsonb) else '[]'::jsonb end);
end;
$$;

create or replace function public.search_bookable_students(_query text) returns table(id uuid,name text)
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := (select auth.uid()); term text := lower(btrim(coalesce(_query,'')));
begin
  perform private.assert_platform_available();
  if actor is null or not private.booking_tutor_visible(actor,actor) then
    raise exception 'Only approved tutors can search for students.' using errcode='42501';
  end if;
  if char_length(term) not between 2 and 80 then raise exception 'Enter a name or a booking code.' using errcode='22023'; end if;
  return query select p.id, coalesce(nullif(btrim(p.first_name),''),'Student') ||
    case when nullif(btrim(p.last_name),'') is null then '' else ' '||left(p.last_name,1)||'.' end
  from public.profiles p
  left join private.student_booking_preferences pref on pref.student_id=p.id
  where p.role='student' and private.booking_pair_allowed(actor,p.id)
    and (p.id::text=term or (pref.discoverable and private.has_open_booking_hours(p.id,false)
      and strpos(lower(concat_ws(' ',p.first_name,p.last_name)),term)>0))
  order by 2,1 limit 20;
end;
$$;

create or replace function public.request_tutoring_booking(_tutor uuid, _student uuid, _subject bigint, _starts_at timestamptz,
  _duration integer, _mode text, _type text, _notes text) returns uuid
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
    and exists (select 1 from public.profiles where id = _tutor and role = 'tutor');
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
    or not exists (select 1 from public.tutor_subjects where tutor_id = _tutor and subject_id = _subject)
  then raise exception 'Choose an offered subject, teaching format and duration.' using errcode = '22023'; end if;

  finish := _starts_at + make_interval(mins => _duration);
  select id into booking_id from public.bookings
  where student_id = _student and tutor_id = _tutor and proposed_by = caller and status in ('pending','confirmed')
    and starts_at = _starts_at and ends_at = finish and subject_id = _subject
    and teaching_mode = _mode and session_type = _type and coalesce(special_requests,'') = btrim(coalesce(_notes,''));
  if found then return booking_id; end if;
  if not private.booking_time_open(_tutor,_student,_starts_at,_duration)
  then raise exception 'That time is no longer available. Choose another time.' using errcode = 'PT409'; end if;
  if exists (select 1 from public.bookings where tutor_id = _tutor and student_id = _student and status = 'pending'
    and starts_at < finish and ends_at > _starts_at)
  then raise exception 'There is already a pending request for this time.' using errcode = 'PT409'; end if;
  insert into public.bookings(student_id,tutor_id,subject_id,starts_at,ends_at,teaching_mode,session_type,duration_minutes,
    hourly_rate,total_amount,special_requests,proposed_by)
  values (_student,_tutor,_subject,_starts_at,finish,_mode,_type,_duration,rate,round(rate * _duration / 60,2),nullif(btrim(_notes),''),caller)
  returning id into booking_id;
  return booking_id;
end;
$$;

notify pgrst, 'reload schema';
