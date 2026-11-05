-- Successful package charges award credits. Funded bookings are the ledger debits.
alter table private.billing_events add column lesson_credits_awarded integer not null default 0
  check (lesson_credits_awarded >= 0);
update private.billing_events e set lesson_credits_awarded = case p.id when 'learning' then 8 when 'premium' then 16 else p.lesson_credits end
from private.billing_plans p
where p.id = e.target and p.audience = 'student' and e.kind in ('subscription','renewal') and e.status = 'succeeded';
create index billing_credit_purchases on private.billing_events(owner, created_at desc, id) where lesson_credits_awarded > 0;

create function private.award_lesson_credits() returns trigger language plpgsql set search_path = '' as $$
begin
  if new.kind in ('subscription','renewal') and new.status = 'succeeded' then
    new.lesson_credits_awarded := coalesce((select lesson_credits from private.billing_plans where id = new.target and audience = 'student'),0);
  end if;
  return new;
end;
$$;
create trigger package_charge_credits before insert on private.billing_events
for each row execute function private.award_lesson_credits();

create function private.lesson_credit_balance(_student uuid) returns jsonb language sql stable set search_path = '' as $$
  with purchases as (
    select coalesce(sum(lesson_credits_awarded),0) as purchased from private.billing_events
    where owner = _student and lesson_credits_awarded > 0
  ), usage as (
    select count(*) filter (where f.state in ('held','disputed')) as reserved,
      count(*) filter (where f.state = 'released') as used,
      count(*) filter (where f.state = 'refunded') as restored
    from public.payments p join private.lesson_funds f on f.payment_id = p.id
    where p.payer_id = _student and f.source = 'package'
  )
  select jsonb_build_object('purchased',p.purchased,'reserved',u.reserved,'used',u.used,'restored',u.restored,
    'available',greatest(p.purchased - u.reserved - u.used,0))
  from purchases p cross join usage u;
$$;

-- Legacy historical appointments can retain their existing workflow.
alter table public.bookings add column payment_required boolean not null default false;
alter table public.bookings alter column payment_required set default true;
update public.bookings set payment_required = true where starts_at > now() and status in ('pending','confirmed');

create function private.lesson_payment_secured(_booking uuid) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.payments where booking_id = _booking and status = 'paid');
$$;

alter table public.booking_safety_cases add column participant_resolved_at timestamptz;

create function private.participant_can_resolve(_reporter uuid, _actor uuid, _status text, _category text, _dispute boolean)
returns boolean language sql immutable set search_path = '' as $$
  select _reporter = _actor and _status <> 'resolved' and not _dispute and _category not in ('safety','conduct','lesson_dispute');
$$;

create function public.resolve_support_ticket(_ticket uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  select * into item from public.booking_safety_cases where id = _ticket and reporter_id = actor for update;
  if not found then raise exception 'Ticket not found.' using errcode = 'PT404'; end if;
  if item.status = 'resolved' then return; end if;
  if not private.participant_can_resolve(item.reporter_id,actor,item.status,item.category,item.dispute) then
    raise exception 'Support needs to review and close this ticket.' using errcode = 'PT409';
  end if;
  update public.booking_safety_cases set status = 'resolved', participant_resolved_at = now(),
    outcome = 'The requester marked this ticket resolved.', updated_at = now(), version = version + 1
  where id = _ticket;
  if item.assigned_to is not null then
    perform private.billing_notice(item.assigned_to,'Ticket '||item.case_reference||' resolved',
      'The requester marked this ticket resolved.','safety',item.id);
  end if;
end;
$$;

revoke all on function private.award_lesson_credits(), private.lesson_credit_balance(uuid), private.lesson_payment_secured(uuid),
  private.participant_can_resolve(uuid,uuid,text,text,boolean), public.resolve_support_ticket(uuid) from public,anon,authenticated;
grant execute on function public.resolve_support_ticket(uuid) to authenticated;

create or replace function public.checkout_booking(_booking uuid,_source text,_succeeds boolean,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); lesson public.bookings%rowtype; item private.memberships%rowtype;
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
  if lesson.status <> 'confirmed' or lesson.starts_at <= now() then
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

create or replace function private.settle_lesson(_booking uuid,_release boolean) returns void
language plpgsql set search_path='' as $$
declare funds private.lesson_funds%rowtype; charge public.payments%rowtype;
begin
  select * into funds from private.lesson_funds where booking_id=_booking and state in ('held','disputed') for update;
  if not found then return; end if;
  select * into strict charge from public.payments where id=funds.payment_id;
  update private.lesson_funds set state=case when _release then 'released' else 'refunded' end, settled_at=now()
    where booking_id=_booking;
  if _release then
    perform private.billing_notice(charge.payee_id,'Lesson earnings released','The lesson has been settled. Your earnings are available for withdrawal.','earnings');
  else
    update public.payments set status='refunded' where id=charge.id;
    if funds.source='package' then
      perform private.billing_lock(charge.payer_id);
      update private.memberships set credits_used=greatest(credits_used-1,0)
        where owner=charge.payer_id and period_start=funds.credit_period and period_end>now();
    end if;
    perform private.record_mock_billing(charge.payer_id,gen_random_uuid(),'refund',_booking::text,
      case when funds.source='checkout' then round(charge.amount*100)::integer else 0 end,private.mock_billing_result(true));
    perform private.billing_notice(charge.payer_id,'Lesson refund recorded',
      case when funds.source='checkout' then 'The simulated refund was returned to the original payment method.'
           else 'One lesson credit was returned to your balance.' end,'payments');
  end if;
end;
$$;

create or replace function public.confirm_lesson_outcome(_booking uuid,_happened boolean,_reason text) returns text
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); lesson public.bookings%rowtype;
  previous private.lesson_outcomes%rowtype; responses integer; confirmed integer; result text;
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
  perform private.billing_notice(case when actor=lesson.student_id then lesson.tutor_id else lesson.student_id end,
    'Lesson response recorded','The other participant responded. Review your lesson in Calendar.','calendar',null,_booking);
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
  return 'recorded';
