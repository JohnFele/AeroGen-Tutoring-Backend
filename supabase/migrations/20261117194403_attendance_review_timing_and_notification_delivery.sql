-- Attendance reviews are available once the scheduled lesson has ended.
create or replace function private.open_invitation_attendance_ticket(_booking uuid, _actor uuid, _description text)
returns uuid language plpgsql set search_path = '' as $$
declare lesson public.bookings%rowtype; ticket uuid;
begin
  perform private.assert_platform_available();
  select * into lesson from public.bookings where id = _booking and _actor in (student_id, tutor_id);
  if not found then raise exception 'This booking is unavailable.' using errcode = '42501'; end if;
  if lesson.ends_at > clock_timestamp() then
    raise exception 'Attendance review is available after the scheduled lesson has ended.' using errcode = 'PT409';
  end if;
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

-- All notification producers share this gate, including learning and billing.
-- Ticket-opening receipts and automatic system events are explicit exceptions.
create or replace function private.notification_preference() returns trigger
language plpgsql security definer set search_path = '' as $$
declare preference public.user_notification_preferences; actor uuid := (select auth.uid());
begin
  if new.user_id = actor
    and coalesce(new.data->>'event', '') not in ('ticket_opened', 'subscription_renewal', 'daily_reminder') then
    return null;
  end if;
  select * into preference from public.user_notification_preferences where user_id = new.user_id;
  if (new.kind = 'message' and not coalesce(preference.push_messages, true))
    or (new.kind in ('booking', 'calendar') and not coalesce(preference.push_booking_updates, true))
    or (new.kind = 'payment' and not coalesce(preference.push_payment_updates, true)) then return null; end if;
  return new;
end;
$$;

create or replace function private.billing_notice(_owner uuid, _title text, _body text, _tab text, _ticket uuid default null, _booking uuid default null)
returns void language plpgsql set search_path = '' as $$
declare item public.booking_safety_cases%rowtype; event text;
begin
  if _ticket is not null then
    select * into item from public.booking_safety_cases where id = _ticket;
    if found then
      _title := replace(replace(_title, item.reference, item.case_reference), item.category_reference, item.case_reference);
      if _title in ('Ticket ' || item.case_reference || ' received',
          'Your lesson is under review · ' || item.case_reference,
          'Teaching session under review · ' || item.case_reference) then
        event := 'ticket_opened';
      end if;
    end if;
  elsif _title in ('Subscription updated', 'Subscription renewal declined') then
    -- The membership synchronizer can run lazily during an authenticated read.
    event := 'subscription_renewal';
  end if;
  -- Cache invalidation must still happen when the actor's alert is suppressed.
  perform private.bump_workspace(_owner);
  insert into public.notifications(user_id, kind, title, body, data)
  values (_owner, 'system', _title, _body, jsonb_strip_nulls(jsonb_build_object(
    'tab', _tab, 'ticketId', _ticket, 'bookingId', _booking, 'event', event)));
end;
$$;

create or replace function private.notify_new_bug_report() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
    select id,'system',
      case when id = new.reporter_id then 'Bug report received · ' else 'New bug report · ' end || new.case_reference,
      case when id = new.reporter_id then 'Support has received your bug report.'
        else 'A bug report is ready for triage in Safety & Quality.' end,
      jsonb_build_object('tab',case when role in ('admin','superUser') then 'safety' else 'tickets' end,
        'ticketId',new.id,'event','ticket_opened')
    from public.profiles where id = new.reporter_id or role in ('admin','superUser') order by id;
  return null;
end;
$$;

create or replace function public.admin_support_check_in() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  today date := (now() at time zone 'Africa/Johannesburg')::date;
  actionable integer;
  awaiting integer;
  overdue integer;
  message text;
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode = '42501'; end if;
  insert into private.admin_support_check_ins(admin_id, day) values (actor, today) on conflict do nothing;
  if not found then return jsonb_build_object('created', false); end if;
  select count(*) filter (where status in ('new','investigating')), count(*) filter (where status = 'waiting'),
    count(*) filter (where status in ('new','investigating') and response_due_at <= now())
  into actionable, awaiting, overdue
  from public.booking_safety_cases where assigned_to = actor and status <> 'resolved';
  message := case
    when overdue > 0 then format('You have %s ready for your review, including %s past the reply deadline. Start with the oldest. Every thoughtful reply helps.',
      case when actionable = 1 then '1 ticket' else actionable || ' tickets' end, overdue)
    when actionable > 0 then format('You have %s ready for your review. A timely first reply can make someone’s day.',
      case when actionable = 1 then '1 ticket' else actionable || ' tickets' end)
    when awaiting > 0 then 'Your action queue is clear. Thanks for following through on the tickets that needed you.'
    else 'Your assigned queue is clear. If you have time, a new ticket could use your help.' end;
  if awaiting > 0 then
    message := message || case when awaiting = 1 then ' 1 ticket is waiting for a participant.' else format(' %s tickets are waiting for participants.', awaiting) end;
  end if;
  perform private.award_admin_support_milestones(actor);
  insert into public.notifications(user_id, kind, title, body, data)
  values (actor, 'system', 'Your support check-in', message, jsonb_build_object(
    'tab', 'safety', 'scope', case when actionable + awaiting > 0 then 'mine' end, 'event', 'daily_reminder'));
  return jsonb_build_object('created', true, 'message', message, 'assigned', actionable + awaiting);
end;
$$;

revoke all on function private.open_invitation_attendance_ticket(uuid,uuid,text),
  private.notification_preference(), private.billing_notice(uuid,text,text,text,uuid,uuid),
  private.notify_new_bug_report() from public, anon, authenticated;
revoke all on function public.admin_support_check_in() from public, anon;
grant execute on function public.admin_support_check_in() to authenticated;

