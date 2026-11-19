-- Support is available to every account independently of billing entitlements.
create function private.support_account() returns uuid language plpgsql stable set search_path='' as $$
declare actor uuid:=(select auth.uid());
begin
 if actor is null or not exists(select 1 from public.profiles where id=actor and role in ('student','tutor','admin','superUser')) then
  raise exception 'Sign in with your AeroGen account to contact support.' using errcode='42501';
 end if;
 return actor;
end;$$;
revoke all on function private.support_account() from public,anon,authenticated;

CREATE OR REPLACE FUNCTION private.create_member_support_ticket(_category text, _issue text, _subject text, _description text, _request uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
    actor := private.support_account();
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
$function$
;

CREATE OR REPLACE FUNCTION public.my_support_ticket(_ticket uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := private.support_account(); item public.booking_safety_cases%rowtype;
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
$function$
;

CREATE OR REPLACE FUNCTION public.my_support_tickets(_offset integer DEFAULT 0)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := private.support_account();
begin
  perform private.assert_platform_available();
  return query select jsonb_build_object('id',c.id,'reference',c.reference,'category_reference',c.category_reference,
    'case_reference',c.case_reference,'reporter_kind',c.reporter_kind,'issue_code',c.issue_code,
    'subject',c.subject,'category',c.category,'status',c.status,'updated_at',c.updated_at)
  from public.booking_safety_cases c where c.reporter_id = actor or (c.dispute and exists(
    select 1 from public.bookings b where b.id = c.booking_id and b.tutor_id = actor
  )) order by c.updated_at desc,c.id limit 25 offset greatest(coalesce(_offset,0),0);
end;
$function$
;

CREATE OR REPLACE FUNCTION public.rate_support_reply(_ticket uuid, _reply uuid, _score integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := private.support_account(); staff uuid;
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
$function$
;

CREATE OR REPLACE FUNCTION public.reply_support_ticket(_ticket uuid, _body text, _request uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := private.support_account(); item public.booking_safety_cases%rowtype; inserted uuid;
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
$function$
;

CREATE OR REPLACE FUNCTION public.resolve_support_ticket(_ticket uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare actor uuid := private.support_account(); item public.booking_safety_cases%rowtype;
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
$function$
;

notify pgrst,'reload schema';
