-- Self-service subscriptions, simulated transfers and a shared support queue.
create table private.billing_plans (
  id text primary key, audience text not null check (audience in ('student','tutor')),
  name text not null, price_cents integer not null check (price_cents >= 0),
  lesson_credits integer not null default 0, fee_bps integer not null default 0
);
insert into private.billing_plans values
  ('payg','student','Pay Per Session',0,0,0),('learning','student','Learning Package',179900,8,0),
  ('premium','student','Premium Success',349900,16,0),('basic','tutor','Basic Tutor',0,0,1500),
  ('pro','tutor','Pro Tutor',19900,0,1000),('elite','tutor','Elite Tutor',39900,0,500);

create table private.memberships (
  owner uuid primary key references public.profiles(id) on delete restrict,
  plan_id text not null references private.billing_plans(id),
  next_plan_id text references private.billing_plans(id),
  period_start timestamptz, period_end timestamptz,
  credits_used integer not null default 0 check (credits_used >= 0),
  renewal_succeeds boolean not null default true,
  check ((period_start is null and period_end is null) or (period_start is not null and period_end > period_start))
);
create index memberships_renewal_idx on private.memberships(period_end) where period_end is not null;

create table private.billing_events (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null references public.profiles(id) on delete restrict,
  request_id uuid not null,
  kind text not null check (kind in ('subscription','renewal','lesson','payout','refund')),
  target text not null,
  amount_cents integer not null check (amount_cents >= 0),
  status text not null check (status in ('succeeded','failed','scheduled')),
  created_at timestamptz not null default now(),
  unique(owner,request_id)
);
create index billing_event_history_idx on private.billing_events(owner,created_at desc,id);

create table private.lesson_funds (
  booking_id uuid primary key references public.bookings(id) on delete restrict,
  payment_id uuid not null unique references public.payments(id) on delete restrict,
  source text not null check (source in ('checkout','package')),
  credit_period timestamptz,
  state text not null default 'held' check (state in ('held','disputed','released','refunded')),
  settled_at timestamptz
);
create table private.lesson_outcomes (
  booking_id uuid not null references public.bookings(id) on delete restrict,
  participant uuid not null references public.profiles(id) on delete restrict,
  happened boolean not null, reason text, created_at timestamptz not null default now(),
  primary key (booking_id,participant),
  check (happened or coalesce(char_length(btrim(reason)),0) between 10 and 2000)
);

alter table private.billing_plans enable row level security;
alter table private.memberships enable row level security;
alter table private.billing_events enable row level security;
alter table private.lesson_funds enable row level security;
alter table private.lesson_outcomes enable row level security;
revoke all on private.billing_plans,private.memberships,private.billing_events,private.lesson_funds,private.lesson_outcomes from public,anon,authenticated;

alter table public.booking_safety_cases alter column booking_id drop not null;
alter table public.booking_safety_cases drop constraint booking_safety_cases_category_check,
  add constraint booking_safety_cases_category_check check (category in ('safety','conduct','lesson_quality','other','billing','account','technical','lesson_dispute'));
alter table public.booking_safety_cases drop constraint booking_safety_cases_status_check,
  add constraint booking_safety_cases_status_check check (status in ('new','investigating','waiting','resolved'));
create sequence private.ticket_reference_seq;
alter table public.booking_safety_cases
  add column reference text not null default ('AG-' || nextval('private.ticket_reference_seq'::regclass)::text) unique,
  add column subject text not null default 'Booking concern' check (char_length(btrim(subject)) between 4 and 120),
  add column response_due_at timestamptz not null default (now() + interval '24 hours'),
  add column updated_at timestamptz not null default now(),
  add column dispute boolean not null default false;
create unique index one_lesson_dispute on public.booking_safety_cases(booking_id) where dispute;
drop index public.booking_safety_cases_active_reporter_idx;
create unique index booking_safety_cases_active_reporter_idx on public.booking_safety_cases(reporter_id,booking_id)
  where status <> 'resolved' and not dispute;
