alter table public.bookings add column invitation_expired_at timestamptz;

create function private.enforce_booking_invitation_deadline() returns trigger
language plpgsql set search_path = '' as $$
begin
  if old.status = 'pending' and old.starts_at <= clock_timestamp() then
    if new.status = 'confirmed' then
      raise exception 'This invitation expired before it was accepted.' using errcode = 'PT409';
    end if;
    if new.status = 'declined' then
      new.invitation_expired_at := coalesce(new.invitation_expired_at, clock_timestamp());
    end if;
  end if;
  return new;
end;
$$;
create trigger booking_invitation_deadline before update of status on public.bookings
for each row execute function private.enforce_booking_invitation_deadline();

create function private.expire_lesson_invitations() returns integer
language plpgsql set search_path = '' as $$
declare affected integer;
begin
  with due as (
    select id from public.bookings where status = 'pending' and starts_at <= now()
    order by starts_at, id limit 100 for update skip locked
  )
  update public.bookings b set status = 'declined' from due where b.id = due.id;
  get diagnostics affected = row_count;
  return affected;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('aerogen-expire-lesson-invitations', '* * * * *',
      'select private.expire_lesson_invitations()');
  end if;
end;
$$;

alter table public.booking_safety_cases add column attendance_decision text
  check (attendance_decision in ('pending', 'happened', 'not_happened'));
alter table public.booking_safety_cases add constraint booking_case_attendance_check check (
  attendance_decision is null or (
    booking_id is not null and category = 'lesson_dispute' and issue_code = 'ATT' and not dispute
    and ((status = 'resolved') = (attendance_decision <> 'pending'))
  )
);

create function private.open_invitation_attendance_ticket(_booking uuid, _actor uuid, _description text)
returns uuid language plpgsql set search_path = '' as $$
declare lesson public.bookings%rowtype; ticket uuid;
begin
  perform private.assert_platform_available();
  select * into lesson from public.bookings where id = _booking and _actor in (student_id, tutor_id);
  if not found then raise exception 'This booking is unavailable.' using errcode = '42501'; end if;
  if coalesce(char_length(btrim(_description)), 0) not between 20 and 2000 then
    raise exception 'Describe the lesson in 20 to 2,000 characters.' using errcode = '22023';
  end if;
  select id into ticket from public.booking_safety_cases
    where booking_id = _booking and reporter_id = _actor and attendance_decision = 'pending';
  if found then return ticket; end if;
  if lesson.status <> 'pending' and not (lesson.status = 'declined' and lesson.invitation_expired_at is not null) then
    raise exception 'Attendance review is available for unanswered or expired invitations.' using errcode = 'PT409';
  end if;
  insert into public.booking_safety_cases(booking_id, reporter_id, category, issue_code, subject, description, attendance_decision)
  values (_booking, _actor, 'lesson_dispute', 'ATT', 'Attendance for an unanswered invitation', btrim(_description), 'pending')
  on conflict (reporter_id, booking_id) where status <> 'resolved' and not dispute do nothing
  returning id into ticket;
  if ticket is null then
    select id into ticket from public.booking_safety_cases
      where booking_id = _booking and reporter_id = _actor and attendance_decision = 'pending';
  end if;
  if ticket is null then
    raise exception 'You already have an open ticket for this booking. Reply there or ask support to close it before opening an attendance review.' using errcode = 'PT409';
  end if;
  return ticket;
end;
$$;

create function private.record_invitation_attendance(_booking uuid, _decision text)
returns void language plpgsql set search_path = '' as $$
declare lesson public.bookings%rowtype;
begin
  select * into strict lesson from public.bookings where id = _booking;
  perform private.lock_booking_participants(lesson.student_id, lesson.tutor_id);
  select * into strict lesson from public.bookings where id = _booking for update;
  if lesson.ends_at > now() then
    raise exception 'Wait until the scheduled lesson ends before recording attendance.' using errcode = 'PT409';
  end if;
  if (lesson.status = 'completed' and _decision = 'happened')
    or (lesson.status = 'no_show' and _decision = 'not_happened') then return; end if;
  if (lesson.status <> 'pending' and not (lesson.status = 'declined' and lesson.invitation_expired_at is not null))
    or exists (select 1 from private.lesson_funds where booking_id = lesson.id) then
    raise exception 'This booking already has a different outcome or payment workflow. Review it before closing this ticket.' using errcode = 'PT409';
  end if;
  update public.bookings set
    status = case when _decision = 'happened' then 'completed' else 'no_show' end,
    invitation_expired_at = coalesce(invitation_expired_at, clock_timestamp())
  where id = lesson.id;
