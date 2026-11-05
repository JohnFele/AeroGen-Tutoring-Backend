begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('bd000000-0000-4000-8000-000000000001','support.student@example.test','{}','{}'),
  ('bd000000-0000-4000-8000-000000000002','support.admin@example.test','{}','{}'),
  ('bd000000-0000-4000-8000-000000000003','support.other@example.test','{}','{}');
update public.profiles set role = 'admin' where id = 'bd000000-0000-4000-8000-000000000002';

set local role authenticated;
select set_config('request.jwt.claim.sub','bd000000-0000-4000-8000-000000000001',true);
do $$
declare ticket jsonb;
begin
  ticket := public.create_support_ticket('billing','Package question','Please clarify when my subscription is renewed.',gen_random_uuid());
  if ticket->>'category_reference' not like 'BIL-%' or ticket->>'reference' not like 'AG-%' then
    raise exception 'The billing code or legacy alias is incorrect';
  end if;
  perform set_config('test.support_ticket',ticket->>'id',true);
  begin
    perform public.admin_support_check_in();
    raise exception 'A student could use the admin check-in';
  exception when insufficient_privilege then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','bd000000-0000-4000-8000-000000000002',true);
do $$
declare
  ticket uuid := current_setting('test.support_ticket')::uuid;
  reminder jsonb;
begin
  perform public.update_support_ticket(ticket,1,'investigating','','',null);
  reminder := public.admin_support_check_in();
  if (reminder->>'assigned')::int is distinct from 1 or reminder->>'created' is distinct from 'true'
    or public.admin_support_check_in()->>'created' is distinct from 'false' then
    raise exception 'Daily check-in did not count the assigned ticket or deduplicate';
  end if;
  perform public.update_support_ticket(ticket,2,'investigating','Your cycle renews every 30 days.','',null);
  perform public.update_support_ticket(ticket,3,'investigating','The pricing page shows the exact date.','',null);
  perform public.update_support_ticket(ticket,4,'waiting','Does that answer your question?','',null);
  if public.my_admin_support_progress()->>'on_time' is distinct from '1' then
    raise exception 'The first response was not measured exactly once';
  end if;
  if not (public.my_admin_support_progress()->'milestones' ? 'first_reply') then
    raise exception 'The first reply milestone was not awarded immediately';
  end if;
  perform set_config('test.support_reply', public.admin_support_ticket(ticket)->'thread'->0->>'id', true);
end;
$$;

select set_config('request.jwt.claim.sub','bd000000-0000-4000-8000-000000000003',true);
do $$
begin
  perform public.rate_support_reply(current_setting('test.support_ticket')::uuid,current_setting('test.support_reply')::uuid,5);
  raise exception 'A stranger could rate the reply';
exception when sqlstate 'PT404' then null;
end;
$$;

select set_config('request.jwt.claim.sub','bd000000-0000-4000-8000-000000000001',true);
do $$
declare
  ticket uuid := current_setting('test.support_ticket')::uuid;
  thread jsonb;
  reply jsonb;
begin
  thread := public.my_support_ticket(ticket)->'thread';
  for reply in select value from jsonb_array_elements(thread) loop
    perform public.rate_support_reply(ticket,(reply->>'id')::uuid,5);
    perform public.rate_support_reply(ticket,(reply->>'id')::uuid,5);
  end loop;
  if public.my_support_ticket(ticket)->'thread'->0->>'rating' is distinct from '5' then
    raise exception 'The participant cannot see their saved rating';
  end if;
  begin
    perform public.rate_support_reply(ticket,current_setting('test.support_reply')::uuid,1);
    raise exception 'A participant could overwrite a submitted rating';
  exception when sqlstate 'PT409' then null; end;
  perform public.reply_support_ticket(ticket,'Yes, thanks for the details.',gen_random_uuid());
  if public.my_support_ticket(ticket)->>'status' is distinct from 'investigating' then
    raise exception 'A participant reply did not resume staff review';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','bd000000-0000-4000-8000-000000000002',true);
do $$
declare stats jsonb := public.my_admin_support_progress();
begin
  if stats->>'ratings' is distinct from '3' or (stats->>'rating')::numeric is distinct from 5 then
    raise exception 'Admin rating is incorrect or retry counted twice';
  end if;
end;
$$;
reset role;

do $$
declare
  staff constant uuid := 'bd000000-0000-4000-8000-000000000002';
  participant constant uuid := 'bd000000-0000-4000-8000-000000000001';
  expired uuid := gen_random_uuid();
  recent uuid := gen_random_uuid();
  waiting_on_staff uuid := gen_random_uuid();
  safety uuid := gen_random_uuid();
  disputed_ticket uuid := gen_random_uuid();
begin
  if (select count(*) from public.notifications where user_id=staff and title='Your support check-in' and data->>'scope'='mine') <> 1
    or (select count(*) from public.notifications where user_id=staff and title like 'Assigned to you · BIL-%') <> 1
    or (select count(*) from public.notifications where user_id=staff and title like 'New reply · BIL-%') <> 1
    or (select count(*) from public.notifications where user_id=staff and title='Milestone earned · First support reply') <> 1 then
    raise exception 'The admin did not receive each expected notification exactly once';
  end if;
  insert into public.booking_safety_cases(id,reporter_id,category,description,status,assigned_to,updated_at,dispute) values
    (expired,participant,'technical','Waiting for the participant to share details.','waiting',staff,now()-interval '31 days',false),
    (recent,participant,'account','Waiting for the participant to share details.','waiting',staff,now()-interval '30 days',false),
    (waiting_on_staff,participant,'other','Waiting for the administrator to respond.','investigating',staff,now()-interval '45 days',false),
    (safety,participant,'safety','Sensitive report still awaiting review.','waiting',staff,now()-interval '45 days',false),
    (disputed_ticket,participant,'lesson_dispute','Financial settlement still awaiting review.','waiting',staff,now()-interval '45 days',true);

  if private.resolve_inactive_support_tickets() <> 1 or private.resolve_inactive_support_tickets() <> 0 then
    raise exception 'The inactivity worker must resolve the eligible ticket once';
  end if;
  if not exists(select 1 from public.booking_safety_cases where id=expired and status='resolved' and auto_resolved_at is not null and category_reference like 'TEC-%')
    or exists(select 1 from public.booking_safety_cases where id in (recent,waiting_on_staff,safety,disputed_ticket) and status='resolved')
    or (private.admin_support_stats(staff)->>'resolved')::int <> 0 then
    raise exception 'Inactivity resolution or its staff attribution is incorrect';
  end if;
  if not exists(select 1 from public.notifications where user_id=participant and data->>'ticketId'=expired::text and title like 'Ticket TEC-% closed') then
    raise exception 'The requester was not notified of automatic resolution';
  end if;
end;
$$;

rollback;
