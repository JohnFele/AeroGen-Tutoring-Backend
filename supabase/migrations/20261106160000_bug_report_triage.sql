create function private.support_response_hours(category text) returns integer
language sql immutable set search_path = '' as $$
  select case
    when category = 'bug' then null
    when category = 'safety' then 4
    when category in ('conduct','lesson_dispute') then 24
    when category in ('billing','account','lesson_quality','technical') then 48
    when category in ('partnership','careers') then 120
    else 72
  end;
$$;

alter table public.booking_safety_cases
  alter column response_due_at drop not null,
  drop constraint support_reporter_kind_check,
  add constraint support_reporter_kind_check check (reporter_kind in ('student','tutor','admin','unknown')),
  add column developer_status text check (developer_status in ('new','investigating','waiting','resolved')),
  add column developer_notes text check (char_length(developer_notes) <= 2000),
  add constraint member_developer_handoff check (developer_status is null or (category = 'bug' and status = 'resolved' and not dispute));
alter table public.contact_enquiries
  add column response_due_at timestamptz,
  add column developer_status text check (developer_status in ('new','investigating','waiting','resolved')),
  add column developer_notes text check (char_length(developer_notes) <= 2000),
  add constraint guest_developer_handoff check (developer_status is null or (category = 'bug' and status = 'resolved'));

grant select(developer_status) on public.booking_safety_cases to authenticated;
revoke update on public.contact_enquiries from authenticated;
grant update(status,internal_notes) on public.contact_enquiries to authenticated;

update public.booking_safety_cases set response_due_at = response_due_at - interval '24 hours'
  + make_interval(hours => private.support_response_hours(category))
where category = 'bug' or status <> 'resolved';
update public.contact_enquiries set response_due_at = created_at + make_interval(hours => private.support_response_hours(category));

create index member_developer_board on public.booking_safety_cases(developer_status, updated_at desc, id)
  where developer_status is not null;
create index guest_developer_board on public.contact_enquiries(developer_status, created_at desc, id)
  where developer_status is not null;

create function private.set_support_response_due() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.response_due_at := new.created_at + make_interval(hours => private.support_response_hours(new.category));
  elsif new.category is distinct from old.category then
    new.response_due_at := now() + make_interval(hours => private.support_response_hours(new.category));
  elsif new.category = 'bug' then
    new.response_due_at := null;
  elsif new.response_due_at is distinct from old.response_due_at then
    new.response_due_at := now() + make_interval(hours => private.support_response_hours(new.category));
  end if;
  return new;
end;
$$;
create trigger member_support_response_due before insert or update on public.booking_safety_cases
for each row execute function private.set_support_response_due();
create trigger guest_support_response_due before insert or update on public.contact_enquiries
for each row execute function private.set_support_response_due();

create table private.bug_report_screenshots (
  id bigint generated always as identity primary key,
  ticket_id uuid unique references public.booking_safety_cases(id) on delete cascade,
  enquiry_id uuid unique references public.contact_enquiries(id) on delete cascade,
  mime_type text not null check (mime_type in ('image/png','image/jpeg','image/webp')),
  image bytea not null check (octet_length(image) between 1 and 2097152),
  check (num_nonnulls(ticket_id, enquiry_id) = 1)
);
alter table private.bug_report_screenshots enable row level security;
revoke all on private.bug_report_screenshots from public, anon, authenticated;