end;
$$;

create unique index reviews_one_per_student_tutor on public.reviews(student_id, tutor_id);
create index bookings_completed_rating_pair on public.bookings(student_id, tutor_id, ends_at, id)
  where status = 'completed';
create index bookings_completed_rating_tutor on public.bookings(tutor_id, student_id, ends_at, id)
  where status = 'completed';

create table private.student_lesson_ratings (
  student_id uuid not null references public.profiles(id) on delete restrict,
  tutor_id uuid not null references public.tutor_profiles(user_id) on delete restrict,
  booking_id uuid not null unique references public.bookings(id) on delete restrict,
  rating smallint not null check (rating between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (tutor_id, student_id)
);
alter table private.student_lesson_ratings enable row level security;
revoke all on private.student_lesson_ratings from public, anon, authenticated;

create function private.lesson_rating_prompts(_actor uuid) returns jsonb
language sql stable set search_path = '' as $$
  with first_lessons as (
    select distinct on (b.student_id, b.tutor_id)
      b.id, b.student_id, b.tutor_id, b.ends_at
    from public.bookings b
    where _actor in (b.student_id, b.tutor_id) and b.status = 'completed' and b.ends_at <= now()
    order by b.student_id, b.tutor_id, b.ends_at, b.id
  ), outstanding as (
    select b.id, b.ends_at, b.student_id = _actor as for_tutor, names.student_name, names.tutor_name
    from first_lessons b
    cross join lateral private.lesson_notification_names(b.student_id, b.tutor_id) names
    where (_actor = b.student_id and not exists (
      select 1 from public.reviews r where r.student_id = b.student_id and r.tutor_id = b.tutor_id
    )) or (_actor = b.tutor_id and not exists (
      select 1 from private.student_lesson_ratings r where r.student_id = b.student_id and r.tutor_id = b.tutor_id
    ))
    order by b.ends_at desc, b.id limit 10
  )
  select coalesce(jsonb_agg(jsonb_build_object('booking_id',id,'for_tutor',for_tutor,
    'name',case when for_tutor then tutor_name else student_name end) order by ends_at desc,id), '[]'::jsonb)
  from outstanding;
$$;

create function public.rate_completed_lesson(_booking uuid, _rating integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); lesson public.bookings%rowtype; saved_rating smallint;
begin
  perform private.assert_platform_available();
  if _rating is null or _rating not between 1 and 5 then
    raise exception 'Choose a rating between 1 and 5 stars.' using errcode = '22023';
  end if;
  select * into lesson from public.bookings where id = _booking and actor in (student_id, tutor_id);
  if not found then raise exception 'This booking is unavailable.' using errcode = '42501'; end if;
  if lesson.status <> 'completed' or lesson.ends_at > now() or exists (
    select 1 from public.bookings b where b.student_id = lesson.student_id and b.tutor_id = lesson.tutor_id
      and b.status = 'completed' and (b.ends_at,b.id) < (lesson.ends_at,lesson.id)
  ) then
    raise exception 'Rate this person after your first completed lesson together.' using errcode = 'PT409';
  end if;
  if actor = lesson.student_id then
    insert into public.reviews(booking_id,student_id,tutor_id,rating)
      values (lesson.id,lesson.student_id,lesson.tutor_id,_rating)
      on conflict (student_id,tutor_id) do nothing;
    select rating into saved_rating from public.reviews
      where student_id = lesson.student_id and tutor_id = lesson.tutor_id;
  else
    insert into private.student_lesson_ratings(booking_id,student_id,tutor_id,rating)
      values (lesson.id,lesson.student_id,lesson.tutor_id,_rating)
      on conflict (tutor_id,student_id) do nothing;
    select rating into saved_rating from private.student_lesson_ratings
      where student_id = lesson.student_id and tutor_id = lesson.tutor_id;
  end if;
  return jsonb_build_object('rating',saved_rating);
end;
$$;

revoke all on function private.enforce_booking_invitation_deadline(), private.expire_lesson_invitations(),
  private.open_invitation_attendance_ticket(uuid,uuid,text), private.record_invitation_attendance(uuid,text),
  private.lesson_rating_prompts(uuid), public.rate_completed_lesson(uuid,integer) from public, anon, authenticated;
grant execute on function public.rate_completed_lesson(uuid,integer) to authenticated;


create or replace function public.report_booking_ticket(_booking uuid,_category text,_description text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype; ticket uuid;
begin
  if _category = 'attendance' then
    ticket := private.open_invitation_attendance_ticket(_booking,actor,_description);
  else
    ticket := public.report_booking_concern(_booking,_category,_description);
  end if;
  select * into strict item from public.booking_safety_cases where id = ticket;
  if not exists(select 1 from public.notifications where user_id = actor and data->>'ticketId' = ticket::text
    and title in ('Ticket '||item.reference||' received','Ticket '||item.category_reference||' received','Ticket '||item.case_reference||' received')) then
    perform private.billing_notice(actor,'Ticket '||item.case_reference||' received','Support has received your booking concern.','tickets',ticket);
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'case_reference',item.case_reference);
end;
$$;

create or replace function public.update_support_ticket(_ticket uuid,_version integer,_status text,_reply text,_outcome text,_settlement text)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); item public.booking_safety_cases%rowtype; staff_override boolean; lesson public.bookings%rowtype; attendance text;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501'; end if;
  select * into item from public.booking_safety_cases where id=_ticket for update;
  if not found then raise exception 'Ticket not found.' using errcode='PT404'; end if;
  if item.version is distinct from _version then raise exception 'The ticket changed. Refresh before retrying.' using errcode='PT409'; end if;
  if _status is null or _status not in ('investigating','waiting','resolved') or item.status='resolved'
    or (item.status='new' and _status<>'investigating') then
    raise exception 'Claim the ticket before responding or resolving it.' using errcode='PT409';
  end if;
  staff_override := exists(select 1 from public.profiles where id=actor and role='superUser');
  if item.assigned_to is not null and item.assigned_to<>actor and not staff_override then
    raise exception 'This ticket belongs to another reviewer.' using errcode='42501';
  end if;
  if char_length(coalesce(_reply,''))>2000 or char_length(coalesce(_outcome,''))>2000
    or (_status='waiting' and coalesce(char_length(btrim(_reply)),0)<2)
    or (_status='resolved' and coalesce(char_length(btrim(_outcome)),0)<20) then
    raise exception 'Add a reply when waiting on a participant or an internal note of at least 20 characters when resolving.' using errcode='22023';
  end if;
  attendance := item.attendance_decision;
  if _status='resolved' and attendance='pending' then
    if _settlement is null or _settlement not in ('happened','not_happened') then
      raise exception 'Choose whether the invited lesson happened.' using errcode='22023';
    end if;
    perform private.record_invitation_attendance(item.booking_id,_settlement);
    attendance := _settlement;
  end if;
  if _status='resolved' and item.dispute then
    if _settlement is null or _settlement not in ('release','refund') then
      raise exception 'Choose whether the disputed lesson happened.' using errcode='22023';
    end if;
    select * into strict lesson from public.bookings where id=item.booking_id;
    perform private.lock_booking_participants(lesson.student_id,lesson.tutor_id);
    perform 1 from public.bookings where id=item.booking_id for update;
    perform private.bump_workspace(least(lesson.student_id,lesson.tutor_id));
    perform private.bump_workspace(greatest(lesson.student_id,lesson.tutor_id));
    perform private.settle_lesson(item.booking_id,_settlement='release');
    update public.bookings set status=case when _settlement='release' then 'completed' else 'no_show' end
      where id=item.booking_id and status='confirmed';
  end if;
  if char_length(btrim(coalesce(_reply,'')))>=2 then
    insert into private.ticket_replies(ticket_id,author,from_support,body) values(_ticket,actor,true,btrim(_reply));
  end if;
  update public.booking_safety_cases set status=_status,assigned_to=actor,version=version+1,updated_at=now(),
    attendance_decision=attendance,
    outcome=case when _status='resolved' then btrim(_outcome) else outcome end,
    response_due_at=case when _status='waiting' or char_length(btrim(coalesce(_reply,'')))>=2 then now()+interval '24 hours' else response_due_at end
    where id=_ticket;
  insert into private.booking_safety_case_audit(case_id,actor_id,action)
    values(_ticket,actor,case when _status='resolved' then 'resolved' else 'investigating' end);
  if item.dispute then
    if lesson.id is null then select * into strict lesson from public.bookings where id=item.booking_id; end if;
    perform private.bump_workspace(least(lesson.student_id,lesson.tutor_id));
    perform private.bump_workspace(greatest(lesson.student_id,lesson.tutor_id));
    perform private.billing_notice(lesson.tutor_id,'Ticket '||item.reference||' updated','Open the lesson dispute for the latest update.','tickets',_ticket);
  end if;
  if item.attendance_decision='pending' and _status='resolved' then
    perform private.billing_notice(item.reporter_id,'Attendance review completed',
      case when attendance='happened' then 'Support recorded the lesson as completed.' else 'Support recorded that the lesson did not take place.' end,
      'tickets',_ticket);
    return;
  end if;
  perform private.billing_notice(item.reporter_id,'Ticket '||item.reference||' updated','Open your support ticket for the latest update.','tickets',_ticket);