create index support_ticket_owner_idx on public.booking_safety_cases(reporter_id,updated_at desc,id);
grant select(reference,subject,response_due_at,updated_at,version) on public.booking_safety_cases to authenticated;
create table private.ticket_replies (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.booking_safety_cases(id) on delete restrict,
  author uuid not null references public.profiles(id) on delete restrict,
  from_support boolean not null,
  body text not null check (char_length(btrim(body)) between 2 and 2000),
  created_at timestamptz not null default now()
);
create index ticket_reply_idx on private.ticket_replies(ticket_id,created_at,id);
alter table private.ticket_replies enable row level security;
revoke all on private.ticket_replies from public,anon,authenticated;

create function private.billing_account() returns uuid language plpgsql stable set search_path='' as $$
declare actor uuid := (select auth.uid());
begin
  if actor is null or not exists(select 1 from public.profiles where id=actor and role in ('student','tutor')) then
    raise exception 'Use your own student or tutor account for billing.' using errcode='42501';
  end if;
  return actor;
end;
$$;

create function private.billing_lock(_owner uuid) returns void language sql set search_path='' as $$
  select pg_advisory_xact_lock(hashtextextended(_owner::text,839));
$$;

-- The mock gateway completes synchronously. It receives no card or bank details.
create function private.mock_billing_result(_succeeds boolean) returns text
language sql immutable set search_path='' as $$
  select case when _succeeds is true then 'succeeded' else 'failed' end;
$$;

create function private.billing_notice(_owner uuid,_title text,_body text,_tab text,_ticket uuid default null,_booking uuid default null) returns void
language plpgsql set search_path='' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
  values(_owner,'system',_title,_body,jsonb_strip_nulls(jsonb_build_object('tab',_tab,'ticketId',_ticket,'bookingId',_booking)));
end;
$$;

create function private.billing_replay(_owner uuid,_request uuid,_kind text,_target text) returns jsonb
language plpgsql stable set search_path='' as $$
declare entry private.billing_events%rowtype;
begin
  if _request is null then raise exception 'A request key is required.' using errcode='22023'; end if;
  select * into entry from private.billing_events where owner=_owner and request_id=_request;
  if not found then return null; end if;
  if row(entry.kind,entry.target) is distinct from row(_kind,_target) then
    raise exception 'This request key belongs to a different action.' using errcode='PT409';
  end if;
  return jsonb_build_object('id',entry.id,'status',entry.status,'amount_cents',entry.amount_cents);
end;
$$;

create function private.record_mock_billing(_owner uuid,_request uuid,_kind text,_target text,_cents integer,_status text)
returns jsonb language plpgsql set search_path='' as $$
declare entry uuid;
begin
  if _kind in ('subscription','lesson','payout') and (select count(*) from private.billing_events
    where owner=_owner and kind=_kind and created_at>now()-interval '15 minutes') >= 20 then
    raise exception 'Too many attempts. Please try again in a few minutes.' using errcode='PT429';
  end if;
  insert into private.billing_events(owner,request_id,kind,target,amount_cents,status)
  values(_owner,_request,_kind,_target,_cents,_status) returning id into entry;
  return jsonb_build_object('id',entry,'status',_status,'amount_cents',_cents);
end;
$$;

