create function private.support_reference(_category text, _actor text, _issue text, _created timestamptz, _number text)
returns text language sql immutable set search_path = '' as $$
  select _category || '-' || _actor || '-' || _issue || '-' ||
    to_char(_created at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"') || '-' || _number;
$$;

create function private.support_issue_code(_category text, _issue text) returns text
language sql immutable set search_path = '' as $$
  select case _category
    when 'billing' then case coalesce(_issue, 'payment') when 'payment' then 'PAY' when 'subscription' then 'SUB' when 'refund' then 'REF' when 'payout' then 'OUT' end
    when 'account' then case coalesce(_issue, 'profile') when 'profile' then 'PRO' when 'access' then 'ACC' end
    when 'technical' then case coalesce(_issue, 'bug') when 'bug' then 'BUG' when 'booking' then 'BKG' when 'messaging' then 'MSG' end
    when 'other' then case coalesce(_issue, 'general') when 'general' then 'GEN' when 'tutoring' then 'TUT' when 'booking' then 'BKG' end
    when 'safety' then case coalesce(_issue, 'incident') when 'incident' then 'INC' end
    when 'conduct' then case coalesce(_issue, 'behaviour') when 'behaviour' then 'BEH' end
    when 'lesson_quality' then case coalesce(_issue, 'quality') when 'quality' then 'QLT' end
    when 'lesson_dispute' then case coalesce(_issue, 'completion') when 'completion' then 'CMP' end
  end;
$$;

alter table public.booking_safety_cases add column reporter_kind text, add column issue_code text;

update public.booking_safety_cases c
set reporter_kind = case
      when exists(select 1 from public.bookings b where b.id = c.booking_id and b.student_id = c.reporter_id) then 'student'
      when exists(select 1 from public.bookings b where b.id = c.booking_id and b.tutor_id = c.reporter_id) then 'tutor'
      else coalesce((select p.role from public.profiles p where p.id = c.reporter_id and p.role in ('student', 'tutor')), 'unknown')
    end,
    issue_code = case
      when c.category = 'other' and c.booking_id is not null then 'BKG'
      when c.category in ('billing','account','technical','other') then 'GEN'
      else private.support_issue_code(c.category, null)
    end;

alter table public.booking_safety_cases
  alter column reporter_kind set not null,
  alter column issue_code set not null,
  add constraint support_reporter_kind_check check (reporter_kind in ('student', 'tutor', 'unknown')),
  add constraint support_issue_code_check check (issue_code ~ '^[A-Z]{3}$'),
  add column case_reference text generated always as (
    private.support_reference(private.ticket_category_code(category),
      case reporter_kind when 'student' then 'STU' when 'tutor' then 'TUT' else 'UNK' end,
      issue_code, created_at, split_part(reference, '-', 2))
  ) stored unique;
grant select (reporter_kind, issue_code, case_reference) on public.booking_safety_cases to authenticated;

create index support_case_reference_prefix on public.booking_safety_cases(case_reference text_pattern_ops);
create index support_case_reporter_activity on public.booking_safety_cases(reporter_id, created_at desc);
create index support_case_kind_date on public.booking_safety_cases(reporter_kind, created_at desc, id);

create function private.set_support_case_origin() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.reporter_kind := case
    when exists(select 1 from public.bookings b where b.id = new.booking_id and b.student_id = new.reporter_id) then 'student'
    when exists(select 1 from public.bookings b where b.id = new.booking_id and b.tutor_id = new.reporter_id) then 'tutor'
    else coalesce((select p.role from public.profiles p where p.id = new.reporter_id and p.role in ('student', 'tutor')), 'unknown')
  end;
  new.issue_code := coalesce(new.issue_code, case when new.category = 'other' and new.booking_id is not null then 'BKG'
    else private.support_issue_code(new.category, null) end);
  return new;
end;
$$;
create trigger support_case_origin before insert on public.booking_safety_cases
for each row execute function private.set_support_case_origin();

create function private.create_member_support_ticket(_category text,_issue text,_subject text,_description text,_request uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  actor uuid := private.billing_account();
  issue text := case when _issue is null then 'GEN' else private.support_issue_code(_category, _issue) end;
  item public.booking_safety_cases%rowtype;
begin
  perform private.assert_platform_available();
  if _request is null or _category is null or _category not in ('billing','account','technical','other') or issue is null
    or coalesce(char_length(btrim(_subject)),0) not between 4 and 120
    or coalesce(char_length(btrim(_description)),0) not between 20 and 2000 then
    raise exception 'Choose a category and issue, then enter a subject and description.' using errcode='22023';
  end if;
  if _issue = 'payout' and not exists (select 1 from public.profiles where id=actor and role='tutor') then
    raise exception 'Payout support is available to tutor accounts.' using errcode='22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(actor::text, 287));
  select * into item from public.booking_safety_cases where id = _request;
  if found then
    if item.reporter_id <> actor or item.booking_id is not null or item.category <> _category
      or item.issue_code <> issue or item.subject <> btrim(_subject) or item.description <> btrim(_description) then
      raise exception 'This request key belongs to a different ticket.' using errcode='PT409';
    end if;
  else
    if (select count(*) from public.booking_safety_cases c where c.reporter_id = actor
      and c.created_at > now() - interval '15 minutes') >= 8 then
      raise exception 'Too many recent tickets. Wait a few minutes before creating another.' using errcode='PT429';
    end if;
    insert into public.booking_safety_cases(id,reporter_id,category,issue_code,subject,description)
      values (_request,actor,_category,issue,btrim(_subject),btrim(_description))
      on conflict(id) do nothing returning * into item;
    if not found then raise exception 'This request key belongs to a different ticket.' using errcode='PT409'; end if;
    perform private.billing_notice(actor,'Ticket '||item.case_reference||' received','Support has received your ticket.','tickets',item.id);
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'case_reference',item.case_reference);
end;
$$;

create or replace function public.create_support_ticket(_category text,_subject text,_description text,_request uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select private.create_member_support_ticket(_category,null,_subject,_description,_request);
$$;

create function public.create_detailed_support_ticket(_category text,_issue text,_subject text,_description text,_request uuid)
returns jsonb language sql security definer set search_path = '' as $$
  select private.create_member_support_ticket(_category,_issue,_subject,_description,_request);
$$;

create or replace function public.my_support_tickets(_offset integer default 0) returns setof jsonb
language plpgsql stable security definer set search_path = '' as $$
declare actor uuid := private.billing_account();
begin
  perform private.assert_platform_available();
  return query select jsonb_build_object('id',c.id,'reference',c.reference,'category_reference',c.category_reference,
    'case_reference',c.case_reference,'reporter_kind',c.reporter_kind,'issue_code',c.issue_code,
    'subject',c.subject,'category',c.category,'status',c.status,'updated_at',c.updated_at)
  from public.booking_safety_cases c where c.reporter_id = actor or (c.dispute and exists(
    select 1 from public.bookings b where b.id = c.booking_id and b.tutor_id = actor
  )) order by c.updated_at desc,c.id limit 25 offset greatest(coalesce(_offset,0),0);
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
    'description',item.description,'status',item.status,'auto_resolved_at',item.auto_resolved_at,'thread',private.ticket_thread(item.id,actor));
end;
$$;

create or replace function public.report_booking_ticket(_booking uuid,_category text,_description text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := private.billing_account(); item public.booking_safety_cases%rowtype; ticket uuid;
begin
  ticket := public.report_booking_concern(_booking,_category,_description);
  select * into strict item from public.booking_safety_cases where id = ticket;
  if not exists(select 1 from public.notifications where user_id = actor and data->>'ticketId' = ticket::text
    and title in ('Ticket '||item.reference||' received','Ticket '||item.category_reference||' received','Ticket '||item.case_reference||' received')) then
    perform private.billing_notice(actor,'Ticket '||item.case_reference||' received','Support has received your booking concern.','tickets',ticket);
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'case_reference',item.case_reference);
end;
$$;

create or replace function private.billing_notice(_owner uuid,_title text,_body text,_tab text,_ticket uuid default null,_booking uuid default null) returns void
language plpgsql set search_path = '' as $$
declare item public.booking_safety_cases%rowtype;
begin
  if _ticket is not null then
    select * into item from public.booking_safety_cases where id = _ticket;
    if found then _title := replace(replace(_title,item.reference,item.case_reference),item.category_reference,item.case_reference); end if;
  end if;
  insert into public.notifications(user_id,kind,title,body,data)
  values (_owner,'system',_title,_body,jsonb_strip_nulls(jsonb_build_object('tab',_tab,'ticketId',_ticket,'bookingId',_booking)));
end;
$$;

create or replace function private.lesson_billing_summary(_booking uuid,_actor uuid) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'payment_state',coalesce((select state from private.lesson_funds where booking_id=_booking),
      (select status from public.payments where booking_id=_booking)),
    'outcome_submitted',exists(select 1 from private.lesson_outcomes where booking_id=_booking and participant=_actor),
    'ticket_reference',(select reference from public.booking_safety_cases where booking_id=_booking and dispute),
    'ticket_category_reference',(select category_reference from public.booking_safety_cases where booking_id=_booking and dispute),
    'ticket_case_reference',(select case_reference from public.booking_safety_cases where booking_id=_booking and dispute)
  );