end;
$$;

create or replace function private.booking_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  proposer uuid := coalesce(new.proposed_by,new.student_id);
  recipient uuid;
  counterpart text;
  names record;
  label text;
  title text;
  body text;
  awaiting_payment boolean := false;
  top_up integer;
  uses_credit boolean := false;
  schedule_changed boolean := false;
  withdrawn boolean := false;
  expired boolean := false;
begin
  if tg_op='UPDATE' then
    schedule_changed := old.status=new.status;
    if row(old.status,old.starts_at,old.ends_at,old.teaching_mode)
       is not distinct from row(new.status,new.starts_at,new.ends_at,new.teaching_mode) then return null; end if;
    withdrawn := old.status='pending' and new.status='cancelled';
    expired := old.status='confirmed' and new.status='cancelled' and new.starts_at<=now() and new.payment_required
      and not private.lesson_payment_secured(new.id);
  end if;
  if new.status='confirmed' then
    awaiting_payment := new.payment_required and not private.lesson_payment_secured(new.id);
    select f.source='package', f.top_up_cents into uses_credit,top_up
      from private.lesson_funds f where f.booking_id=new.id;
  end if;
  select * into names from private.lesson_notification_names(new.student_id,new.tutor_id);
  label := to_char(new.starts_at at time zone 'Africa/Johannesburg','DD Mon YYYY "at" HH24:MI') || ' SAST';

  perform private.bump_workspace(least(new.student_id,new.tutor_id));
  perform private.bump_workspace(greatest(new.student_id,new.tutor_id));
  for recipient in select distinct unnest(array[new.student_id,new.tutor_id]) loop
    counterpart := case when recipient=new.student_id then names.tutor_name else names.student_name end;
    if schedule_changed then
      title := case when recipient=new.student_id then 'Your lesson schedule changed' else 'Your teaching schedule changed' end;
      body := format('The lesson with %s is now scheduled for %s. Check Calendar for the current time and lesson format.',counterpart,label);
    elsif new.status='pending' then
      title := case when recipient=proposer then 'Booking request sent'
        when recipient=new.student_id then 'Your tutor proposed a lesson' else 'Booking request received' end;
      body := case when recipient=proposer then format('You requested a lesson with %s for %s. We’ll let you know when they respond.',counterpart,label)
        else format('You received a lesson request from %s for %s. Open Calendar to accept or decline.',counterpart,label) end;
    elsif new.status='confirmed' then
      title := case when recipient=proposer then 'Your booking request was accepted' else 'You accepted the booking' end;
      body := case when recipient=proposer then format('Your lesson with %s on %s was accepted.',counterpart,label)
        else format('You accepted the lesson with %s on %s.',counterpart,label) end;
      if awaiting_payment then
        if recipient<>new.student_id then
          body := body || ' The student still needs to finish checkout before the lesson can go ahead.';
        elsif top_up>0 then
          body := body || format(' One lesson credit is reserved. Pay the remaining R%s in Calendar before the lesson starts.',
            to_char(top_up / 100.0,'FM999999990.00'));
        else
          body := body || ' Open Calendar to use an eligible credit or pay before the lesson starts.';
        end if;
      elsif uses_credit then
        body := body || case when recipient=new.student_id then ' One lesson credit covers this booking.'
          else ' The lesson is funded. Open Calendar for the details.' end;
      else
        body := body || ' Open Calendar for the lesson details.';
      end if;
    elsif new.status='declined' and new.invitation_expired_at is not null then
      title := 'Lesson invitation expired';
      body := format('The invitation for a lesson with %s on %s expired without a response. If the lesson happened, you can request an attendance review in Calendar.',counterpart,label);
    elsif new.status='declined' then
      title := case when recipient=proposer then 'Your booking request was declined' else 'You declined the booking' end;
      body := case when recipient=proposer then format('The lesson you requested with %s for %s was declined. You can propose another time.',counterpart,label)
        else format('You declined the request from %s for %s. The lesson will not go ahead.',counterpart,label) end;
    elsif new.status='cancelled' then
      if expired then
        title := case when recipient=new.student_id then 'Your booking expired before payment' else 'Lesson cancelled before funding' end;
        body := case when recipient=new.student_id then format('Checkout was incomplete when your lesson with %s was due to start on %s.',counterpart,label)
          else format('Checkout was incomplete for the lesson with %s on %s. The time is no longer booked.',counterpart,label) end;
      elsif withdrawn then
        title := case when recipient=proposer then 'You withdrew your booking request' else 'Booking request withdrawn' end;
        body := case when recipient=proposer then format('You withdrew your request for a lesson with %s on %s.',counterpart,label)
          else format('The request from %s for a lesson on %s was withdrawn. You don’t need to respond.',counterpart,label) end;
      else
        title := case when recipient=actor then 'You cancelled the lesson' else 'Lesson cancelled' end;
        body := case when recipient=actor then format('You cancelled the lesson with %s scheduled for %s.',counterpart,label)
          when actor in (new.student_id,new.tutor_id) then format('The lesson scheduled for %s was cancelled by %s. Your calendar has been updated.',label,counterpart)
          else format('The lesson with %s scheduled for %s was cancelled. Your calendar has been updated.',counterpart,label) end;
      end if;
    elsif new.status='completed' then
      title := case when recipient=new.student_id then 'Your lesson is complete' else 'Teaching session completed' end;
      if new.invitation_expired_at is not null and new.confirmed_at is null then
        body := format('Support recorded the lesson with %s on %s as completed. Open Calendar for the lesson record.',counterpart,label);
      else
        body := format('The lesson with %s on %s is complete. %s',counterpart,label,
        case when recipient=new.student_id then 'You can review it in Calendar.' else 'Check Earnings for any funds released from this lesson.' end);
      end if;
    else
      title := case when recipient=new.student_id then 'Your lesson did not take place' else 'Teaching session did not take place' end;
      body := format('The lesson with %s on %s was marked as not having taken place. %s',counterpart,label,
        case when recipient=new.student_id then 'Check Payments for any returned payment or lesson credit.' else 'Check Earnings for any payment adjustment.' end);
    end if;
    insert into public.notifications(user_id,kind,title,body,data)
    values(recipient,'booking',title,body,jsonb_build_object('tab','calendar','bookingId',new.id));
  end loop;
  return null;