create function private.sync_membership(_owner uuid) returns private.memberships
language plpgsql set search_path='' as $$
declare item private.memberships%rowtype; tier private.billing_plans%rowtype; account_role text; starts timestamptz; renewal text;
begin
  perform private.billing_lock(_owner);
  select role into account_role from public.profiles where id=_owner;
  if account_role is null or account_role not in ('student','tutor') then return null; end if;
  insert into private.memberships(owner,plan_id)
    values(_owner,case when account_role='student' then 'payg' else 'basic' end) on conflict(owner) do nothing;
  select * into item from private.memberships where owner=_owner for update;
  if not exists(select 1 from private.billing_plans p where p.id=item.plan_id and p.audience=account_role) then
    update private.memberships set plan_id=case when account_role='student' then 'payg' else 'basic' end,
      next_plan_id=null,period_start=null,period_end=null,credits_used=0 where owner=_owner returning * into item;
  end if;
  if item.period_end <= now() then
    select * into strict tier from private.billing_plans where id=coalesce(item.next_plan_id,item.plan_id);
    if tier.price_cents > 0 then
      renewal := private.mock_billing_result(item.renewal_succeeds);
      perform private.record_mock_billing(_owner,gen_random_uuid(),'renewal',tier.id,tier.price_cents,renewal);
      if renewal='failed' then
        select * into strict tier from private.billing_plans where audience=account_role and price_cents=0;
      end if;
    end if;
    starts := case when tier.price_cents=0 then null when item.period_end + interval '30 days' <= now() then now() else item.period_end end;
    update private.memberships set plan_id=tier.id,next_plan_id=null,credits_used=0,
      period_start=starts,period_end=starts + interval '30 days' where owner=_owner returning * into item;
    perform private.billing_notice(_owner,case when renewal='failed' then 'Subscription renewal declined' else 'Subscription updated' end,
      'Your current plan is ' || tier.name || '.','pricing');
  end if;
  return item;
end;
$$;

create function public.change_membership(_plan text,_succeeds boolean,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype; tier private.billing_plans%rowtype;
  result jsonb; result_status text;
begin
  perform private.assert_platform_available();
  perform private.billing_lock(actor);
  result := private.billing_replay(actor,_request,'subscription',_plan);
  if result is not null then return result; end if;
  select p.* into tier from private.billing_plans p join public.profiles u on u.role=p.audience where p.id=_plan and u.id=actor;
  if not found then raise exception 'Choose a plan for your account type.' using errcode='22023'; end if;
  item := private.sync_membership(actor);
  if item.period_end is not null then
    update private.memberships set next_plan_id=case when item.plan_id=tier.id then null else tier.id end where owner=actor;
    return private.record_mock_billing(actor,_request,'subscription',tier.id,0,'scheduled');
  end if;
  if tier.price_cents=0 then raise exception 'This is already your plan.' using errcode='PT409'; end if;
  result_status := private.mock_billing_result(_succeeds);
  result := private.record_mock_billing(actor,_request,'subscription',tier.id,tier.price_cents,result_status);
  if result_status='succeeded' then
    update private.memberships set plan_id=tier.id,next_plan_id=null,period_start=now(),period_end=now()+interval '30 days',credits_used=0 where owner=actor;
    perform private.billing_notice(actor,'Subscription activated','Your ' || tier.name || ' plan is active.','pricing');
  end if;
  return result;
end;
$$;

create function public.set_mock_renewal_result(_succeeds boolean) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype;
begin
  perform private.assert_platform_available();
  item := private.sync_membership(actor);
  if item.period_end is null or _succeeds is null then raise exception 'Choose an outcome for an active subscription.' using errcode='22023'; end if;
  update private.memberships set renewal_succeeds=_succeeds where owner=actor;
end;
$$;

create function public.checkout_booking(_booking uuid,_source text,_succeeds boolean,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); lesson public.bookings%rowtype; item private.memberships%rowtype;
  tier private.billing_plans%rowtype; bps integer;
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
    select * into strict tier from private.billing_plans where id=item.plan_id;
    if item.credits_used >= tier.lesson_credits or item.period_end is null or lesson.starts_at >= item.period_end
      or lesson.duration_minutes > 60 or cents > 23000 then
      raise exception 'This lesson is not eligible for an available package credit.' using errcode='PT409';
    end if;
    update private.memberships set credits_used=credits_used+1 where owner=actor;
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
  perform private.billing_notice(lesson.tutor_id,'Lesson payment secured','Funds are held until both participants confirm the lesson.','earnings');
  return result;
end;
$$;

create function private.payout_balance(_tutor uuid) returns bigint
language sql stable set search_path='' as $$
  select coalesce((select sum(round((p.amount-p.platform_fee)*100)::bigint) from private.lesson_funds f
    join public.payments p on p.id=f.payment_id where p.payee_id=_tutor and f.state='released'),0)
    - coalesce((select sum(amount_cents) from private.billing_events where owner=_tutor and kind='payout' and status='succeeded'),0);
$$;

create function public.request_tutor_payout(_cents integer,_succeeds boolean,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); result jsonb;
begin
  perform private.assert_platform_available();
  if not exists(select 1 from public.profiles where id=actor and role='tutor') then
    raise exception 'Only tutors can withdraw released lesson earnings.' using errcode='42501';
  end if;
  perform private.billing_lock(actor);
  result := private.billing_replay(actor,_request,'payout',_cents::text);
  if result is not null then return result; end if;
  if _cents is null or _cents < 10000 or _cents > private.payout_balance(actor) then
    raise exception 'Withdraw at least R100 and no more than your released balance.' using errcode='22023';
  end if;
  result := private.record_mock_billing(actor,_request,'payout',_cents::text,_cents,private.mock_billing_result(_succeeds));
  perform private.billing_notice(actor,'Payout ' || (result->>'status'),'Your simulated withdrawal has been recorded.','earnings');
  return result;
end;
$$;

create function private.settle_lesson(_booking uuid,_release boolean) returns void
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
           else 'An eligible credit was returned to the original, still-active subscription period.' end,'payments');
  end if;
