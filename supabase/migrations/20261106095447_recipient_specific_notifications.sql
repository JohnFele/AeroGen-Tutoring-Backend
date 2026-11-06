create function private.lesson_notification_names(_student uuid, _tutor uuid)
returns table(student_name text, tutor_name text)
language sql stable set search_path = '' as $$
  select
    coalesce((select nullif(btrim(first_name),'') from public.profiles where id=_student), 'your student'),
    coalesce((select nullif(btrim(public_name),'') from public.tutor_profiles where user_id=_tutor),
             (select nullif(btrim(first_name),'') from public.profiles where id=_tutor), 'your tutor');
$$;
revoke all on function private.lesson_notification_names(uuid,uuid) from public,anon,authenticated;

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
      body := format('The lesson with %s on %s is complete. %s',counterpart,label,
        case when recipient=new.student_id then 'You can review it in Calendar.' else 'Check Earnings for any funds released from this lesson.' end);
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

create or replace function private.payment_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  names record;
  student_title text;
  student_body text;
  tutor_title text;
  tutor_body text;
  managed_refund boolean;
  was_pending boolean := false;
begin
  if tg_op='UPDATE' then
    if old.status is not distinct from new.status then return null; end if;
    was_pending := old.status='pending';
  end if;
  perform private.bump_workspace(least(new.payer_id,new.payee_id));
  perform private.bump_workspace(greatest(new.payer_id,new.payee_id));
  -- Automatic credit reservation and funding are described in the booking-acceptance notice.
  if new.provider='demo' and new.status in ('pending','paid') and
      exists(select 1 from public.bookings where id=new.booking_id and status='pending') then return null; end if;

  select * into names from private.lesson_notification_names(new.payer_id,new.payee_id);
  if new.status='paid' then
    student_title := 'Your lesson is funded';
    student_body := format('Checkout for your lesson with %s is complete. Open Calendar for the booking details.',names.tutor_name);
    tutor_title := 'Lesson funding secured';
    tutor_body := format('Funding for your lesson with %s is secured. Earnings are held until lesson completion is confirmed.',names.student_name);
  elsif new.status in ('refunded','partially_refunded') then
    select exists(select 1 from private.lesson_funds where payment_id=new.id and state='refunded') into managed_refund;
    -- A managed full refund sends its own student notice with the cash and credit details.
    if not (managed_refund and new.status='refunded') then
      student_title := case when new.status='refunded' then 'Your lesson payment was refunded' else 'Your lesson payment was partially refunded' end;
      student_body := format('A refund was recorded for your lesson with %s. Open Calendar for the booking details.',names.tutor_name);
    end if;
    if not was_pending then
      tutor_title := 'Lesson earnings adjusted';
      tutor_body := format('A refund affected the payment for your lesson with %s. Open Earnings for details.',names.student_name);
    end if;
  elsif new.status='failed' then
    student_title := 'Your lesson payment did not go through';
    student_body := format('Payment for your lesson with %s failed. Open Calendar to check the booking and try again if available.',names.tutor_name);
    tutor_title := 'Lesson funding still outstanding';
    tutor_body := format('Funding for your lesson with %s is incomplete. Wait for confirmation before the lesson goes ahead.',names.student_name);
  else
    student_title := 'Your lesson payment is processing';
    student_body := format('Payment for your lesson with %s is being processed. Check Calendar for updates.',names.tutor_name);
    tutor_title := 'Lesson funding is processing';
    tutor_body := format('Payment for your lesson with %s is being processed. Earnings are available after the lesson is settled.',names.student_name);
  end if;
  if student_title is not null then
    insert into public.notifications(user_id,kind,title,body,data)
    values(new.payer_id,'payment',student_title,student_body,
      jsonb_build_object('tab','calendar','bookingId',new.booking_id,'paymentId',new.id));
  end if;
  if tutor_title is not null then
    insert into public.notifications(user_id,kind,title,body,data)
    values(new.payee_id,'payment',tutor_title,tutor_body,
      jsonb_build_object('tab','earnings','paymentId',new.id));
  end if;
  return null;
end;
$$;