$$;

create sequence private.enquiry_reference_seq;
alter table public.contact_enquiries
  add column reference_number bigint not null default nextval('private.enquiry_reference_seq'::regclass),
  add column case_reference text generated always as (
    private.support_reference(case category
      when 'general' then 'GEN' when 'tutoring' then 'TUT' when 'partnership' then 'PAR' when 'careers' then 'CAR'
      else private.ticket_category_code(category) end,
      'GST', 'ENQ', created_at, reference_number::text)
  ) stored unique;
create index support_enquiry_reference_prefix on public.contact_enquiries(case_reference text_pattern_ops);
create index support_enquiry_created_at on public.contact_enquiries(created_at desc, id);

create or replace function private.submit_contact_enquiry(_id uuid,_first_name text,_last_name text,_email text,_category text,_message text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare item public.contact_enquiries%rowtype;
begin
  if _id is null or _first_name is null or _last_name is null or _email is null or _category is null or _message is null then
    raise exception 'Complete the enquiry form.' using errcode='22023';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(lower(btrim(_email)),0));
  select * into item from public.contact_enquiries where id = _id;
  if found then
    if item.first_name=btrim(_first_name) and item.last_name=btrim(_last_name) and item.email=lower(btrim(_email))
      and item.category=_category and item.message=btrim(_message) then
      return jsonb_build_object('id',item.id,'case_reference',item.case_reference,'created',false);
    end if;
    raise exception 'Start a new enquiry before changing a submitted message.' using errcode='PT409';
  end if;
  if (select count(*) from public.contact_enquiries where email=lower(btrim(_email)) and created_at>now()-interval '15 minutes')>=5 then
    raise exception 'Too many enquiries. Please try again later.' using errcode='PT429';
  end if;
  insert into public.contact_enquiries(id,first_name,last_name,email,category,message)
    values (_id,btrim(_first_name),btrim(_last_name),lower(btrim(_email)),_category,btrim(_message))
    on conflict(id) do nothing returning * into item;
  if not found then raise exception 'Start a new enquiry before changing a submitted message.' using errcode='PT409'; end if;
  return jsonb_build_object('id',item.id,'case_reference',item.case_reference,'created',true);
