begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('ba100000-0000-4000-8000-000000000001','triage.student@example.test','{}','{}'),
  ('ba100000-0000-4000-8000-000000000002','triage.other@example.test','{}','{}'),
  ('ba100000-0000-4000-8000-000000000003','triage.admin@example.test','{}','{}'),
  ('ba100000-0000-4000-8000-000000000004','triage.super@example.test','{}','{}');
update public.profiles set role = 'admin' where id = 'ba100000-0000-4000-8000-000000000003';
update public.profiles set role = 'superUser' where id = 'ba100000-0000-4000-8000-000000000004';

set local role authenticated;
do $$
declare
  owner text := 'ba100000-0000-4000-8000-000000000001';
  other_user text := 'ba100000-0000-4000-8000-000000000002';
  admin text := 'ba100000-0000-4000-8000-000000000003';
  super_user text := 'ba100000-0000-4000-8000-000000000004';
  member_report uuid := gen_random_uuid();
  invalid_report uuid := gen_random_uuid();
  guest_report uuid := gen_random_uuid();
  guest_reclass uuid := gen_random_uuid();
  png text := 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==';
  member_row jsonb;
  guest_row jsonb;
begin
  perform set_config('request.jwt.claim.sub',owner,true);
  perform public.submit_member_bug_report(member_report,'Calendar issue','Clicking the next day shows a blank page.','image/png',png);
  perform public.submit_member_bug_report(member_report,'Calendar issue','Clicking the next day shows a blank page.','image/png',png);
  begin
    perform public.submit_member_bug_report(invalid_report,'Broken button','Clicking the save button causes an error.','image/jpeg',png);
    raise exception 'A mismatched screenshot was accepted';
  exception when invalid_parameter_value then null; end;
  if public.my_support_ticket(member_report)->>'has_screenshot' <> 'true'
    or public.my_support_ticket(member_report)->>'response_due_at' is not null
    or public.support_bug_screenshot(member_report,false,false)->>'mime' <> 'image/png' then
    raise exception 'Member attachment or bug response target is incorrect';
  end if;

  perform set_config('request.jwt.claim.sub',other_user,true);
  begin
    perform public.support_bug_screenshot(member_report,false,false);
    raise exception 'An unrelated account accessed a screenshot';
  exception when sqlstate 'PT404' then null; end;
  perform set_config('request.jwt.claim.sub',admin,true);
  begin
    perform public.admin_support_ticket(invalid_report);
    raise exception 'The invalid screenshot left a partial ticket';
  exception when sqlstate 'PT404' then null; end;

  member_row := public.admin_support_ticket(member_report);
  perform public.triage_member_ticket(member_report,(member_row->>'version')::integer,'category','billing',null);
  member_row := public.admin_support_ticket(member_report);
  if member_row->>'case_reference' not like 'BIL-STU-%' or (member_row->>'response_due_at')::timestamptz <> now() + interval '48 hours' then
    raise exception 'Reclassification did not update the reference and target';
  end if;
  perform public.triage_member_ticket(member_report,(member_row->>'version')::integer,'category','bug',null);
  member_row := public.admin_support_ticket(member_report);
  perform public.triage_member_ticket(member_report,(member_row->>'version')::integer,'handoff',null,null);
  member_row := public.admin_support_ticket(member_report);
  if member_row->>'status' <> 'resolved' or member_row->>'developer_status' <> 'new' then
    raise exception 'Member handoff did not separate support and developer state';
  end if;
  begin
    perform public.triage_member_ticket(member_report,(member_row->>'version')::integer,'stage','resolved','Admin bypass');
    raise exception 'A regular admin changed a member developer stage';
  exception when insufficient_privilege then null; end;

  perform public.submit_guest_bug_report(guest_report,'Test','Guest','triage.guest@example.test','Search clears when choosing the date.','image/png',png);
  perform public.submit_guest_bug_report(guest_reclass,'Test','Other','triage.guest@example.test','A question about an available tutor.',null,null);
  guest_row := public.triage_guest_enquiry(guest_reclass,1,'category','tutoring',null);
  if guest_row->>'notice_id' is null or guest_row->>'notice' not like '%72 hours%' then
    raise exception 'Guest reclassification email was not recorded';
  end if;
  guest_row := public.triage_guest_enquiry(guest_report,1,'handoff',null,null);
  if guest_row->'enquiry'->>'status' <> 'resolved' or guest_row->'enquiry'->>'developer_status' <> 'new'
    or guest_row->>'notice_id' is null then raise exception 'Guest handoff was not recorded'; end if;
  begin
    update public.contact_enquiries set developer_status = 'resolved' where id = guest_report;
    raise exception 'Direct update bypassed developer access controls';
  exception when insufficient_privilege then null; end;
  begin
    perform public.triage_guest_enquiry(guest_report,(guest_row->'enquiry'->>'version')::integer,'stage','resolved',null);
    raise exception 'A regular admin changed a guest developer stage';
  exception when insufficient_privilege then null; end;
  perform public.begin_enquiry_reply(gen_random_uuid(),guest_report,'We received your screenshot and shared it with development.',
    (guest_row->'enquiry'->>'version')::integer);
  if (select status from public.contact_enquiries where id = guest_report) <> 'resolved' then
    raise exception 'A follow-up email reopened a handed-off guest report';
  end if;

  perform set_config('request.jwt.claim.sub',super_user,true);
  perform public.triage_member_ticket(member_report,(member_row->>'version')::integer,'stage','resolved','Verified the calendar fix');
  member_row := public.admin_support_ticket(member_report);
  guest_row := public.triage_guest_enquiry(guest_report,(guest_row->'enquiry'->>'version')::integer + 1,'stage','waiting','Awaiting reproduction');
  if member_row->>'developer_status' <> 'resolved' or member_row->>'status' <> 'resolved'
    or guest_row->'enquiry'->>'developer_status' <> 'waiting'
    or public.support_bug_screenshot(guest_report,true,false)->>'mime' <> 'image/png' then
    raise exception 'Superuser transitions or screenshot access failed';
  end if;

  perform set_config('request.jwt.claim.sub',owner,true);
  if public.my_support_ticket(member_report)->>'status' <> 'resolved'
    or public.my_support_ticket(member_report)->>'bug_handed_off' <> 'true'
    or public.my_support_ticket(member_report) ? 'developer_notes' then
    raise exception 'Reporter view did not preserve support closure and private developer notes';
  end if;
  perform set_config('test.triage_member',member_report::text,true);
  perform set_config('test.triage_guest',guest_report::text,true);