end;
$$;

create function private.refund_cancelled_lesson() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status is distinct from new.status and new.status='cancelled' then
    perform private.settle_lesson(new.id,false);
  end if;
  return new;
end;
$$;
create trigger refund_cancelled_lesson after update of status on public.bookings
  for each row execute function private.refund_cancelled_lesson();

create function private.open_lesson_dispute(_booking public.bookings,_description text) returns void
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
    perform private.billing_notice(_booking.student_id,'Lesson review '||ref,'Support will review the lesson before any funds are released.','tickets',ticket);
    perform private.billing_notice(_booking.tutor_id,'Lesson review '||ref,'Support will review the lesson before any funds are released.','tickets',ticket);
  end if;
end;
$$;

create function public.confirm_lesson_outcome(_booking uuid,_happened boolean,_reason text) returns text
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

-- Preserve the existing booking API while closing the unilateral completion route.
alter function public.respond_to_tutoring_booking(uuid,text) rename to respond_to_booking_legacy;
revoke all on function public.respond_to_booking_legacy(uuid,text) from public,anon,authenticated;
create function public.respond_to_tutoring_booking(_booking uuid,_action text) returns text
language plpgsql security definer set search_path='' as $$
begin
  if _action='complete' then return public.confirm_lesson_outcome(_booking,true,''); end if;
  return public.respond_to_booking_legacy(_booking,_action);
end;
$$;

create function private.lesson_billing_summary(_booking uuid,_actor uuid) returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object(
    'payment_state',coalesce((select state from private.lesson_funds where booking_id=_booking),
      (select status from public.payments where booking_id=_booking)),
    'outcome_submitted',exists(select 1 from private.lesson_outcomes where booking_id=_booking and participant=_actor),
    'ticket_reference',(select reference from public.booking_safety_cases where booking_id=_booking and dispute)
  );
$$;

