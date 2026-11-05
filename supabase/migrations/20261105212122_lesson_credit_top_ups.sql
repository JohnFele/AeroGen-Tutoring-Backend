-- A credit contributes up to R230 towards an eligible lesson. The payment
-- amount is the full lesson value used for settlement, including the credit.
alter table private.lesson_funds add column top_up_cents integer not null default 0
  check (top_up_cents >= 0 and (top_up_cents = 0 or source = 'package'));

create function private.lesson_credit_allowance_cents() returns integer
language sql immutable set search_path = '' as $$ select 23000 $$;
revoke all on function private.lesson_credit_allowance_cents() from public,anon,authenticated;

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
  perform private.billing_notice(lesson.tutor_id,'Lesson payment secured','Funds are held until both participants confirm the lesson.','earnings');
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
    perform private.billing_notice(charge.payee_id,'Lesson earnings released','The lesson has been settled. Your earnings are available for withdrawal.','earnings');
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
    perform private.billing_notice(charge.payer_id,'Lesson refund recorded',
      case when funds.source='checkout' then 'The simulated refund was returned to the original payment method.'
           when refund_cents > 0 then 'One lesson credit was returned and the simulated top-up was refunded.'
           else 'One lesson credit was returned to your balance.' end,'payments');
  end if;
end;
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
    eligible := item.duration_minutes<=60;
    if paid_package and (not eligible or credits<1) then
      raise exception '%',case when not eligible then 'Package bookings must be 60 minutes or less.'
        else 'The student has no available package credits. No booking was accepted.' end using errcode='PT409';
    end if;
    if eligible and credits>0 then
      perform private.fund_accepted_booking(item.id,'package',true,gen_random_uuid(),item.student_id,true);
    end if;
  end if;
  return public.respond_to_booking_legacy(_booking,_action);
end;
$$;

create or replace function private.lesson_billing_summary(_booking uuid,_actor uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'payment_required',(select payment_required from public.bookings where id=_booking),
    'payment_secured',private.lesson_payment_secured(_booking),
    'top_up_due_cents',(select f.top_up_cents from private.lesson_funds f join public.payments p on p.id=f.payment_id
      where f.booking_id=_booking and p.payer_id=_actor and p.status='pending' and f.top_up_cents>0),
    'payment_source',(select source from private.lesson_funds where booking_id=_booking),
    'payment_state',coalesce((select state from private.lesson_funds where booking_id=_booking),
      (select status from public.payments where booking_id=_booking)),
    'outcome_submitted',exists(select 1 from private.lesson_outcomes where booking_id=_booking and participant=_actor),
    'ticket_reference',(select reference from public.booking_safety_cases where booking_id=_booking and dispute),
    'ticket_category_reference',(select category_reference from public.booking_safety_cases where booking_id=_booking and dispute),
    'ticket_case_reference',(select case_reference from public.booking_safety_cases where booking_id=_booking and dispute)
  );
$$;

create or replace function public.my_account_billing() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype; account_role text;
begin
  perform private.assert_platform_available();
  item := private.sync_membership(actor);
  select role into account_role from public.profiles where id=actor;
  return jsonb_build_object(
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