end;
$$;

create or replace function private.enquiry_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
    select id,'enquiry','New website enquiry · '||new.case_reference,
      'A new '||new.category||' enquiry is ready in Safety & Quality.',
      jsonb_build_object('tab','enquiries','enquiryId',new.id)
    from public.profiles where role in ('admin','superUser') order by id;
  return null;
end;
$$;

create or replace function public.begin_enquiry_reply(_id uuid,_enquiry_id uuid,_message text,_expected_version integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare enquiry public.contact_enquiries%rowtype; reply public.enquiry_replies%rowtype;
begin
  if not (select private.is_platform_admin()) then raise exception 'Administrator access required.' using errcode='42501'; end if;
  if _id is null or coalesce(char_length(btrim(_message)),0) not between 10 and 4000 then
    raise exception 'Enter a valid reply.' using errcode='22023';
  end if;
  select * into enquiry from public.contact_enquiries where id=_enquiry_id for update;
  if not found then raise exception 'Enquiry not found.' using errcode='PT404'; end if;
  select * into reply from public.enquiry_replies where id=_id;
  if found then
    if reply.enquiry_id=_enquiry_id and reply.message=btrim(_message) then
      return jsonb_build_object('reply',to_jsonb(reply),'created',false);
    end if;
    raise exception 'This reply reference has already been used.' using errcode='PT409';
  end if;
  if enquiry.status='spam' then raise exception 'Change the status before replying to spam.' using errcode='PT409'; end if;
  select * into reply from public.enquiry_replies
    where enquiry_id=_enquiry_id and message=btrim(_message) and delivery_status in ('pending','unknown','sent')
    order by created_at desc,id limit 1;
  if found then return jsonb_build_object('reply',to_jsonb(reply),'created',false); end if;
  if enquiry.version is distinct from _expected_version then raise exception 'This enquiry changed. Reload it before replying.' using errcode='PT409'; end if;
  if (select count(*) from public.enquiry_replies where enquiry_id=_enquiry_id and created_at>now()-interval '1 hour')>=5 then
    raise exception 'Too many replies. Please try later.' using errcode='PT429';
  end if;
  insert into public.enquiry_replies(id,enquiry_id,admin_id,message) values(_id,_enquiry_id,(select auth.uid()),btrim(_message))
    returning * into reply;
  update public.contact_enquiries set status='in_progress' where id=_enquiry_id;
  return jsonb_build_object('reply',to_jsonb(reply),'created',true);
end;
$$;

revoke update on public.contact_enquiries from authenticated;
grant update(status,internal_notes) on public.contact_enquiries to authenticated;
revoke insert,update on public.enquiry_replies from authenticated;
grant update(delivery_status,provider_id) on public.enquiry_replies to authenticated;
alter policy "Admins update replies" on public.enquiry_replies
  using ((select private.is_platform_admin()) and admin_id = (select auth.uid()) and delivery_status = 'pending')
  with check ((select private.is_platform_admin()) and admin_id = (select auth.uid()) and delivery_status in ('sent','failed','unknown'));

revoke all on function private.support_reference(text,text,text,timestamptz,text), private.support_issue_code(text,text),
  private.set_support_case_origin(), private.create_member_support_ticket(text,text,text,text,uuid) from public,anon,authenticated;
-- Authenticated staff can update enquiry status and notes. Their stored reference expression uses these pure formatters.
grant execute on function private.support_reference(text,text,text,timestamptz,text), private.ticket_category_code(text) to authenticated;
revoke all on function public.create_detailed_support_ticket(text,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.create_detailed_support_ticket(text,text,text,text,uuid) to authenticated;
