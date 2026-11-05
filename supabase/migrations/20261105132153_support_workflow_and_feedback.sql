create function private.ticket_category_code(category text) returns text
language sql immutable set search_path = '' as $$
  select case category
    when 'billing' then 'BIL' when 'account' then 'ACC' when 'technical' then 'TEC'
    when 'safety' then 'SAF' when 'conduct' then 'CON' when 'lesson_quality' then 'QLT'
    when 'lesson_dispute' then 'DSP' else 'OTH'
  end;
$$;

alter table public.booking_safety_cases
  add column category_reference text generated always as (
    private.ticket_category_code(category) || '-' || split_part(reference, '-', 2)
  ) stored unique,
  add column auto_resolved_at timestamptz;

grant select(category_reference, assigned_to, auto_resolved_at) on public.booking_safety_cases to authenticated;

create or replace function private.billing_notice(_owner uuid,_title text,_body text,_tab text,_ticket uuid default null,_booking uuid default null) returns void
language plpgsql set search_path = '' as $$
declare old_reference text; coded_reference text;
begin
  if _ticket is not null then
    select reference, category_reference into old_reference, coded_reference
    from public.booking_safety_cases where id = _ticket;
    if found then _title := replace(_title, old_reference, coded_reference); end if;
  end if;
  insert into public.notifications(user_id,kind,title,body,data)
  values(_owner,'system',_title,_body,jsonb_strip_nulls(jsonb_build_object('tab',_tab,'ticketId',_ticket,'bookingId',_booking)));
end;
$$;

create or replace function private.lesson_billing_summary(_booking uuid,_actor uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'payment_state',coalesce((select state from private.lesson_funds where booking_id=_booking),
      (select status from public.payments where booking_id=_booking)),
    'outcome_submitted',exists(select 1 from private.lesson_outcomes where booking_id=_booking and participant=_actor),
    'ticket_reference',(select reference from public.booking_safety_cases where booking_id=_booking and dispute),
    'ticket_category_reference',(select category_reference from public.booking_safety_cases where booking_id=_booking and dispute)
  );
$$;

create or replace function public.my_support_tickets(_offset integer default 0) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account();
begin
  perform private.assert_platform_available();
  return query select jsonb_build_object('id',c.id,'reference',c.reference,'category_reference',c.category_reference,
    'subject',c.subject,'category',c.category,'status',c.status,'updated_at',c.updated_at)
  from public.booking_safety_cases c where c.reporter_id=actor or (c.dispute and exists(
    select 1 from public.bookings b where b.id=c.booking_id and b.tutor_id=actor
  )) order by c.updated_at desc,c.id limit 25 offset greatest(coalesce(_offset,0),0);
end;
$$;

create or replace function public.create_support_ticket(_category text,_subject text,_description text,_request uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
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
    perform private.billing_notice(actor,'Ticket '||item.category_reference||' received','Support has received your ticket.','tickets',item.id);
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference);
end;
$$;

create or replace function public.report_booking_ticket(_booking uuid,_category text,_description text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); ticket uuid; ref text; coded_ref text;
begin
  ticket := public.report_booking_concern(_booking,_category,_description);
  select reference, category_reference into strict ref, coded_ref from public.booking_safety_cases where id=ticket;
  if not exists(select 1 from public.notifications where user_id=actor and data->>'ticketId'=ticket::text
    and title in ('Ticket '||ref||' received', 'Ticket '||coded_ref||' received')) then
    perform private.billing_notice(actor,'Ticket '||coded_ref||' received','Support has received your booking concern.','tickets',ticket);
  end if;
  return jsonb_build_object('id',ticket,'reference',ref,'category_reference',coded_ref);
end;
$$;

create index support_ticket_waiting_idx on public.booking_safety_cases(updated_at, id)
where status = 'waiting' and not dispute and category not in ('safety', 'conduct', 'lesson_dispute');
create index support_ticket_assignee_idx on public.booking_safety_cases(assigned_to, status)
where assigned_to is not null;

alter table private.ticket_replies add column first_response_on_time boolean;
create index support_staff_reply_author_idx on private.ticket_replies(author, id) where from_support;
create index support_first_staff_reply_idx on private.ticket_replies(ticket_id, created_at, id) where from_support;

with first_replies as (
  select distinct on (ticket_id) id, ticket_id, created_at
  from private.ticket_replies where from_support order by ticket_id, created_at, id
)
update private.ticket_replies r
set first_response_on_time = f.created_at <= c.created_at + interval '24 hours'
from first_replies f join public.booking_safety_cases c on c.id = f.ticket_id
where r.id = f.id;

