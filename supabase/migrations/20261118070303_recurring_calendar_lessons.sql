create table private.recurring_booking_requests (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id),
  request_id uuid not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique(owner,request_id)
);
alter table private.recurring_booking_requests enable row level security;
revoke all on private.recurring_booking_requests from public,anon,authenticated;
alter table public.bookings add column series_id uuid references private.recurring_booking_requests(id),
  add column recurrence_frequency text check(recurrence_frequency in ('daily','weekly','monthly')),
  add column series_occurrence integer check(series_occurrence between 1 and 12),
  add constraint booking_series_complete check(
    (series_id is null and recurrence_frequency is null and series_occurrence is null)
    or (series_id is not null and recurrence_frequency is not null and series_occurrence is not null)),
  add constraint booking_series_occurrence_unique unique(series_id,series_occurrence);

create or replace function private.booking_time_open(_tutor uuid,_student uuid,_starts timestamptz,_duration integer) returns boolean
language sql stable set search_path='' as $$
  with local_time as (
    select _starts at time zone 'Africa/Johannesburg' as starts,_starts+make_interval(mins=>_duration) as ends
  ), slot as (
    select starts::date as day,extract(hour from starts)::integer*60+extract(minute from starts)::integer as minute,ends
    from local_time where _duration in (30,60,90,120) and _starts>=now()+interval '2 hours'
      and starts::date<=private.booking_local_today()+365 and extract(second from starts)=0 and extract(minute from starts) in (0,30)
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

create function private.recurring_lesson_dates(_starts timestamptz,_frequency text,_count integer)
returns table(occurrence integer,starts_at timestamptz) language plpgsql stable set search_path='' as $$
declare local_start timestamp := _starts at time zone 'Africa/Johannesburg';
begin
  if _starts is null or not isfinite(_starts) or _frequency is null or _frequency not in ('daily','weekly','monthly')
    or _count is null or _count not between 2 and 12 then
    raise exception 'Choose daily, weekly or monthly, with 2 to 12 lessons.' using errcode='22023';
  end if;
  return query select n+1,(local_start+case _frequency
    when 'daily' then make_interval(days=>n)
    when 'weekly' then make_interval(days=>n*7)
    else make_interval(months=>n) end) at time zone 'Africa/Johannesburg'
  from generate_series(0,_count-1) n;
end; $$;
revoke all on function private.recurring_lesson_dates(timestamptz,text,integer) from public,anon,authenticated;

create function public.recurring_booking_options(_tutor uuid,_student uuid,_starts timestamptz,_duration integer,_frequency text,_count integer)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); result jsonb;
begin
  perform private.assert_platform_available();
  if actor is null or _tutor is null or _student is null or actor not in (_tutor,_student) or not private.booking_pair_allowed(_tutor,_student) then
    raise exception 'Choose a valid tutor and student.' using errcode='42501';
  end if;
  select jsonb_agg(jsonb_build_object('starts_at',r.starts_at,'available',
    private.booking_time_open(_tutor,_student,r.starts_at,_duration)
    and not exists(select 1 from public.bookings b where b.tutor_id=_tutor and b.student_id=_student and b.status='pending'
      and b.starts_at<r.starts_at+make_interval(mins=>_duration) and b.ends_at>r.starts_at)) order by occurrence)
  into result from private.recurring_lesson_dates(_starts,_frequency,_count) r;
  return result;
end; $$;