create function public.my_account_billing() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item private.memberships%rowtype; account_role text;
begin
  perform private.assert_platform_available();
  item := private.sync_membership(actor);
  select role into account_role from public.profiles where id=actor;
  return jsonb_build_object(
    'membership',to_jsonb(item)-'owner',
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

-- Participant-only read with stable pagination for ticket history.
create function public.my_support_tickets(_offset integer default 0) returns setof jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := private.billing_account();
begin
  perform private.assert_platform_available();
  return query select jsonb_build_object('id',c.id,'reference',c.reference,'subject',c.subject,'category',c.category,
    'status',c.status,'updated_at',c.updated_at)
  from public.booking_safety_cases c where c.reporter_id=actor or (c.dispute and exists(
    select 1 from public.bookings b where b.id=c.booking_id and b.tutor_id=actor
  )) order by c.updated_at desc,c.id limit 25 offset greatest(coalesce(_offset,0),0);
end;
$$;

create function public.create_support_ticket(_category text,_subject text,_description text,_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  if _request is null or _category is null or _category not in ('billing','account','technical','other')
    or coalesce(char_length(btrim(_subject)),0) not between 4 and 120
    or coalesce(char_length(btrim(_description)),0) not between 20 and 2000 then
    raise exception 'Enter a subject, category and description.' using errcode='22023';
  end if;
  insert into public.booking_safety_cases(id,reporter_id,category,subject,description)
    values(_request,actor,_category,btrim(_subject),btrim(_description)) on conflict(id) do nothing
    returning * into item;
  if item.id is null then
    select * into item from public.booking_safety_cases where id=_request and reporter_id=actor and booking_id is null
      and category=_category and subject=btrim(_subject) and description=btrim(_description);
    if not found then raise exception 'This request key belongs to a different ticket.' using errcode='PT409'; end if;
  else
    perform private.billing_notice(actor,'Ticket '||item.reference||' received','Support has received your ticket.','tickets',item.id);
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference);
end;
$$;

create function private.ticket_thread(_ticket uuid,_viewer uuid) returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'mine',r.author=_viewer,'from_support',r.from_support,
    'body',r.body,'created_at',r.created_at) order by r.created_at,r.id),'[]'::jsonb)
  from (select * from private.ticket_replies where ticket_id=_ticket order by created_at desc,id desc limit 200) r;
$$;

create function public.my_support_ticket(_ticket uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  select * into item from public.booking_safety_cases c where id=_ticket and (c.reporter_id=actor or (c.dispute and exists(
    select 1 from public.bookings where id=c.booking_id and tutor_id=actor)));
  if not found then raise exception 'Ticket not found.' using errcode='PT404'; end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'subject',item.subject,'category',item.category,
    'description',item.description,'status',item.status,'thread',private.ticket_thread(item.id,actor));
end;
$$;

create function public.report_booking_ticket(_booking uuid,_category text,_description text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); ticket uuid; ref text;
begin
  ticket := public.report_booking_concern(_booking,_category,_description);
  select reference into strict ref from public.booking_safety_cases where id=ticket;
  if not exists(select 1 from public.notifications where user_id=actor and data->>'ticketId'=ticket::text and title='Ticket '||ref||' received') then
    perform private.billing_notice(actor,'Ticket '||ref||' received','Support has received your booking concern.','tickets',ticket);
  end if;
  return jsonb_build_object('id',ticket,'reference',ref);
end;
$$;

-- A confidential participant report is separate from the shared settlement dispute.
create or replace function public.report_booking_concern(_booking uuid,_category text,_description text) returns uuid
language plpgsql security definer set search_path='' as $$
declare actor uuid := (select auth.uid()); ticket uuid;
begin
  perform private.assert_platform_available();
  if actor is null or not exists(select 1 from public.bookings where id=_booking and actor in (student_id,tutor_id)) then
    raise exception 'This booking is unavailable.' using errcode='42501';
  end if;
  if _category is null or _category not in ('safety','conduct','lesson_quality','other')
    or coalesce(char_length(btrim(_description)),0) not between 20 and 2000 then
    raise exception 'Choose a category and describe the concern in 20 to 2,000 characters.' using errcode='22023';
  end if;
  insert into public.booking_safety_cases(booking_id,reporter_id,category,description)
  values(_booking,actor,_category,btrim(_description))
  on conflict(reporter_id,booking_id) where status<>'resolved' and not dispute do nothing returning id into ticket;
  if ticket is null then
    select id into ticket from public.booking_safety_cases where booking_id=_booking and reporter_id=actor
      and not dispute and status<>'resolved' and category=_category and description=btrim(_description);
    if ticket is null then raise exception 'You already have an open report for this booking.' using errcode='PT409'; end if;
  end if;
  return ticket;