create table private.support_reply_ratings (
  reply_id uuid not null references private.ticket_replies(id) on delete restrict,
  participant_id uuid not null references public.profiles(id) on delete cascade,
  score smallint not null check (score between 1 and 5),
  created_at timestamptz not null default now(),
  primary key (reply_id, participant_id)
);
create table private.admin_support_check_ins (
  admin_id uuid not null references public.profiles(id) on delete cascade,
  day date not null,
  primary key (admin_id, day)
);
create table private.admin_support_milestones (
  admin_id uuid not null references public.profiles(id) on delete cascade,
  milestone text not null check (milestone in ('first_reply', 'five_resolutions', 'timely_twenty', 'helpful_ten')),
  earned_at timestamptz not null default now(),
  primary key (admin_id, milestone)
);

alter table private.support_reply_ratings enable row level security;
alter table private.admin_support_check_ins enable row level security;
alter table private.admin_support_milestones enable row level security;
revoke all on private.support_reply_ratings, private.admin_support_check_ins, private.admin_support_milestones from public, anon, authenticated;

create function private.admin_support_stats(_admin uuid) returns jsonb
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
      where c.assigned_to = _admin and c.status = 'resolved' and c.auto_resolved_at is null)
  ) from work w cross join feedback f;
$$;

create function private.award_admin_support_milestones(_admin uuid) returns void
language plpgsql set search_path = '' as $$
declare
  stats jsonb;
  earned record;
begin
  if not exists (select 1 from public.profiles where id = _admin and role in ('admin', 'superUser')) then return; end if;
  stats := private.admin_support_stats(_admin);
  for earned in
    with criteria(key, title, body, achieved) as (values
      ('first_reply', 'First support reply', 'You made someone’s next step clearer. Thanks for getting them started.', (stats->>'replies')::int >= 1),
      ('five_resolutions', 'Five tickets resolved', 'Five people or cases have a clearer outcome because you followed through.', (stats->>'resolved')::int >= 5),
      ('timely_twenty', 'Twenty timely first replies', 'You helped twenty requests get an answer within a day. Keep that momentum going.', (stats->>'on_time')::int >= 20),
      ('helpful_ten', 'Ten helpful ratings', 'Participants rated ten of your replies four stars or higher. Your care is making a difference.', (stats->>'helpful')::int >= 10)
    ), newly_earned as (
      insert into private.admin_support_milestones(admin_id, milestone)
      select _admin, key from criteria where achieved order by key
      on conflict do nothing returning milestone
    )
    select c.title, c.body from criteria c join newly_earned n on n.milestone = c.key
  loop
    perform private.billing_notice(_admin, 'Milestone earned · ' || earned.title, earned.body, 'safety');
  end loop;
end;
$$;

create function private.mark_first_support_reply() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.from_support and not exists (
    select 1 from private.ticket_replies where ticket_id = new.ticket_id and from_support
  ) then
    select new.created_at <= c.created_at + interval '24 hours' into new.first_response_on_time
    from public.booking_safety_cases c where c.id = new.ticket_id;
  end if;
  return new;
end;
$$;

create trigger support_first_reply before insert on private.ticket_replies
for each row execute function private.mark_first_support_reply();

create function private.notify_support_reply() returns trigger
language plpgsql set search_path = '' as $$
declare item public.booking_safety_cases%rowtype;
begin
  if new.from_support then
    perform private.award_admin_support_milestones(new.author);
  else
    select * into item from public.booking_safety_cases where id = new.ticket_id;
    if item.assigned_to is not null then
      perform private.billing_notice(item.assigned_to, 'New reply · ' || item.category_reference,
        'Someone replied to a ticket you’re helping with. A quick follow-up can keep things moving.', 'safety', item.id);
    end if;
  end if;
  return null;
end;
$$;

create trigger support_reply_notification after insert on private.ticket_replies
for each row execute function private.notify_support_reply();

create function private.notify_support_assignment() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.assigned_to is distinct from old.assigned_to and new.assigned_to is not null and new.status <> 'resolved' then
    perform private.billing_notice(new.assigned_to, 'Assigned to you · ' || new.category_reference,
      'This ticket is in your queue. A thoughtful first reply can make a real difference.', 'safety', new.id);
  end if;
  if new.status = 'resolved' and old.status <> 'resolved' and new.auto_resolved_at is null and new.assigned_to is not null then
    perform private.award_admin_support_milestones(new.assigned_to);
  end if;
  return null;
end;
$$;

create trigger support_assignment_notification after update of assigned_to, status on public.booking_safety_cases
for each row execute function private.notify_support_assignment();