end;
$$;

create or replace function private.lesson_billing_summary(_booking uuid,_actor uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'payment_required',(select payment_required from public.bookings where id=_booking),
    'payment_secured',private.lesson_payment_secured(_booking),
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
      select b.id,b.starts_at,s.name as subject,b.status,f.state,p.amount,p.platform_fee,f.source
      from public.bookings b left join public.subjects s on s.id=b.subject_id
      join private.lesson_funds f on f.booking_id=b.id join public.payments p on p.id=f.payment_id
      where actor in (b.student_id,b.tutor_id) order by b.starts_at desc,b.id limit 50
    ) l),'[]'::jsonb)
  );
end;
$$;

create or replace function public.my_support_ticket(_ticket uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  select * into item from public.booking_safety_cases c where id = _ticket and (c.reporter_id = actor or (c.dispute and exists (
    select 1 from public.bookings where id = c.booking_id and tutor_id = actor)));
  if not found then raise exception 'Ticket not found.' using errcode = 'PT404'; end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'case_reference',item.case_reference,
    'reporter_kind',item.reporter_kind,'issue_code',item.issue_code,'subject',item.subject,'category',item.category,
    'description',item.description,'status',item.status,'participant_resolved_at',item.participant_resolved_at,
    'can_resolve',private.participant_can_resolve(item.reporter_id,actor,item.status,item.category,item.dispute),'auto_resolved_at',item.auto_resolved_at,'thread',private.ticket_thread(item.id,actor));
end;
$$;

create or replace function private.admin_support_stats(_admin uuid) returns jsonb
language sql stable set search_path = '' as $$
  with work as (
    select count(*) as replies, count(first_response_on_time) as first_responses,
      count(*) filter (where first_response_on_time) as on_time
    from private.ticket_replies where author = _admin and from_support
  ), feedback as (
    select count(*) as ratings, avg(f.score) as average_score, count(*) filter (where f.score >= 4) as helpful
    from private.support_reply_ratings f join private.ticket_replies r on r.id = f.reply_id
    where r.author = _admin and r.from_support
  )
  select jsonb_build_object(
    'replies', w.replies, 'first_responses', w.first_responses, 'on_time', w.on_time,
    'ratings', f.ratings, 'helpful', f.helpful, 'average_feedback', round(f.average_score, 2),
    'rating', case when f.ratings >= 3 then round(
      case when w.first_responses = 0 then f.average_score
      else 0.8 * f.average_score + 0.2 * (1 + 4 * w.on_time::numeric / w.first_responses) end, 2) end,
    'resolved', (select count(*) from public.booking_safety_cases c
      where c.assigned_to = _admin and c.status = 'resolved' and c.auto_resolved_at is null and c.participant_resolved_at is null)
  ) from work w cross join feedback f;
$$;

create or replace function public.update_support_ticket(_ticket uuid,_version integer,_status text,_reply text,_outcome text,_settlement text)
returns void language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); item public.booking_safety_cases%rowtype; staff_override boolean; lesson public.bookings%rowtype;
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
  perform private.billing_notice(item.reporter_id,'Ticket '||item.reference||' updated','Open your support ticket for the latest update.','tickets',_ticket);
end;
$$;

create or replace function private.process_billing_queue() returns void language plpgsql set search_path='' as $$
declare owner_id uuid; lesson public.bookings%rowtype;
begin
  if not private.platform_runtime_allowed() then return; end if;
  for owner_id in select owner from (select owner from private.memberships where period_end<=now() order by period_end limit 250) due order by owner loop
    if pg_try_advisory_xact_lock(hashtextextended(owner_id::text,839)) then
      perform private.sync_membership(owner_id);
    end if;
  end loop;
  -- Expire accepted bookings that reached their start time without secured payment.
  for lesson in select b.* from public.bookings b
    where b.status='confirmed' and b.payment_required and b.starts_at<=now()
      and not private.lesson_payment_secured(b.id)
    order by b.starts_at,b.id limit 250 for update of b skip locked loop
    if not private.lesson_payment_secured(lesson.id) then
      update public.bookings set status='cancelled' where id=lesson.id;
    end if;
  end loop;
  for lesson in select b.* from public.bookings b join private.lesson_funds f on f.booking_id=b.id
    where b.status='confirmed' and b.ends_at<=now()-interval '72 hours' and f.state='held'
    order by b.ends_at limit 250 for update of b skip locked loop
    perform private.open_lesson_dispute(lesson,'Both participants did not confirm this funded lesson within 72 hours.');
  end loop;
end;
$$;

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
         when new.status = 'confirmed' and new.payment_required and not private.lesson_payment_secured(new.id)
           then 'The time on ' || label || ' is accepted. The student needs to use a credit or pay before the lesson starts.'
         else 'Your lesson on ' || label || ' is ' || replace(new.status,'_',' ') || '.' end,
    jsonb_build_object('tab','calendar','bookingId',new.id)
  from (select distinct unnest(array[new.student_id,new.tutor_id]) recipient) recipients;
  return null;
end;
$$;