create function public.request_recurring_tutoring_booking(_tutor uuid,_student uuid,_subject bigint,_starts_at timestamptz,
  _duration integer,_mode text,_type text,_notes text,_curriculum text,_frequency text,_count integer,_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  actor uuid := (select auth.uid()); series private.recurring_booking_requests; payload jsonb;
  occurrence record; booking_id uuid; ids uuid[] := '{}'; recipient uuid; counterpart text; names record; previous_mode text;
begin
  perform private.assert_platform_available();
  if actor is null or _tutor is null or _student is null or actor not in (_tutor,_student) or _request is null then
    raise exception 'Only a participant can request recurring lessons.' using errcode='42501';
  end if;
  payload:=jsonb_build_object('tutor',_tutor,'student',_student,'subject',_subject,'starts',_starts_at,'duration',_duration,
    'mode',_mode,'type',_type,'notes',btrim(coalesce(_notes,'')),'curriculum',_curriculum,'frequency',_frequency,'count',_count);
  perform pg_advisory_xact_lock(hashtextextended(actor::text||_request::text,0));
  select * into series from private.recurring_booking_requests where owner=actor and request_id=_request;
  if found then
    if series.payload is distinct from payload then raise exception 'This request key belongs to a different lesson series.' using errcode='PT409'; end if;
    return jsonb_build_object('id',(select id from public.bookings where series_id=series.id order by series_occurrence limit 1),
      'seriesId',series.id,'count',_count);
  end if;
  perform private.lock_booking_participants(_student,_tutor);
  insert into private.recurring_booking_requests(owner,request_id,payload) values(actor,_request,payload) returning * into series;
  previous_mode:=coalesce(current_setting('aerogen.creating_booking_series',true),'');
  perform set_config('aerogen.creating_booking_series','yes',true);
  for occurrence in select * from private.recurring_lesson_dates(_starts_at,_frequency,_count) loop
    if exists(select 1 from public.bookings b where b.student_id=_student and b.tutor_id=_tutor and b.status in ('pending','confirmed')
      and b.starts_at<occurrence.starts_at+make_interval(mins=>_duration) and b.ends_at>occurrence.starts_at) then
      raise exception 'A lesson in this series already has a booking request. Choose another time.' using errcode='PT409';
    end if;
    booking_id:=public.request_tutoring_booking(_tutor,_student,_subject,occurrence.starts_at,_duration,_mode,_type,_notes,_curriculum);
    update public.bookings set series_id=series.id,recurrence_frequency=_frequency,series_occurrence=occurrence.occurrence where id=booking_id;
    ids:=array_append(ids,booking_id);
  end loop;
  perform set_config('aerogen.creating_booking_series',previous_mode,true);
  select * into names from private.lesson_notification_names(_student,_tutor);
  recipient:=case when actor=_student then _tutor else _student end;
  counterpart:=case when actor=_student then names.student_name else names.tutor_name end;
  insert into public.notifications(user_id,kind,title,body,data)
  values(recipient,'booking','Recurring lesson requests received',
    format('%s proposed %s %s lessons. Review and accept or decline each invitation in Calendar.',counterpart,_count,_frequency),
    jsonb_build_object('tab','calendar','bookingId',ids[1],'seriesId',series.id));
  return jsonb_build_object('id',ids[1],'seriesId',series.id,'count',cardinality(ids));
end; $$;
revoke all on function public.recurring_booking_options(uuid,uuid,timestamptz,integer,text,integer),
  public.request_recurring_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text,text,text,integer,uuid) from public,anon;
grant execute on function public.recurring_booking_options(uuid,uuid,timestamptz,integer,text,integer),
  public.request_recurring_tutoring_booking(uuid,uuid,bigint,timestamptz,integer,text,text,text,text,text,integer,uuid) to authenticated;

create or replace function private.notification_preference() returns trigger
language plpgsql security definer set search_path='' as $$
declare preference public.user_notification_preferences; actor uuid := (select auth.uid());
begin
  if new.kind='booking' and current_setting('aerogen.creating_booking_series',true)='yes' then return null; end if;
  if new.user_id=actor and coalesce(new.data->>'event','') not in ('ticket_opened','subscription_renewal','daily_reminder') then return null; end if;
  select * into preference from public.user_notification_preferences where user_id=new.user_id;
  if (new.kind='message' and not coalesce(preference.push_messages,true))
    or (new.kind in ('booking','calendar') and not coalesce(preference.push_booking_updates,true))
    or (new.kind='payment' and not coalesce(preference.push_payment_updates,true)) then return null; end if;
  return new;
end; $$;

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
        'series_id',b.series_id,'recurrence_frequency',b.recurrence_frequency,'series_occurrence',b.series_occurrence,'status',case when b.status='pending' and b.starts_at<=now() then 'declined' else b.status end,
        'invitation_expired_at',coalesce(b.invitation_expired_at,case when b.status='pending' and b.starts_at<=now() then b.starts_at end),
        'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'proposed_by',coalesce(b.proposed_by,b.student_id),'confirmed_at',b.confirmed_at,
        'special_requests',b.special_requests,'demo',sp.demo_dataset is not null,
        'attendance_ticket_id',(select c.id from public.booking_safety_cases c where c.booking_id=b.id
          and c.reporter_id=caller and c.attendance_decision='pending' limit 1)
      ) || private.lesson_billing_summary(b.id,caller) row_data
      from public.bookings b join public.profiles sp on sp.id=b.student_id join public.tutor_profiles tp on tp.user_id=b.tutor_id
      left join public.subjects s on s.id=b.subject_id where caller in (b.student_id,b.tutor_id) order by b.starts_at desc limit 1000
    ) rows),'[]'::jsonb),
    'student_study_profiles',private.workspace_student_study_profiles(caller),
    'lesson_rating_prompts',private.lesson_rating_prompts(caller),
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