create or replace function private.ticket_thread(_ticket uuid, _viewer uuid) returns jsonb
language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'mine',r.author=_viewer,'from_support',r.from_support,
    'body',r.body,'created_at',r.created_at,'rating',f.score) order by r.created_at,r.id),'[]'::jsonb)
  from (select * from private.ticket_replies where ticket_id=_ticket order by created_at desc,id desc limit 200) r
  left join private.support_reply_ratings f on f.reply_id = r.id and f.participant_id = _viewer;
$$;

create or replace function public.my_support_ticket(_ticket uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  select * into item from public.booking_safety_cases c where id = _ticket and (c.reporter_id = actor or (c.dispute and exists (
    select 1 from public.bookings where id = c.booking_id and tutor_id = actor)));
  if not found then raise exception 'Ticket not found.' using errcode = 'PT404'; end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'subject',item.subject,'category',item.category,
    'description',item.description,'status',item.status,'auto_resolved_at',item.auto_resolved_at,
    'thread',private.ticket_thread(item.id,actor));
end;
$$;

create function public.rate_support_reply(_ticket uuid, _reply uuid, _score integer) returns void
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); staff uuid;
begin
  perform private.assert_platform_available();
  if _score is null or _score not between 1 and 5 then
    raise exception 'Choose a rating from one to five.' using errcode = '22023';
  end if;
  select r.author into staff from private.ticket_replies r
  join public.booking_safety_cases c on c.id = r.ticket_id
  where c.id = _ticket and r.id = _reply and r.from_support and r.author <> actor and
    (c.reporter_id = actor or (c.dispute and exists (
      select 1 from public.bookings b where b.id = c.booking_id and b.tutor_id = actor
    )));
  if not found then raise exception 'Support reply not found.' using errcode = 'PT404'; end if;
  insert into private.support_reply_ratings(reply_id, participant_id, score) values (_reply, actor, _score)
    on conflict do nothing;
  if found then
    perform private.award_admin_support_milestones(staff);
  elsif not exists (select 1 from private.support_reply_ratings where reply_id = _reply and participant_id = actor and score = _score) then
    raise exception 'You already rated this reply.' using errcode = 'PT409';
  end if;
end;
$$;

create function public.my_admin_support_progress() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := (select auth.uid());
begin
  if not private.is_platform_admin() then raise exception 'Administrator access required.' using errcode = '42501'; end if;
  return private.admin_support_stats(actor) || jsonb_build_object('milestones',
    coalesce((select jsonb_object_agg(milestone, earned_at) from private.admin_support_milestones where admin_id = actor), '{}'::jsonb));
end;
$$;

create function public.admin_support_check_in() returns jsonb
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
  values (actor, 'system', 'Your support check-in', message, jsonb_build_object('tab', 'safety', 'scope', case when actionable + awaiting > 0 then 'mine' end));
  return jsonb_build_object('created', true, 'message', message, 'assigned', actionable + awaiting);
end;
$$;

create function private.resolve_inactive_support_tickets() returns integer
language plpgsql set search_path = '' as $$
declare
  item record;
  total integer := 0;
begin
  for item in
    with expired as (
      select id from public.booking_safety_cases
      where status = 'waiting' and updated_at <= now() - interval '31 days'
        and not dispute and category not in ('safety', 'conduct', 'lesson_dispute')
      order by updated_at, id limit 250 for update skip locked
    )
    update public.booking_safety_cases c
    set status = 'resolved', version = version + 1, updated_at = now(), auto_resolved_at = now(),
      outcome = 'Automatically resolved after 31 days without a participant reply.'
    from expired e where c.id = e.id
    returning c.id, c.category_reference, c.reporter_id
  loop
    perform private.billing_notice(item.reporter_id, 'Ticket ' || item.category_reference || ' closed',
      'This ticket was resolved after 31 days without a reply. If you still need help, open a new ticket and include this reference.', 'tickets', item.id);
    total := total + 1;
  end loop;
  return total;
end;
$$;

revoke all on function private.ticket_category_code(text), private.admin_support_stats(uuid),
  private.award_admin_support_milestones(uuid), private.mark_first_support_reply(), private.notify_support_reply(),
  private.notify_support_assignment(), private.resolve_inactive_support_tickets() from public, anon, authenticated;
revoke all on function public.rate_support_reply(uuid,uuid,integer), public.my_admin_support_progress(),
  public.admin_support_check_in() from public, anon, authenticated;
grant execute on function public.rate_support_reply(uuid,uuid,integer), public.my_admin_support_progress(), public.admin_support_check_in() to authenticated;

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $job$select cron.schedule('aerogen-support-inactivity','17 * * * *','select private.resolve_inactive_support_tickets()')$job$;
  end if;
end;
$$;
