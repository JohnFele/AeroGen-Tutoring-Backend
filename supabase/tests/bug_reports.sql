begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('bf000000-0000-4000-8000-000000000001','bugs.student@example.test','{}','{}'),
  ('bf000000-0000-4000-8000-000000000002','bugs.tutor@example.test','{}','{}'),
  ('bf000000-0000-4000-8000-000000000003','bugs.admin@example.test','{}','{}'),
  ('bf000000-0000-4000-8000-000000000004','bugs.superuser@example.test','{}','{}');
update public.profiles set role = 'tutor' where id = 'bf000000-0000-4000-8000-000000000002';
update public.profiles set role = 'admin' where id = 'bf000000-0000-4000-8000-000000000003';
update public.profiles set role = 'superUser' where id = 'bf000000-0000-4000-8000-000000000004';

set local role authenticated;
do $$
declare
  reporter record;
  request uuid;
  submitted jsonb;
begin
  for reporter in select * from (values
    ('bf000000-0000-4000-8000-000000000001','STU'),
    ('bf000000-0000-4000-8000-000000000002','TUT'),
    ('bf000000-0000-4000-8000-000000000003','ADM'),
    ('bf000000-0000-4000-8000-000000000004','ADM')
  ) v(profile_id, code) loop
    perform set_config('request.jwt.claim.sub',reporter.profile_id,true);
    request := gen_random_uuid();
    submitted := public.create_detailed_support_ticket('bug','bug','Page fails to load','The page displays an error after clicking save.',request);
    if submitted->>'case_reference' not like ('BUG-'||reporter.code||'-BUG-%')
      or submitted is distinct from public.create_detailed_support_ticket('bug','bug','Page fails to load','The page displays an error after clicking save.',request) then
      raise exception 'Bug intake gave the wrong role code or duplicated the request';
    end if;
    if reporter.code = 'ADM' then
      if public.admin_support_ticket(request)->>'reporter_kind' is distinct from 'admin' then
        raise exception 'The report was missing from the admin queue';
      end if;
      begin
        perform public.create_detailed_support_ticket('billing','payment','Payment question','I have a question about a member payment.',gen_random_uuid());
        raise exception 'Bug intake expanded admin access to member-only ticket creation';
      exception when insufficient_privilege then null; end;
    elsif public.my_support_ticket(request)->>'category' is distinct from 'bug' then
      raise exception 'A member could not reopen their bug report';
    end if;
  end loop;
end;
$$;
reset role;

set local role anon;
do $$
declare request uuid := gen_random_uuid(); report jsonb;
begin
  report := public.submit_contact_enquiry(request,'Test','Visitor','bug-visitor@example.test','bug',
    'Summary: Button fails on mobile. Clicking it shows an error.');
  if report->>'case_reference' not like 'BUG-GST-ENQ-%' then raise exception 'Visitor report did not get a bug reference'; end if;
  perform set_config('test.visitor_bug',request::text,true);
  begin
    perform public.create_detailed_support_ticket('bug','bug','Page fails','An anonymous caller tried member intake.',gen_random_uuid());
    raise exception 'Anonymous caller could use authenticated bug intake';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;

do $$
begin
  if (select count(*) from public.notifications
      where user_id in ('bf000000-0000-4000-8000-000000000001','bf000000-0000-4000-8000-000000000002','bf000000-0000-4000-8000-000000000003','bf000000-0000-4000-8000-000000000004')
      and title like 'Bug report received · BUG-%') <> 4 then
    raise exception 'A reporter did not receive exactly one confirmation';
  end if;
  if not exists(select 1 from public.notifications where title like 'New bug report · BUG-GST-%'
      and data->>'enquiryId' = current_setting('test.visitor_bug'))
    or not exists(select 1 from public.notifications where title like 'New bug report · BUG-ADM-%'
      and data->>'tab' = 'safety' and data ? 'ticketId') then
    raise exception 'An admin bug notification was missing its queue link';
  end if;
end;
$$;

rollback;