end;
$$;

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
        'status',case when b.status='pending' and b.starts_at<=now() then 'declined' else b.status end,
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

create function private.tutor_billing_performance(_tutor uuid) returns jsonb
language sql stable set search_path = '' as $$
  with period as (
    select date_trunc('month', now() at time zone 'Africa/Johannesburg') as local_month
  ), totals as (
    select
      coalesce(sum(net_cents) filter (where state='released' and in_month),0) as released_month,
      coalesce(sum(net_cents) filter (where state in ('held','disputed') and in_month),0) as unreleased_month,
      coalesce(sum(net_cents) filter (where state in ('held','disputed')),0) as unreleased
    from (
      select f.state, round((p.amount-p.platform_fee)*100) as net_cents,
        date_trunc('month',b.starts_at at time zone 'Africa/Johannesburg') = period.local_month as in_month
      from public.payments p
      join private.lesson_funds f on f.payment_id=p.id
      join public.bookings b on b.id=f.booking_id and b.tutor_id=_tutor
      cross join period
      where p.payee_id=_tutor and p.status='paid' and f.state in ('held','disputed','released')
    ) earnings
  )
  select jsonb_build_object(
    'released_month_cents',totals.released_month,
    'unreleased_month_cents',totals.unreleased_month,
    'unreleased_cents',totals.unreleased,
    'rating_average',round(stats.average_rating,1),
    'rating_count',coalesce(stats.review_count,0)
  )
  from totals left join public.tutor_public_stats stats on stats.tutor_id=_tutor;