end;
$$;
reset role;

do $$
begin
  if not exists (select 1 from public.notifications where data->>'ticketId' = current_setting('test.triage_member')
    and body like '%48 hours%' and user_id = 'ba100000-0000-4000-8000-000000000001')
    or not exists (select 1 from public.notifications where data->>'enquiryId' = current_setting('test.triage_guest')
      and data->>'tab' = 'bugs' and user_id = 'ba100000-0000-4000-8000-000000000004') then
    raise exception 'A routing or response-time notification was missing';
  end if;
end;
$$;

do $$
declare
  entry uuid;
  bytes bytea := convert_to(repeat('x', 2097152),'UTF8');
begin
  for i in 1..24 loop
    entry := gen_random_uuid();
    insert into public.contact_enquiries(id,first_name,last_name,email,category,message)
      values (entry,'Test','Quota','triage.quota@example.test','bug','Checking the attachment upload quota.');
    if i < 24 then
      insert into private.bug_report_screenshots(enquiry_id,mime_type,image) values (entry,'image/png',bytes);
    else
      begin
        insert into private.bug_report_screenshots(enquiry_id,mime_type,image) values (entry,'image/png',bytes);
        raise exception 'The shared guest screenshot quota did not apply';
      exception when sqlstate 'PT429' then null; end;
    end if;
  end loop;
end;
$$;

rollback;
