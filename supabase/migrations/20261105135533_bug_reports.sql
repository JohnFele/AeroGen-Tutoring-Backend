create or replace function private.ticket_category_code(category text) returns text
language sql immutable set search_path = '' as $$
  select case category
    when 'billing' then 'BIL' when 'account' then 'ACC' when 'technical' then 'TEC'
    when 'safety' then 'SAF' when 'conduct' then 'CON' when 'lesson_quality' then 'QLT'
    when 'lesson_dispute' then 'DSP' when 'bug' then 'BUG' else 'OTH'
  end;
$$;

alter table public.booking_safety_cases
  drop constraint booking_safety_cases_category_check,
  drop constraint support_reporter_kind_check,
  add constraint booking_safety_cases_category_check
    check (category in ('safety','conduct','lesson_quality','other','billing','account','technical','lesson_dispute','bug')),
  add constraint support_reporter_kind_check
    check (reporter_kind in ('student','tutor','unknown') or (reporter_kind = 'admin' and category = 'bug')),
  alter column case_reference set expression as (
    private.support_reference(private.ticket_category_code(category),
      case reporter_kind when 'student' then 'STU' when 'tutor' then 'TUT' when 'admin' then 'ADM' else 'UNK' end,
      issue_code, created_at, split_part(reference, '-', 2))
  );

alter table public.contact_enquiries
  drop constraint contact_enquiries_category_check,
  add constraint contact_enquiries_category_check
    check (category in ('general','tutoring','billing','technical','partnership','careers','other','bug'));

create or replace function private.set_support_case_origin() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.reporter_kind := case
    when exists(select 1 from public.bookings b where b.id = new.booking_id and b.student_id = new.reporter_id) then 'student'
    when exists(select 1 from public.bookings b where b.id = new.booking_id and b.tutor_id = new.reporter_id) then 'tutor'
    else coalesce((select case when p.role in ('student','tutor') then p.role
      when new.category = 'bug' and p.role in ('admin','superUser') then 'admin' end
      from public.profiles p where p.id = new.reporter_id), 'unknown')
  end;
  new.issue_code := coalesce(new.issue_code, case
    when new.category = 'bug' then 'BUG'
    when new.category = 'other' and new.booking_id is not null then 'BKG'
    else private.support_issue_code(new.category, null) end);
  return new;
end;
$$;

create or replace function private.create_member_support_ticket(_category text,_issue text,_subject text,_description text,_request uuid)
returns jsonb language plpgsql set search_path = '' as $$
declare
  actor uuid;
  issue text;
  item public.booking_safety_cases%rowtype;
begin
  if _category = 'bug' then
    actor := (select auth.uid());
    if actor is null or not exists (
      select 1 from public.profiles where id = actor and role in ('student','tutor','admin','superUser')
    ) then raise exception 'Sign in with your AeroGen account to use this reporting form.' using errcode = '42501'; end if;
    if coalesce(_issue, 'bug') = 'bug' then issue := 'BUG'; end if;
  else
    actor := private.billing_account();
    issue := case when _issue is null then 'GEN' else private.support_issue_code(_category, _issue) end;
  end if;

  perform private.assert_platform_available();
  if _request is null or _category is null or _category not in ('billing','account','technical','other','bug') or issue is null
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
    if _category <> 'bug' then
      perform private.billing_notice(actor,'Ticket '||item.case_reference||' received','Support has received your ticket.','tickets',item.id);
    end if;
  end if;
  return jsonb_build_object('id',item.id,'reference',item.reference,'category_reference',item.category_reference,'case_reference',item.case_reference);
end;
$$;

create function private.notify_new_bug_report() returns trigger
language plpgsql set search_path = '' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
    select id,'system',
      case when id = new.reporter_id then 'Bug report received · ' else 'New bug report · ' end || new.case_reference,
      case when id = new.reporter_id then 'Support has received your bug report.'
        else 'A bug report is ready for triage in Safety & Quality.' end,
      jsonb_build_object('tab',case when role in ('admin','superUser') then 'safety' else 'tickets' end,'ticketId',new.id)
    from public.profiles where id = new.reporter_id or role in ('admin','superUser') order by id;
  return null;
end;
$$;

create trigger support_bug_notification after insert on public.booking_safety_cases
for each row when (new.category = 'bug') execute function private.notify_new_bug_report();
revoke all on function private.notify_new_bug_report() from public,anon,authenticated;

create or replace function private.enquiry_notification() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications(user_id,kind,title,body,data)
    select id,'enquiry',
      case when new.category = 'bug' then 'New bug report · ' else 'New website enquiry · ' end || new.case_reference,
      case when new.category = 'bug' then 'A visitor reported a bug in Safety & Quality.'
        else 'A new '||new.category||' enquiry is ready in Safety & Quality.' end,
      jsonb_build_object('tab','enquiries','enquiryId',new.id)
    from public.profiles where role in ('admin','superUser') order by id;
  return null;
end;
$$;