create function private.save_bug_screenshot(_ticket uuid,_enquiry uuid,_mime text,_base64 text)
returns void language plpgsql set search_path = '' as $$
declare bytes bytea;
begin
  if _mime is null and _base64 is null then return; end if;
  if _mime is null or _mime not in ('image/png','image/jpeg','image/webp')
    or coalesce(length(_base64),0) not between 4 and 2796204
    or _base64 !~ '^[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'Choose a PNG, JPEG or WebP screenshot up to 2 MB.' using errcode = '22023';
  end if;
  bytes := decode(_base64,'base64');
  if octet_length(bytes) not between 12 and 2097152 or not (case _mime
    when 'image/png' then substring(bytes from 1 for 8) = decode('89504e470d0a1a0a','hex')
    when 'image/jpeg' then substring(bytes from 1 for 3) = decode('ffd8ff','hex')
    when 'image/webp' then substring(bytes from 1 for 4) = convert_to('RIFF','UTF8')
      and substring(bytes from 9 for 4) = convert_to('WEBP','UTF8')
    else false end) then
    raise exception 'The screenshot is not a supported image.' using errcode = '22023';
  end if;
  insert into private.bug_report_screenshots(ticket_id,enquiry_id,mime_type,image)
    values (_ticket,_enquiry,_mime,bytes) on conflict do nothing;
  if not found and not exists (select 1 from private.bug_report_screenshots s
      where (s.ticket_id = _ticket or s.enquiry_id = _enquiry) and s.mime_type = _mime and s.image = bytes) then
    raise exception 'A different screenshot is already attached to this report.' using errcode = 'PT409';
  end if;
end;
$$;