create or replace function private.fund_accepted_booking(_booking uuid,_source text,_succeeds boolean,_request uuid,actor uuid,_accepting boolean) returns jsonb
language plpgsql security definer set search_path='' as $$
declare
  lesson public.bookings%rowtype;
  item private.memberships%rowtype;
  payment public.payments%rowtype;
  funds private.lesson_funds%rowtype;
  bps integer;
  result jsonb;
  result_status text;
  charge uuid;
  top_up integer := 0;
  cash_due integer;
  reserve_only boolean;
  target text := _booking::text || ':' || _source;
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

  select * into payment from public.payments where booking_id=lesson.id;
  if found then
    select * into funds from private.lesson_funds where booking_id=lesson.id;
    if payment.status <> 'pending' or funds.top_up_cents is null or funds.top_up_cents = 0 or funds.state <> 'held' then
      raise exception 'This lesson already has a payment.' using errcode='PT409';
    end if;
    if _source <> 'package' then
      raise exception 'A lesson credit is already reserved. Pay the remaining amount using package checkout.' using errcode='PT409';
    end if;
    result_status := private.mock_billing_result(_succeeds);
    result := private.record_mock_billing(actor,_request,'lesson',target,funds.top_up_cents,result_status);
    if result_status='failed' then return result; end if;
    update public.payments set status='paid', provider_reference='mock-' || (result->>'id'), paid_at=now() where id=payment.id;
  else
    cash_due := round(lesson.total_amount*100);
    if _source='package' then
      if lesson.duration_minutes > 60 then
        raise exception 'A credit covers up to R230 towards a lesson of 60 minutes or less.' using errcode='PT409';
      end if;
      item := private.sync_membership(actor);
      if (private.lesson_credit_balance(actor)->>'available')::bigint < 1 then
        raise exception 'You have no available lesson credits. Choose a separate payment or buy a package.' using errcode='PT409';
      end if;
      top_up := greatest(cash_due - private.lesson_credit_allowance_cents(),0);
      cash_due := top_up;
    end if;

    reserve_only := _accepting and top_up > 0;
    if not reserve_only then
      result_status := private.mock_billing_result(cash_due=0 or _succeeds);
      result := private.record_mock_billing(actor,_request,'lesson',target,cash_due,result_status);
      if result_status='failed' then return result; end if;
    end if;

    if _source='package' and item.period_start is not null then
      update private.memberships set credits_used=credits_used+1 where owner=actor;
    end if;
    select p.fee_bps into bps from private.billing_plans p where p.id=coalesce((
      select case when m.period_end <= now() and not m.renewal_succeeds then 'basic'
        when m.period_end <= now() then coalesce(m.next_plan_id,m.plan_id) else m.plan_id end
      from private.memberships m where m.owner=lesson.tutor_id
    ),'basic') and p.audience='tutor';
    insert into public.payments(booking_id,payer_id,payee_id,provider,provider_reference,status,amount,platform_fee,paid_at)
    values(lesson.id,actor,lesson.tutor_id,'demo','mock-' || (result->>'id'),
      case when reserve_only then 'pending' else 'paid' end,lesson.total_amount,
      round(lesson.total_amount*coalesce(bps,1500)/10000,2),case when not reserve_only then now() end)
    returning id into charge;
    insert into private.lesson_funds(booking_id,payment_id,source,credit_period,top_up_cents)
      values(lesson.id,charge,_source,item.period_start,top_up);
    if reserve_only then
      return jsonb_build_object('status','pending','amount_cents',top_up);
    end if;
  end if;

  perform private.bump_workspace(actor);
  return result;
end;
$$;

create or replace function private.settle_lesson(_booking uuid,_release boolean) returns void
language plpgsql set search_path='' as $$
declare funds private.lesson_funds%rowtype; charge public.payments%rowtype; refund_cents integer;
begin
  select * into funds from private.lesson_funds where booking_id=_booking and state in ('held','disputed') for update;
  if not found then return; end if;
  select * into strict charge from public.payments where id=funds.payment_id;
  if _release and charge.status <> 'paid' then
    raise exception 'Lesson payment must be secured before releasing earnings.' using errcode='PT409';
  end if;
  update private.lesson_funds set state=case when _release then 'released' else 'refunded' end, settled_at=now()
    where booking_id=_booking;
  if _release then
    perform private.bump_workspace(charge.payee_id);
    insert into public.notifications(user_id,kind,title,body,data)
    values(charge.payee_id,'payment','Lesson earnings released',
      'The lesson has been settled. Your earnings are available for withdrawal.',
      jsonb_build_object('tab','earnings','paymentId',charge.id));
  else
    refund_cents := case when charge.status <> 'paid' then 0 when funds.source='package' then funds.top_up_cents
      else round(charge.amount*100)::integer end;
    update public.payments set status='refunded' where id=charge.id;
    if funds.source='package' then
      perform private.billing_lock(charge.payer_id);
      update private.memberships set credits_used=greatest(credits_used-1,0)
        where owner=charge.payer_id and period_start=funds.credit_period and period_end>now();
    end if;
    perform private.record_mock_billing(charge.payer_id,gen_random_uuid(),'refund',_booking::text,refund_cents,private.mock_billing_result(true));
    insert into public.notifications(user_id,kind,title,body,data)
    values(charge.payer_id,'payment',
      case when funds.source='package' and refund_cents=0 then 'Your lesson credit was returned'
           else 'Your lesson refund was recorded' end,
      case when funds.source='checkout' then 'The simulated refund was returned to the original payment method.'
           when refund_cents > 0 then 'One lesson credit was returned and the simulated top-up was refunded.'
           else 'One lesson credit was returned to your balance.' end,jsonb_build_object('tab','payments','paymentId',charge.id));
  end if;
