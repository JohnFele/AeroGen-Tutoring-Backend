create table private.student_booking_preferences (
  student_id uuid primary key references public.profiles(id) on delete cascade,
  discoverable boolean not null default false
);
create table private.student_booking_hours (
  student_id uuid not null references private.student_booking_preferences(student_id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_minute smallint not null check (start_minute between 0 and 1410 and start_minute % 30 = 0),
  end_minute smallint not null check (end_minute between 30 and 1440 and end_minute % 30 = 0 and end_minute > start_minute),
  primary key (student_id, weekday)
);
alter table private.student_booking_preferences enable row level security;
alter table private.student_booking_hours enable row level security;
revoke all on private.student_booking_preferences,private.student_booking_hours from public,anon,authenticated;

create function public.my_booking_availability() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); account_role text; hours jsonb; discoverable boolean;
begin
  perform private.assert_platform_available();
  select role into account_role from public.profiles where id=actor;
  if account_role='tutor' then
    select jsonb_agg(to_jsonb(h)-'tutor_id' order by weekday) into hours from public.tutor_booking_hours h where tutor_id=actor;
  else
    select jsonb_agg(to_jsonb(h)-'student_id' order by weekday) into hours from private.student_booking_hours h where student_id=actor;
    select p.discoverable into discoverable from private.student_booking_preferences p where p.student_id=actor;
  end if;
  return jsonb_build_object('hours',coalesce(hours,'[]'::jsonb),'discoverable',coalesce(discoverable,false));
end;
$$;