end;
$$;

create function public.reply_support_ticket(_ticket uuid,_body text,_request uuid) returns void
language plpgsql security definer set search_path='' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype; inserted uuid;
begin
  perform private.assert_platform_available();
  select * into item from public.booking_safety_cases c where id=_ticket and (c.reporter_id=actor or (c.dispute and exists(
    select 1 from public.bookings where id=c.booking_id and tutor_id=actor))) for update;
  if not found then raise exception 'Ticket not found.' using errcode='PT404'; end if;
  if _request is null or coalesce(char_length(btrim(_body)),0) not between 2 and 2000 then
    raise exception 'Enter a reply between 2 and 2,000 characters.' using errcode='22023';
  end if;
  if exists(select 1 from private.ticket_replies where id=_request and ticket_id=_ticket and author=actor and body=btrim(_body)) then return; end if;
  if item.status='resolved' then raise exception 'This ticket is resolved. Open a new ticket for further help.' using errcode='PT409'; end if;
  insert into private.ticket_replies(id,ticket_id,author,from_support,body) values(_request,_ticket,actor,false,btrim(_body))
    on conflict(id) do nothing returning id into inserted;
  if inserted is null then raise exception 'This request key belongs to a different reply.' using errcode='PT409'; end if;
  update public.booking_safety_cases set status=case when status='waiting' then 'investigating' else status end,
    response_due_at=least(case when status='waiting' then now()+interval '24 hours' else response_due_at end,now()+interval '24 hours'),
    updated_at=now(),version=version+1 where id=_ticket;
end;
$$;

