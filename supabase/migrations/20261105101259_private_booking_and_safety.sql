-- Private booking requests, bookable hours and case-scoped review.
alter table public.bookings
  add column proposed_by uuid references public.profiles(id) on delete restrict,
  add column confirmed_at timestamptz,
  add constraint bookings_proposer_is_participant check (proposed_by in (student_id, tutor_id));

create index bookings_proposed_by_idx on public.bookings(proposed_by) where proposed_by is not null;
drop policy "Admins can read bookings" on public.bookings;
drop policy "Admins can read payments" on public.payments;

create table public.tutor_booking_hours (
  tutor_id uuid not null references public.tutor_profiles(user_id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  start_minute smallint not null check (start_minute between 0 and 1410 and start_minute % 30 = 0),
  end_minute smallint not null check (end_minute between 30 and 1440 and end_minute % 30 = 0 and end_minute > start_minute),
  primary key (tutor_id, weekday)
);
alter table public.tutor_booking_hours enable row level security;
revoke all on public.tutor_booking_hours from public, anon, authenticated;
grant select on public.tutor_booking_hours to authenticated;
create policy "Tutors read their own booking hours" on public.tutor_booking_hours for select to authenticated
  using (tutor_id = (select auth.uid()) and (select private.platform_runtime_allowed()));

create function public.save_tutor_booking_hours(_hours jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare caller uuid := (select auth.uid());
begin
  perform private.assert_platform_available();
  if caller is null or not exists (
    select 1 from public.tutor_profiles t join public.profiles p on p.id = t.user_id
    where t.user_id = caller and t.is_approved and p.role = 'tutor'
  ) then raise exception 'Only approved tutors can set their hours.' using errcode = '42501'; end if;
  if jsonb_typeof(_hours) is distinct from 'array' or jsonb_array_length(_hours) > 7 then
    raise exception 'Enter up to seven days of availability.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(caller::text, 367));
  delete from public.tutor_booking_hours where tutor_id = caller;
  insert into public.tutor_booking_hours(tutor_id, weekday, start_minute, end_minute)
  select caller, h.weekday, h.start_minute, h.end_minute
  from jsonb_to_recordset(_hours) as h(weekday smallint, start_minute smallint, end_minute smallint);
end;
$$;
revoke all on function public.save_tutor_booking_hours(jsonb) from public, anon, authenticated;
grant execute on function public.save_tutor_booking_hours(jsonb) to authenticated;

-- Only selectable starts are returned. No booking identities, notes, or busy events are exposed.
create function public.tutor_bookable_slots(_tutor uuid, _duration integer) returns setof timestamptz
language sql stable security definer set search_path = '' as $$
  select slot.starts_at
  from public.tutor_profiles t
  join public.tutor_booking_hours h on h.tutor_id = t.user_id
  cross join generate_series(0, 13) as d(day_offset)
  cross join lateral generate_series(h.start_minute::integer, h.end_minute - _duration, 30) as m(minute_of_day)
  cross join lateral (
    select (((now() at time zone 'Africa/Johannesburg')::date + d.day_offset)::timestamp
      + make_interval(mins => m.minute_of_day)) at time zone 'Africa/Johannesburg' as starts_at
  ) slot
  where t.user_id = _tutor and t.is_approved and t.is_accepting_students
    and private.platform_runtime_allowed() and _duration in (30, 60, 90, 120)
    and extract(isodow from (slot.starts_at at time zone 'Africa/Johannesburg')) = h.weekday
    and slot.starts_at > now()
    and not exists (
      select 1 from public.bookings b where b.tutor_id = t.user_id and b.status = 'confirmed'
        and b.starts_at < slot.starts_at + make_interval(mins => _duration) and b.ends_at > slot.starts_at
    )
  order by slot.starts_at;
$$;
revoke all on function public.tutor_bookable_slots(uuid, integer) from public, anon, authenticated;
grant execute on function public.tutor_bookable_slots(uuid, integer) to anon, authenticated;

create function private.lock_booking_participants(_student uuid, _tutor uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtextextended(least(_student, _tutor)::text, 367));
  perform pg_advisory_xact_lock(hashtextextended(greatest(_student, _tutor)::text, 367));
end;
$$;
revoke all on function private.lock_booking_participants(uuid, uuid) from public, anon, authenticated;

create function public.request_tutoring_booking(_tutor uuid, _student uuid, _subject bigint, _starts_at timestamptz,
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
  if not exists (select 1 from public.tutor_bookable_slots(_tutor, _duration) as slot where slot = _starts_at)
    or exists (select 1 from public.bookings where student_id = _student and status = 'confirmed'
      and starts_at < finish and ends_at > _starts_at)
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
revoke all on function public.request_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text) from public, anon, authenticated;
grant execute on function public.request_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text) to authenticated;

create function public.respond_to_tutoring_booking(_booking uuid, _action text) returns text
language plpgsql security definer set search_path = '' as $$
declare caller uuid := (select auth.uid()); item public.bookings%rowtype; next_status text;
begin
  perform private.assert_platform_available();
  select * into item from public.bookings where id = _booking;
  if not found or caller is null or caller not in (item.student_id,item.tutor_id) then
    raise exception 'This booking is unavailable.' using errcode = '42501';
  end if;
  perform private.lock_booking_participants(item.student_id,item.tutor_id);
  select * into strict item from public.bookings where id = _booking for update;

  if _action in ('accept','decline') then
    if caller = coalesce(item.proposed_by,item.student_id) then
      raise exception 'The other participant must respond to this request.' using errcode = '42501';
    end if;
    next_status := case when _action = 'accept' then 'confirmed' else 'declined' end;
    if item.status = next_status then return next_status; end if;
    if item.status <> 'pending' then raise exception 'This request has already been decided.' using errcode = 'PT409'; end if;
    if _action = 'accept' and (item.starts_at <= now() or exists (
      select 1 from public.bookings b where b.status = 'confirmed'
        and (b.tutor_id = item.tutor_id or b.student_id = item.student_id)
        and b.starts_at < item.ends_at and b.ends_at > item.starts_at
    )) then raise exception 'That time is no longer available. Decline and arrange a different time.' using errcode = 'PT409'; end if;
  elsif _action = 'cancel' then
    next_status := 'cancelled';
    if item.status = next_status then return next_status; end if;
    if item.starts_at <= now() or not (item.status = 'confirmed' or
      (item.status = 'pending' and caller = coalesce(item.proposed_by,item.student_id))) then
      raise exception 'This booking cannot be cancelled.' using errcode = 'PT409';
    end if;
  elsif _action = 'complete' then
    next_status := 'completed';
    if caller <> item.tutor_id then raise exception 'Only the tutor can mark a session complete.' using errcode = '42501'; end if;
    if item.status = next_status then return next_status; end if;
    if item.status <> 'confirmed' or item.ends_at > now() then
      raise exception 'Only a confirmed session that has ended can be completed.' using errcode = 'PT409';
    end if;
  else raise exception 'Choose a booking action.' using errcode = '22023';
  end if;

  update public.bookings set status = next_status,
    confirmed_at = case when next_status = 'confirmed' then clock_timestamp() else item.confirmed_at end
  where id = item.id;
  return next_status;
end;
$$;
revoke all on function public.respond_to_tutoring_booking(uuid,text) from public, anon, authenticated;
grant execute on function public.respond_to_tutoring_booking(uuid,text) to authenticated;

create or replace function private.booking_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare title text; label text;
begin
  if tg_op = 'UPDATE' and row(old.status,old.starts_at,old.ends_at,old.teaching_mode)
    is not distinct from row(new.status,new.starts_at,new.ends_at,new.teaching_mode) then return null; end if;
  title := case new.status when 'pending' then 'Booking request'
    when 'confirmed' then 'Booking accepted' when 'declined' then 'Booking declined'
    else 'Session ' || replace(new.status,'_',' ') end;
  if tg_op = 'UPDATE' and old.status = new.status then title := 'Session schedule updated'; end if;
  label := to_char(new.starts_at at time zone 'Africa/Johannesburg','DD Mon YYYY, HH24:MI') || ' SAST';
  perform private.bump_workspace(least(new.student_id,new.tutor_id));
  perform private.bump_workspace(greatest(new.student_id,new.tutor_id));
  insert into public.notifications(user_id,kind,title,body,data)
  select recipient,'booking',
    case when new.status = 'pending' and new.proposed_by = recipient then 'Booking request sent'
         when new.status = 'pending' and new.proposed_by is not null then 'Booking request received' else title end,
    case when new.status = 'pending' then 'A lesson was proposed for ' || label || '.'
         else 'Your lesson on ' || label || ' is ' || replace(new.status,'_',' ') || '.' end,
    jsonb_build_object('tab','calendar','bookingId',new.id)
  from (select distinct unnest(array[new.student_id,new.tutor_id]) recipient) recipients;
  return null;
end;
$$;

-- Public reviews still expose rating and feedback, never the underlying booking or student ID.
revoke select on public.reviews from anon, authenticated;
grant select (id,tutor_id,rating,body,is_published,created_at) on public.reviews to anon, authenticated;

create table public.booking_safety_cases (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete restrict,
  reporter_id uuid not null references public.profiles(id) on delete restrict,
  category text not null check (category in ('safety','conduct','lesson_quality','other')),
  description text not null check (char_length(btrim(description)) between 20 and 2000),
  status text not null default 'new' check (status in ('new','investigating','resolved')),
  assigned_to uuid references public.profiles(id) on delete set null,
  outcome text check (char_length(outcome) <= 2000),
  version integer not null default 1,
  created_at timestamptz not null default now()
);
create index booking_safety_cases_queue_idx on public.booking_safety_cases(status,created_at desc,id);
create index booking_safety_cases_booking_idx on public.booking_safety_cases(booking_id);
create unique index booking_safety_cases_active_reporter_idx on public.booking_safety_cases(reporter_id,booking_id)
  where status <> 'resolved';
alter table public.booking_safety_cases enable row level security;
revoke all on public.booking_safety_cases from public, anon, authenticated;
grant select (id,category,status,created_at) on public.booking_safety_cases to authenticated;
create policy "Administrators can list safety cases" on public.booking_safety_cases for select to authenticated
  using ((select private.is_platform_admin()));

create table private.booking_safety_case_audit (
  id bigint generated always as identity primary key,
  case_id uuid not null references public.booking_safety_cases(id) on delete restrict,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  action text not null check (action in ('opened','investigating','resolved')),
  created_at timestamptz not null default now()
);
create index booking_safety_case_audit_case_idx on private.booking_safety_case_audit(case_id);
alter table private.booking_safety_case_audit enable row level security;
revoke all on private.booking_safety_case_audit from public, anon, authenticated;

create function public.report_booking_concern(_booking uuid,_category text,_description text) returns uuid
language plpgsql security definer set search_path = '' as $$
declare caller uuid := (select auth.uid()); case_id uuid;
begin
  perform private.assert_platform_available();
  if caller is null or not exists (
    select 1 from public.bookings where id = _booking and caller in (student_id,tutor_id)
  ) then raise exception 'This booking is unavailable.' using errcode = '42501'; end if;
  if _category is null or _category not in ('safety','conduct','lesson_quality','other')
    or coalesce(char_length(btrim(_description)),0) not between 20 and 2000 then
    raise exception 'Choose a category and describe the concern in 20 to 2,000 characters.' using errcode = '22023';
  end if;
  insert into public.booking_safety_cases(booking_id,reporter_id,category,description)
  values (_booking,caller,_category,btrim(_description))
  on conflict (reporter_id,booking_id) where status <> 'resolved' do nothing returning id into case_id;
  if case_id is null then
    raise exception 'You already have an open report for this booking.' using errcode = 'PT409';
  end if;
  return case_id;
end;
$$;
revoke all on function public.report_booking_concern(uuid,text,text) from public, anon, authenticated;
grant execute on function public.report_booking_concern(uuid,text,text) to authenticated;

create function public.open_booking_safety_case(_case uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare caller uuid := (select auth.uid()); item public.booking_safety_cases%rowtype; booking jsonb;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode = '42501'; end if;
  select * into item from public.booking_safety_cases where id = _case for share;
  if not found then raise exception 'This safety case could not be found.' using errcode = 'PT404'; end if;
  if item.status <> 'resolved' then
    insert into private.booking_safety_case_audit(case_id,actor_id,action) values (item.id,caller,'opened');
    select jsonb_build_object('status',b.status,'starts_at',b.starts_at,'ends_at',b.ends_at,'mode',b.teaching_mode,
      'subject',s.name,'student',concat_ws(' ',p.first_name,p.last_name),'tutor',t.public_name,
      'reporter_role',case when item.reporter_id = b.tutor_id then 'Tutor' else 'Student' end)
    into booking
    from public.bookings b join public.profiles p on p.id = b.student_id
    join public.tutor_profiles t on t.user_id = b.tutor_id left join public.subjects s on s.id = b.subject_id
    where b.id = item.booking_id;
  end if;
  return (to_jsonb(item) - 'booking_id' - 'reporter_id' - 'assigned_to') ||
    jsonb_build_object('booking',booking,'assigned',item.assigned_to is not null,'mine',item.assigned_to = caller);
end;
$$;
revoke all on function public.open_booking_safety_case(uuid) from public, anon, authenticated;
grant execute on function public.open_booking_safety_case(uuid) to authenticated;

create function public.review_booking_safety_case(_case uuid,_status text,_outcome text,_version integer) returns void
language plpgsql security definer set search_path = '' as $$
declare caller uuid := (select auth.uid()); item public.booking_safety_cases%rowtype;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode = '42501'; end if;
  select * into item from public.booking_safety_cases where id = _case for update;
  if not found then raise exception 'This safety case could not be found.' using errcode = 'PT404'; end if;
  if item.version is distinct from _version then raise exception 'The case changed. Reload it before reviewing.' using errcode = 'PT409'; end if;
  if not coalesce((_status = 'investigating' and item.status = 'new') or
    (_status = 'resolved' and item.status = 'investigating' and (item.assigned_to = caller
      or exists (select 1 from public.profiles where id = caller and role = 'superUser'))),false) then
    raise exception 'Start review first. Only the assigned reviewer can resolve an open case.' using errcode = 'PT409';
  end if;
  if _status = 'resolved' and coalesce(char_length(btrim(_outcome)),0) not between 20 and 2000 then
    raise exception 'Describe the outcome in 20 to 2,000 characters.' using errcode = '22023';
  end if;
  update public.booking_safety_cases set status = _status, version = version + 1,
    assigned_to = caller,outcome = case when _status = 'resolved' then btrim(_outcome) end where id = item.id;
  insert into private.booking_safety_case_audit(case_id,actor_id,action) values (item.id,caller,_status);
  insert into public.notifications(user_id,kind,title,body,data) values (item.reporter_id,'booking',
    case when _status = 'resolved' then 'Safety report closed' else 'Safety report under review' end,
    case when _status = 'resolved' then 'The safety team has closed your report.' else 'The safety team is reviewing your report.' end,
    jsonb_build_object('tab','calendar','bookingId',item.booking_id));
  perform private.bump_workspace(item.reporter_id);
end;
$$;
revoke all on function public.review_booking_safety_case(uuid,text,text,integer) from public, anon, authenticated;
grant execute on function public.review_booking_safety_case(uuid,text,text,integer) to authenticated;

-- Reports return date buckets, never participant, booking or payment identifiers.
create function public.admin_booking_metrics() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode = '42501'; end if;
  return (
    with records as materialized (
      select b.id,b.status,b.duration_minutes,b.subject_id,b.starts_at >= now() as is_upcoming,
        date_trunc('day',b.starts_at,'Africa/Johannesburg') as starts_at,
        date_trunc('day',b.created_at,'Africa/Johannesburg') as created_at,
        (sp.demo_dataset is not null or tp.demo_dataset is not null or tutor.demo_dataset is not null) as demo
      from public.bookings b join public.profiles sp on sp.id = b.student_id
      join public.tutor_profiles tp on tp.user_id = b.tutor_id join public.profiles tutor on tutor.id = b.tutor_id
    ), scheduled as (
      select r.starts_at,r.status,s.name as subject_name,r.demo,r.is_upcoming,count(*) as count,
        sum(r.duration_minutes) as duration_minutes
      from records r left join public.subjects s on s.id = r.subject_id
      group by r.starts_at,r.status,s.name,r.demo,r.is_upcoming
    ), activity as (
      select created_at,demo,count(*) as count from records group by created_at,demo
    ), payment_summary as (
      select r.starts_at,p.status,(r.demo or p.provider = 'demo') as demo,count(*) as count,
        sum(p.amount) as amount,sum(p.platform_fee) as platform_fee
      from records r join public.payments p on p.booking_id = r.id
      group by r.starts_at,p.status,(r.demo or p.provider = 'demo')
    )
    select jsonb_build_object(
      'bookings',coalesce((select jsonb_agg(to_jsonb(scheduled)) from scheduled),'[]'::jsonb),
      'bookingActivity',coalesce((select jsonb_agg(to_jsonb(activity)) from activity),'[]'::jsonb),
      'payments',coalesce((select jsonb_agg(to_jsonb(payment_summary)) from payment_summary),'[]'::jsonb)
    )
  );
end;
$$;
revoke all on function public.admin_booking_metrics() from public, anon, authenticated;
grant execute on function public.admin_booking_metrics() to authenticated;

-- Include the proposer and confirmation time in the existing participant-only workspace.
CREATE OR REPLACE FUNCTION public.my_tutoring_workspace()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare caller uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if caller is null then raise exception 'Sign-in required' using errcode='42501'; end if;
  select jsonb_build_object(
    'bookings',coalesce((select jsonb_agg(row_data order by starts_at desc) from (
      select b.starts_at,jsonb_build_object('id',b.id,'student_id',b.student_id,'tutor_id',b.tutor_id,
        'student_name',concat_ws(' ',sp.first_name,sp.last_name),'tutor_name',coalesce(tp.public_name,'Tutor'),
        'subject',s.name,'starts_at',b.starts_at,'ends_at',b.ends_at,'duration_minutes',b.duration_minutes,
        'status',b.status,'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'proposed_by',coalesce(b.proposed_by,b.student_id),'confirmed_at',b.confirmed_at,
        'special_requests',b.special_requests,'demo',sp.demo_dataset is not null) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc) from public.payments p where caller in (p.payer_id,p.payee_id)),'[]'::jsonb),
    'conversations',coalesce((select jsonb_agg(row_data order by updated_at desc) from (
      select c.updated_at,jsonb_build_object('id',c.id,'booking_id',c.booking_id,'last_read_at',own.last_read_at,
        'participants',(select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(tp.public_name,concat_ws(' ',p.first_name,p.last_name)),'role',p.role))
          from public.conversation_members cm join public.profiles p on p.id=cm.user_id left join public.tutor_profiles tp on tp.user_id=p.id
          where cm.conversation_id=c.id and cm.user_id<>caller),
        'messages',coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from (
          select id,sender_id,body,created_at from public.messages where conversation_id=c.id and deleted_at is null order by created_at desc limit 200
        ) m),'[]'::jsonb)) row_data
      from public.conversations c join public.conversation_members own on own.conversation_id=c.id and own.user_id=caller
      order by c.updated_at desc limit 200
    ) rows),'[]'::jsonb),
    'notifications',coalesce((select jsonb_agg(to_jsonb(n) order by n.created_at desc,n.id desc) from (select * from public.notifications where user_id=caller order by created_at desc,id desc limit 50) n),'[]'::jsonb),
    'notification_unread_count',(select count(*) from public.notifications where user_id=caller and read_at is null),
    'notification_revision',coalesce((select version from public.workspace_signals where user_id=caller),0)
  ) into result;
  return result;
end;
$function$;