create function public.save_booking_availability(_hours jsonb,_discoverable boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account();
begin
  perform private.assert_platform_available();
  if exists(select 1 from public.profiles where id=actor and role='tutor') then
    perform public.save_tutor_booking_hours(_hours);
    return;
  end if;
  if jsonb_typeof(_hours) is distinct from 'array' or jsonb_array_length(_hours)>7 or _discoverable is null then
    raise exception 'Enter up to seven days of availability.' using errcode='22023';
  end if;
  if _discoverable and jsonb_array_length(_hours)=0 then
    raise exception 'Add at least one time before making your profile searchable.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(actor::text,367));
  insert into private.student_booking_preferences(student_id,discoverable) values(actor,_discoverable)
    on conflict(student_id) do update set discoverable=excluded.discoverable;
  delete from private.student_booking_hours where student_id=actor;
  insert into private.student_booking_hours(student_id,weekday,start_minute,end_minute)
    select actor,h.weekday,h.start_minute,h.end_minute
    from jsonb_to_recordset(_hours) h(weekday smallint,start_minute smallint,end_minute smallint);
exception when check_violation or unique_violation or not_null_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Choose one valid time range per day.' using errcode='22023';
end;
$$;

create function private.booking_tutor_visible(_tutor uuid,_viewer uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists(select 1 from public.tutor_profiles t join public.profiles p on p.id=t.user_id
    where t.user_id=_tutor and p.role='tutor' and t.is_approved and t.is_accepting_students
      and (t.demo_dataset is null or t.demo_dataset=(select demo_dataset from public.profiles where id=_viewer)));
$$;

create function private.booking_pair_allowed(_tutor uuid,_student uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists(select 1 from public.profiles s join public.tutor_profiles t on t.user_id=_tutor
    where s.id=_student and s.role='student' and s.demo_dataset is not distinct from t.demo_dataset);
$$;

create function private.booking_time_open(_tutor uuid,_student uuid,_starts timestamptz,_duration integer) returns boolean
language sql stable set search_path = '' as $$
  with local_time as (
    select _starts at time zone 'Africa/Johannesburg' as starts,
      _starts+make_interval(mins=>_duration) as ends
  ), slot as (
    select extract(isodow from starts) as weekday, extract(hour from starts)::integer*60+extract(minute from starts)::integer as minute, ends
    from local_time
    where _duration in (30,60,90,120) and _starts >= now()+interval '2 hours'
      and starts::date <= (now() at time zone 'Africa/Johannesburg')::date+29
      and extract(second from starts)=0 and extract(minute from starts) in (0,30)
  )
  select exists(select 1 from slot s
    where exists(select 1 from public.tutor_booking_hours h where h.tutor_id=_tutor and h.weekday=s.weekday
      and h.start_minute<=s.minute and h.end_minute>=s.minute+_duration)
    and (_student is null or not exists(select 1 from private.student_booking_preferences where student_id=_student)
      or exists(select 1 from private.student_booking_hours h where h.student_id=_student and h.weekday=s.weekday
        and h.start_minute<=s.minute and h.end_minute>=s.minute+_duration))
    and not exists(select 1 from public.bookings b where b.status='confirmed' and b.tutor_id=_tutor and b.starts_at<s.ends and b.ends_at>_starts)
    and not exists(select 1 from public.bookings b where b.status='confirmed' and b.student_id=_student and b.starts_at<s.ends and b.ends_at>_starts));
$$;

create function private.matching_booking_starts(_tutor uuid,_student uuid,_duration integer) returns setof timestamptz
language sql stable set search_path = '' as $$
  select slot.starts_at from public.tutor_booking_hours h
  cross join generate_series(0,29) as d(offset_day)
  cross join lateral generate_series(h.start_minute::integer,h.end_minute-_duration,30) as m(minute_of_day)
  cross join lateral (
    select ((now() at time zone 'Africa/Johannesburg')::date+d.offset_day+make_interval(mins=>m.minute_of_day))
      at time zone 'Africa/Johannesburg' as starts_at
  ) slot
  where h.tutor_id=_tutor and _duration in (30,60,90,120)
    and extract(isodow from slot.starts_at at time zone 'Africa/Johannesburg')=h.weekday
    and private.booking_time_open(_tutor,_student,slot.starts_at,_duration)
  order by slot.starts_at;
$$;

create or replace function public.tutor_bookable_slots(_tutor uuid,_duration integer) returns setof timestamptz
language sql stable security definer set search_path = '' as $$
  select s from private.matching_booking_starts(_tutor,null,_duration) s
  where private.platform_runtime_allowed() and private.booking_tutor_visible(_tutor,(select auth.uid()));
$$;

create function public.booking_slot_options(_tutor uuid,_student uuid,_duration integer) returns jsonb
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
  select exists(select 1 from public.tutor_booking_hours where tutor_id=_tutor) into published;
  student_ready := _student is null or actor=_student or exists(select 1 from private.student_booking_hours where student_id=_student);
  return jsonb_build_object('tutorPublished',published,'studentReady',student_ready,'slots',
    case when published and student_ready then coalesce((select jsonb_agg(s order by s)
      from private.matching_booking_starts(_tutor,_student,_duration) s),'[]'::jsonb) else '[]'::jsonb end);
end;
$$;

create function public.tutors_available_at(_starts timestamptz,_duration integer) returns setof uuid
language sql stable security definer set search_path = '' as $$
  with viewer as (
    select auth.uid() as id, (select role from public.profiles where id=auth.uid())='student' as is_student
  )
  select t.user_id from public.tutor_profiles t cross join viewer v
  where private.platform_runtime_allowed() and private.booking_tutor_visible(t.user_id,v.id)
    and (not coalesce(v.is_student,false) or private.booking_pair_allowed(t.user_id,v.id))
    and private.booking_time_open(t.user_id,case when v.is_student then v.id end,_starts,_duration)
  order by t.user_id;
$$;

create function public.search_bookable_students(_query text) returns table(id uuid,name text)
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
    and (p.id::text=term or (pref.discoverable and exists(select 1 from private.student_booking_hours h where h.student_id=p.id)
      and strpos(lower(concat_ws(' ',p.first_name,p.last_name)),term)>0))
  order by 2,1 limit 20;
end;
$$;

revoke all on function private.booking_tutor_visible(uuid,uuid),private.booking_pair_allowed(uuid,uuid),
  private.booking_time_open(uuid,uuid,timestamptz,integer),private.matching_booking_starts(uuid,uuid,integer)
  from public,anon,authenticated;
revoke all on function public.my_booking_availability(),public.save_booking_availability(jsonb,boolean),
  public.booking_slot_options(uuid,uuid,integer),public.tutors_available_at(timestamptz,integer),public.search_bookable_students(text)
  from public,anon,authenticated;
grant execute on function public.my_booking_availability(),public.save_booking_availability(jsonb,boolean),public.search_bookable_students(text) to authenticated;
grant execute on function public.booking_slot_options(uuid,uuid,integer),public.tutors_available_at(timestamptz,integer) to anon,authenticated;

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
  if caller=_tutor and not exists(select 1 from private.student_booking_hours where student_id=_student) then
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

create or replace function private.fund_accepted_booking(_booking uuid,_source text,_succeeds boolean,_request uuid,actor uuid,_accepting boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare lesson public.bookings%rowtype; item private.memberships%rowtype;
  bps integer;
  result jsonb; result_status text; charge uuid; cents integer; target text := _booking::text || ':' || _source;
begin
  perform private.assert_platform_available();
  select * into lesson from public.bookings where id=_booking and student_id=actor;
  if not found then raise exception 'Only the student on this booking can pay.' using errcode='42501'; end if;
  perform private.lock_booking_participants(lesson.student_id,lesson.tutor_id);
  select * into strict lesson from public.bookings where id=_booking for update;
  perform private.billing_lock(actor);
  result := private.billing_replay(actor,_request,'lesson',target);
  if result is not null then return result; end if;
  if _source is null or _source not in ('checkout','package') then raise exception 'Choose a payment method.' using errcode='22023'; end if;
  if lesson.status <> (case when _accepting then 'pending' else 'confirmed' end) or lesson.starts_at <= now() then
    raise exception 'Pay for a confirmed lesson before it starts.' using errcode='PT409';
  end if;
  if exists(select 1 from public.payments where booking_id=lesson.id) then
    raise exception 'This lesson already has a payment.' using errcode='PT409';
  end if;
  cents := round(lesson.total_amount*100);
  if _source='package' then
    item := private.sync_membership(actor);
    if lesson.duration_minutes > 60 or cents > 23000 then
      raise exception 'A credit covers a lesson up to 60 minutes and R230.' using errcode='PT409';
    end if;
    if (private.lesson_credit_balance(actor)->>'available')::bigint < 1 then
      raise exception 'You have no available lesson credits. Choose a separate payment or buy a package.' using errcode='PT409';
    end if;
    if item.period_start is not null then
      update private.memberships set credits_used=credits_used+1 where owner=actor;
    end if;
  end if;
  result_status := private.mock_billing_result(_source='package' or _succeeds);
  result := private.record_mock_billing(actor,_request,'lesson',target,case when _source='package' then 0 else cents end,result_status);
  if result_status='failed' then return result; end if;
  -- The tutor's fee is fixed at checkout; existing payments keep their rate.
  select p.fee_bps into bps from private.billing_plans p where p.id=coalesce((
    select case when m.period_end <= now() and not m.renewal_succeeds then 'basic'
      when m.period_end <= now() then coalesce(m.next_plan_id,m.plan_id) else m.plan_id end
    from private.memberships m where m.owner=lesson.tutor_id
  ),'basic') and p.audience='tutor';
  insert into public.payments(booking_id,payer_id,payee_id,provider,provider_reference,status,amount,platform_fee,paid_at)
  values(lesson.id,actor,lesson.tutor_id,'demo','mock-' || (result->>'id'),'paid',lesson.total_amount,
    round(lesson.total_amount*coalesce(bps,1500)/10000,2),now()) returning id into charge;
  insert into private.lesson_funds(booking_id,payment_id,source,credit_period)
    values(lesson.id,charge,_source,item.period_start);
  perform private.bump_workspace(actor);
  perform private.billing_notice(lesson.tutor_id,'Lesson payment secured','Funds are held until both participants confirm the lesson.','earnings');
  return result;
end;
$$;

revoke all on function private.fund_accepted_booking(uuid,text,boolean,uuid,uuid,boolean) from public,anon,authenticated;

create or replace function public.checkout_booking(_booking uuid,_source text,_succeeds boolean,_request uuid) returns jsonb
language sql security definer set search_path = '' as $$
  select private.fund_accepted_booking(_booking,_source,_succeeds,_request,private.billing_account(),false);
$$;

create or replace function public.respond_to_tutoring_booking(_booking uuid,_action text) returns text
language plpgsql security definer set search_path = '' as $$
declare actor uuid := (select auth.uid()); item public.bookings%rowtype; membership private.memberships%rowtype;
  paid_package boolean; eligible boolean; credits bigint;
begin
  if _action = 'complete' then return public.confirm_lesson_outcome(_booking,true,''); end if;
  if _action not in ('accept','cancel') then return public.respond_to_booking_legacy(_booking,_action); end if;
  perform private.assert_platform_available();
  select * into item from public.bookings where id=_booking and actor in (student_id,tutor_id);
  if not found then raise exception 'This booking is unavailable.' using errcode='42501'; end if;
  perform private.lock_booking_participants(item.student_id,item.tutor_id);
  select * into strict item from public.bookings where id=_booking for update;
  if _action='cancel' and item.status='confirmed' and item.starts_at < now()+interval '2 hours' then
    raise exception 'Online cancellation closes two hours before the lesson. Contact support if you need help.' using errcode='PT409';
  end if;
  if _action='accept' and item.status='pending' then
    if actor=coalesce(item.proposed_by,item.student_id) then
      raise exception 'The other participant must respond to this request.' using errcode='42501';
    end if;
    if not private.booking_tutor_visible(item.tutor_id,actor) or not private.booking_pair_allowed(item.tutor_id,item.student_id)
      or not private.booking_time_open(item.tutor_id,item.student_id,item.starts_at,item.duration_minutes) then
      raise exception 'This time no longer matches both schedules. Ask for another time at least two hours ahead.' using errcode='PT409';
    end if;
    membership := private.sync_membership(item.student_id);
    select p.lesson_credits>0 into paid_package from private.billing_plans p where p.id=membership.plan_id;
    credits := (private.lesson_credit_balance(item.student_id)->>'available')::bigint;
    eligible := item.duration_minutes<=60 and item.total_amount<=230;
    if paid_package and (not eligible or credits<1) then
      raise exception '%',case when not eligible then 'Package bookings must be 60 minutes or less and cost at most R230.'
        else 'The student has no available package credits. No booking was accepted.' end using errcode='PT409';
    end if;
    if eligible and credits>0 then
      perform private.fund_accepted_booking(item.id,'package',true,gen_random_uuid(),item.student_id,true);
    end if;
  end if;
  return public.respond_to_booking_legacy(_booking,_action);
end;
$$;