create function public.admin_support_ticket(_ticket uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare result jsonb; item public.booking_safety_cases%rowtype;
begin
  result := public.open_booking_safety_case(_ticket);
  select * into strict item from public.booking_safety_cases where id=_ticket;
  return result || jsonb_build_object('thread',private.ticket_thread(item.id,auth.uid()),'lesson_outcomes',
    case when item.dispute and item.status<>'resolved' then (
      select coalesce(jsonb_agg(jsonb_build_object('role',case when o.participant=b.student_id then 'Student' else 'Tutor' end,
        'happened',o.happened,'reason',o.reason)),'[]'::jsonb)
      from private.lesson_outcomes o join public.bookings b on b.id=o.booking_id where o.booking_id=item.booking_id
    ) else '[]'::jsonb end);
end;
$$;

create function public.update_support_ticket(_ticket uuid,_version integer,_status text,_reply text,_outcome text,_settlement text)
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
    or (_status in ('waiting','resolved') and coalesce(char_length(btrim(_reply)),0)<2)
    or (_status='resolved' and coalesce(char_length(btrim(_outcome)),0)<20) then
    raise exception 'Add a public reply and, when resolving, an internal note of at least 20 characters.' using errcode='22023';
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

-- Legacy case routes still read the same queue, but cannot bypass financial settlement.
alter function public.review_booking_safety_case(uuid,text,text,integer) rename to review_booking_safety_case_legacy;
revoke all on function public.review_booking_safety_case_legacy(uuid,text,text,integer) from public,anon,authenticated;
create function public.review_booking_safety_case(_case uuid,_status text,_outcome text,_version integer) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode='42501'; end if;
  if exists(select 1 from public.booking_safety_cases where id=_case and dispute) then
    raise exception 'Open the support ticket to resolve a lesson dispute.' using errcode='PT409';
  end if;
  perform public.review_booking_safety_case_legacy(_case,_status,_outcome,_version);
end;
$$;

create function private.process_billing_queue() returns void language plpgsql set search_path='' as $$
declare owner_id uuid; lesson public.bookings%rowtype;
begin
  if not private.platform_runtime_allowed() then return; end if;
  for owner_id in select owner from (select owner from private.memberships where period_end<=now() order by period_end limit 250) due order by owner loop
    if pg_try_advisory_xact_lock(hashtextextended(owner_id::text,839)) then
      perform private.sync_membership(owner_id);
    end if;
  end loop;
  for lesson in select b.* from public.bookings b join private.lesson_funds f on f.booking_id=b.id
    where b.status='confirmed' and b.ends_at<=now()-interval '72 hours' and f.state='held'
    order by b.ends_at limit 250 for update of b skip locked loop
    perform private.open_lesson_dispute(lesson,'Both participants did not confirm this funded lesson within 72 hours.');
  end loop;
end;
$$;

revoke all on function private.billing_account(),private.billing_lock(uuid),private.mock_billing_result(boolean),
  private.billing_notice(uuid,text,text,text,uuid,uuid),private.billing_replay(uuid,uuid,text,text),
  private.record_mock_billing(uuid,uuid,text,text,integer,text),private.sync_membership(uuid),private.payout_balance(uuid),
  private.settle_lesson(uuid,boolean),private.refund_cancelled_lesson(),private.open_lesson_dispute(public.bookings,text),
  private.lesson_billing_summary(uuid,uuid),private.ticket_thread(uuid,uuid),private.process_billing_queue()
  from public,anon,authenticated;

revoke all on function public.change_membership(text,boolean,uuid),public.set_mock_renewal_result(boolean),public.checkout_booking(uuid,text,boolean,uuid),
  public.request_tutor_payout(integer,boolean,uuid),public.confirm_lesson_outcome(uuid,boolean,text),
  public.respond_to_tutoring_booking(uuid,text),public.my_account_billing(),public.my_support_tickets(integer),
  public.create_support_ticket(text,text,text,uuid),public.my_support_ticket(uuid),public.reply_support_ticket(uuid,text,uuid),public.report_booking_ticket(uuid,text,text),
  public.admin_support_ticket(uuid),public.update_support_ticket(uuid,integer,text,text,text,text),
  public.review_booking_safety_case(uuid,text,text,integer) from public,anon,authenticated;

grant execute on function public.change_membership(text,boolean,uuid),public.set_mock_renewal_result(boolean),public.checkout_booking(uuid,text,boolean,uuid),
  public.request_tutor_payout(integer,boolean,uuid),public.confirm_lesson_outcome(uuid,boolean,text),
  public.respond_to_tutoring_booking(uuid,text),public.my_account_billing(),public.my_support_tickets(integer),
  public.create_support_ticket(text,text,text,uuid),public.my_support_ticket(uuid),public.reply_support_ticket(uuid,text,uuid),public.report_booking_ticket(uuid,text,text),
  public.admin_support_ticket(uuid),public.update_support_ticket(uuid,integer,text,text,text,text),
  public.review_booking_safety_case(uuid,text,text,integer) to authenticated;

-- Supabase supports pg_cron. Isolated development engines can exercise the worker directly.
do $$
begin
  if exists(select 1 from pg_available_extensions where name='pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $job$select cron.schedule('aerogen-billing-queue','*/15 * * * *','select private.process_billing_queue()')$job$;
  end if;
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
        'status',b.status,'teaching_mode',b.teaching_mode,'hourly_rate',b.hourly_rate,'total_amount',b.total_amount,
        'proposed_by',coalesce(b.proposed_by,b.student_id),'confirmed_at',b.confirmed_at,
        'special_requests',b.special_requests,'demo',sp.demo_dataset is not null) || private.lesson_billing_summary(b.id,caller) row_data
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