end;
$$;

create or replace function public.confirm_lesson_outcome(_booking uuid,_happened boolean,_reason text) returns text
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); lesson public.bookings%rowtype;
  previous private.lesson_outcomes%rowtype; responses integer; confirmed integer; result text; names record;
begin
  perform private.assert_platform_available();
  select * into lesson from public.bookings where id=_booking and actor in (student_id,tutor_id);
  if not found then raise exception 'This lesson is unavailable.' using errcode='42501'; end if;
  perform private.lock_booking_participants(lesson.student_id,lesson.tutor_id);
  select * into strict lesson from public.bookings where id=_booking for update;
  select * into previous from private.lesson_outcomes where booking_id=_booking and participant=actor;
  if found then
    if previous.happened is not distinct from _happened and coalesce(previous.reason,'')=btrim(coalesce(_reason,'')) then
      return 'recorded';
    end if;
    raise exception 'Your response was already recorded. Use the ticket if it needs review.' using errcode='PT409';
  end if;
  if lesson.status <> 'confirmed' or lesson.ends_at > now() then
    raise exception 'Respond after the scheduled end of a confirmed lesson.' using errcode='PT409';
  end if;
  if lesson.payment_required and not private.lesson_payment_secured(_booking) then
    raise exception 'This lesson needs a payment or package credit before its outcome can be recorded.' using errcode='PT409';
  end if;
  if _happened is null or char_length(coalesce(_reason,''))>2000
    or (not _happened and char_length(btrim(coalesce(_reason,'')))<10) then
    raise exception 'Give a reason of 10 to 2,000 characters if the lesson did not happen.' using errcode='22023';
  end if;
  insert into private.lesson_outcomes values(_booking,actor,_happened,nullif(btrim(_reason),''),now());
  perform private.bump_workspace(least(lesson.student_id,lesson.tutor_id));
  perform private.bump_workspace(greatest(lesson.student_id,lesson.tutor_id));
  select count(*),count(*) filter(where happened) into responses,confirmed from private.lesson_outcomes where booking_id=_booking;
  if exists(select 1 from public.booking_safety_cases where booking_id=_booking and dispute) then return 'disputed'; end if;
  if responses=2 then
    if confirmed=1 then
      perform private.open_lesson_dispute(lesson,'The student and tutor gave different answers about whether this lesson happened.');
      return 'disputed';
    end if;
    result := case when confirmed=2 then 'completed' else 'no_show' end;
    perform private.settle_lesson(_booking,confirmed=2);
    update public.bookings set status=result where id=_booking;
    return result;
  end if;
  select * into names from private.lesson_notification_names(lesson.student_id,lesson.tutor_id);
  insert into public.notifications(user_id,kind,title,body,data)
  values(case when actor=lesson.student_id then lesson.tutor_id else lesson.student_id end,'booking',
    case when actor=lesson.student_id then 'Confirm the lesson you taught' else 'Confirm your lesson' end,
    format('A response from %s is ready. Open Calendar to confirm whether the lesson took place.',
      case when actor=lesson.student_id then names.student_name else names.tutor_name end),
    jsonb_build_object('tab','calendar','bookingId',_booking));
  return 'recorded';
end;
$$;

create or replace function private.open_lesson_dispute(_booking public.bookings,_description text) returns void
language plpgsql set search_path='' as $$
declare ticket uuid; ref text;
begin
  update private.lesson_funds set state='disputed' where booking_id=_booking.id and state='held';
  insert into public.booking_safety_cases(booking_id,reporter_id,category,subject,description,dispute)
  values(_booking.id,_booking.student_id,'lesson_dispute','Lesson completion dispute',_description,true)
  on conflict do nothing returning id,reference into ticket,ref;
  if ticket is not null then
    perform private.bump_workspace(least(_booking.student_id,_booking.tutor_id));
    perform private.bump_workspace(greatest(_booking.student_id,_booking.tutor_id));
    perform private.billing_notice(_booking.student_id,'Your lesson is under review · '||ref,'Support is reviewing the lesson. Any payment or lesson credit stays on hold until they reach a decision. Open the ticket for updates.','tickets',ticket);
    perform private.billing_notice(_booking.tutor_id,'Teaching session under review · '||ref,'Support is reviewing the lesson. Any earnings stay on hold until they reach a decision. Open the ticket for updates.','tickets',ticket);
  end if;
end;
$$;