$$;
revoke all on function private.tutor_billing_performance(uuid) from public,anon,authenticated;

create or replace function public.my_account_billing() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype; account_role text; performance jsonb;
begin
  perform private.assert_platform_available();
  item := private.sync_membership(actor);
  select role into account_role from public.profiles where id=actor;
  performance := case when account_role='tutor' then private.tutor_billing_performance(actor) else '{}'::jsonb end;
  return performance || jsonb_build_object(
    'membership',to_jsonb(item)-'owner',
    'lesson_credit_allowance_cents',case when account_role='student' then private.lesson_credit_allowance_cents() end,
    'lesson_credits',case when account_role='student' then private.lesson_credit_balance(actor) end,
    'credit_purchases',case when account_role='student' then coalesce((
      select jsonb_agg(to_jsonb(purchase) order by created_at desc,id desc) from (
        select e.id,e.created_at,e.amount_cents,e.lesson_credits_awarded as credits,p.name as plan_name
        from private.billing_events e join private.billing_plans p on p.id=e.target
        where e.owner=actor and e.lesson_credits_awarded>0 order by e.created_at desc,e.id desc limit 20
      ) purchase
    ),'[]'::jsonb) end,
    'plans',(select jsonb_agg(to_jsonb(p) order by price_cents) from private.billing_plans p where p.audience=account_role),
    'payout_balance_cents',case when account_role='tutor' then private.payout_balance(actor) else 0 end,
    'events',coalesce((select jsonb_agg(to_jsonb(e)-'owner'-'request_id' order by created_at desc,id desc) from
      (select * from private.billing_events where owner=actor order by created_at desc,id desc limit 50) e),'[]'::jsonb),
    'lessons',coalesce((select jsonb_agg(to_jsonb(l) order by starts_at desc) from (
      select b.id,b.starts_at,s.name as subject,b.status,f.state,p.amount,p.platform_fee,f.source,
        case when actor=b.student_id then f.top_up_cents end as top_up_cents,p.paid_at
      from public.bookings b left join public.subjects s on s.id=b.subject_id
      join private.lesson_funds f on f.booking_id=b.id join public.payments p on p.id=f.payment_id
      where actor=b.student_id or (actor=b.tutor_id and (f.top_up_cents=0 or p.paid_at is not null))
      order by b.starts_at desc,b.id limit 50
    ) l),'[]'::jsonb)
  );
end;
$$;