create function public.submit_member_bug_report(_id uuid,_subject text,_description text,_mime text,_base64 text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare receipt jsonb;
begin
  receipt := private.create_member_support_ticket('bug','bug',_subject,_description,_id);
  perform private.save_bug_screenshot(_id,null,_mime,_base64);
  return receipt;
end;
$$;

create function public.submit_guest_bug_report(_id uuid,_first_name text,_last_name text,_email text,_message text,_mime text,_base64 text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare receipt jsonb;
begin
  receipt := private.submit_contact_enquiry(_id,_first_name,_last_name,_email,'bug',_message);
  perform private.save_bug_screenshot(null,_id,_mime,_base64);
  return receipt;
end;
$$;

create function public.support_bug_screenshot(_id uuid,_guest boolean,_metadata boolean)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare shot private.bug_report_screenshots%rowtype;
begin
  if not private.is_platform_admin() and (_guest or not exists (
    select 1 from public.booking_safety_cases where id = _id and reporter_id = (select auth.uid())
  )) then
    raise exception 'Screenshot not found.' using errcode = 'PT404';
  end if;
  if _guest then
    select * into shot from private.bug_report_screenshots where enquiry_id = _id;
  else
    select * into shot from private.bug_report_screenshots where ticket_id = _id;
  end if;
  if shot.id is null then return null; end if;
  return jsonb_build_object('mime',shot.mime_type,'base64',case when not _metadata then encode(shot.image,'base64') end);
end;
$$;

revoke all on function private.support_response_hours(text), private.set_support_response_due(),
  private.save_bug_screenshot(uuid,uuid,text,text) from public, anon, authenticated;
grant execute on function private.support_response_hours(text) to authenticated;

revoke all on function public.submit_member_bug_report(uuid,text,text,text,text),
  public.submit_guest_bug_report(uuid,text,text,text,text,text,text),
  public.support_bug_screenshot(uuid,boolean,boolean) from public, anon, authenticated;
grant execute on function public.submit_member_bug_report(uuid,text,text,text,text),
  public.support_bug_screenshot(uuid,boolean,boolean) to authenticated;
grant execute on function public.submit_guest_bug_report(uuid,text,text,text,text,text,text) to anon, authenticated;

create function private.support_category_message(_category text,_reference text) returns text
language sql stable set search_path = '' as $$
  select format('Your report was moved to %s. Its updated reference is %s. %s',
    replace(_category,'_',' '),_reference,
    case when _category = 'bug' then 'Bug investigation has no fixed response time.'
    else format('The response target for this category is %s hours from the category change.',
      private.support_response_hours(_category)) end);
$$;

create function private.require_support_triage(_action text,_developer_status text) returns void
language plpgsql stable set search_path = '' as $$
begin
  if not private.is_platform_admin() then
    raise exception 'Administrator access required.' using errcode = '42501';
  end if;
  if _action = 'stage' then
    if not exists (select 1 from public.profiles where id = (select auth.uid()) and role = 'superUser') then
      raise exception 'Only superusers can move developer reports.' using errcode = '42501';
    end if;
    if _developer_status is null then
      raise exception 'Send this bug to the development team first.' using errcode = 'PT409';
    end if;
  elsif _developer_status is not null then
    raise exception 'This report has already been handed off to the development team.' using errcode = 'PT409';
  end if;
end;
$$;

create function public.triage_member_ticket(_ticket uuid,_version integer,_action text,_value text,_notes text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  item public.booking_safety_cases%rowtype;
  updated public.booking_safety_cases%rowtype;
  notice text;
begin
  if not private.is_platform_admin() then
    raise exception 'Administrator access required.' using errcode = '42501';
  end if;
  select * into item from public.booking_safety_cases where id = _ticket for update;
  if not found then raise exception 'Ticket not found.' using errcode = 'PT404'; end if;
  perform private.require_support_triage(_action,item.developer_status);
  if item.version is distinct from _version then
    raise exception 'The ticket changed. Refresh before retrying.' using errcode = 'PT409';
  end if;

  if _action = 'category' and _value in ('safety','conduct','lesson_quality','other','billing','account','technical','lesson_dispute','bug')
    and _value <> item.category and not item.dispute then
    update public.booking_safety_cases set category = _value,
      issue_code = case _value when 'bug' then 'BUG' when 'safety' then 'INC' when 'conduct' then 'BEH'
        when 'lesson_quality' then 'QLT' when 'lesson_dispute' then 'CMP' else 'GEN' end,
      version = version + 1, updated_at = now()
    where id = _ticket returning * into updated;
    notice := private.support_category_message(updated.category,updated.case_reference);
  elsif _action = 'handoff' and item.category = 'bug' and not item.dispute then
    update public.booking_safety_cases set status = 'resolved', developer_status = 'new',
      assigned_to = coalesce(assigned_to,actor),
      outcome = coalesce(nullif(outcome,''), 'Support closed this ticket after forwarding the report to the development team.'),
      version = version + 1, updated_at = now()
    where id = _ticket returning * into updated;
    notice := 'Support has closed this ticket and sent your report to the development team. Bug investigation has no fixed response time.';
    insert into public.notifications(user_id,kind,title,body,data)
      select id,'system','Bug sent to development · ' || updated.case_reference,
        'A new report is ready in the developer queue.',
        jsonb_build_object('tab','bugs','ticketId',_ticket)
      from public.profiles where role = 'superUser' order by id;
  elsif _action = 'stage' and _value in ('new','investigating','waiting','resolved')
    and char_length(coalesce(_notes,'')) <= 2000 then
    update public.booking_safety_cases set developer_status = _value, developer_notes = btrim(coalesce(_notes,'')),
      version = version + 1, updated_at = now() where id = _ticket;
  else
    raise exception 'Choose a valid category or action. Lesson disputes with held funds must follow their settlement workflow.' using errcode = '22023';
  end if;

  if notice is not null then
    perform private.billing_notice(item.reporter_id,
      'Update to ' || item.case_reference,notice,
      case when item.reporter_kind = 'admin' then 'safety' else 'tickets' end,_ticket);
  end if;
end;
$$;

create function public.triage_guest_enquiry(_enquiry uuid,_version integer,_action text,_value text,_notes text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := (select auth.uid());
  item public.contact_enquiries%rowtype;
  updated public.contact_enquiries%rowtype;
  notice text;
  notice_id uuid;
begin
  if not private.is_platform_admin() then
    raise exception 'Administrator access required.' using errcode = '42501';
  end if;
  select * into item from public.contact_enquiries where id = _enquiry for update;
  if not found then raise exception 'Enquiry not found.' using errcode = 'PT404'; end if;
  perform private.require_support_triage(_action,item.developer_status);
  if item.version is distinct from _version then
    raise exception 'This enquiry changed. Reload before saving.' using errcode = 'PT409';
  end if;

  if _action = 'category' and _value in ('general','tutoring','billing','technical','partnership','careers','other','bug')
    and _value <> item.category then
    update public.contact_enquiries set category = _value where id = _enquiry returning * into updated;
    notice := private.support_category_message(updated.category,updated.case_reference);
  elsif _action = 'handoff' and item.category = 'bug' and item.status <> 'spam' then
    update public.contact_enquiries set status = 'resolved', developer_status = 'new'
      where id = _enquiry returning * into updated;
    notice := 'Support has closed your report and sent it to the development team. Bug investigation has no fixed response time.';
    insert into public.notifications(user_id,kind,title,body,data)
      select id,'enquiry','Bug sent to development · ' || updated.case_reference,
        'A new guest report is ready in the developer queue.',
        jsonb_build_object('tab','bugs','enquiryId',_enquiry)
      from public.profiles where role = 'superUser' order by id;
  elsif _action = 'stage' and _value in ('new','investigating','waiting','resolved')
    and char_length(coalesce(_notes,'')) <= 2000 then
    update public.contact_enquiries set developer_status = _value, developer_notes = btrim(coalesce(_notes,''))
      where id = _enquiry returning * into updated;
  else
    raise exception 'Choose a valid category or action.' using errcode = '22023';
  end if;
  if notice is not null and item.status <> 'spam' then
    insert into public.enquiry_replies(id,enquiry_id,admin_id,message)
      values (gen_random_uuid(),_enquiry,actor,notice) returning id into notice_id;
  end if;
  return jsonb_build_object('enquiry',to_jsonb(updated),'notice_id',notice_id,'notice',notice);
end;
$$;

create or replace function private.mark_first_support_reply() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.from_support and not exists (
    select 1 from private.ticket_replies where ticket_id = new.ticket_id and from_support
  ) then
    select new.created_at <= c.response_due_at into new.first_response_on_time
    from public.booking_safety_cases c where c.id = new.ticket_id;
  end if;
  return new;
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
    'response_due_at',item.response_due_at,'bug_handed_off',item.developer_status is not null,
    'has_screenshot',exists(select 1 from private.bug_report_screenshots where ticket_id = _ticket and item.reporter_id = actor),
    'can_resolve',private.participant_can_resolve(item.reporter_id,actor,item.status,item.category,item.dispute),
    'auto_resolved_at',item.auto_resolved_at,'thread',private.ticket_thread(item.id,actor));
end;
$$;

create or replace function public.admin_support_ticket(_ticket uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare result jsonb; item public.booking_safety_cases%rowtype;
begin
  result := public.open_booking_safety_case(_ticket);
  select * into strict item from public.booking_safety_cases where id = _ticket;
  return result || jsonb_build_object('thread',private.ticket_thread(item.id,auth.uid()),
    'has_screenshot',exists(select 1 from private.bug_report_screenshots where ticket_id = _ticket),
    'lesson_outcomes',case when item.dispute and item.status <> 'resolved' then (
      select coalesce(jsonb_agg(jsonb_build_object('role',case when o.participant=b.student_id then 'Student' else 'Tutor' end,
        'happened',o.happened,'reason',o.reason)),'[]'::jsonb)
      from private.lesson_outcomes o join public.bookings b on b.id=o.booking_id where o.booking_id=item.booking_id
    ) else '[]'::jsonb end);
end;
$$;

revoke all on function private.support_category_message(text,text), private.require_support_triage(text,text)
  from public, anon, authenticated;
revoke all on function public.triage_member_ticket(uuid,integer,text,text,text),
  public.triage_guest_enquiry(uuid,integer,text,text,text) from public, anon, authenticated;
grant execute on function public.triage_member_ticket(uuid,integer,text,text,text),
  public.triage_guest_enquiry(uuid,integer,text,text,text) to authenticated;
