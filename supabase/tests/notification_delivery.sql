begin;
-- Successful staff workflows model a verified MFA session; denial cases are in staff_mfa.sql.
select set_config('request.jwt.claims',jsonb_build_object('aal','aal2','amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from now())::bigint)))::text,true);

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('c1800000-0000-4000-8000-000000000001','delivery.student@example.test','{}','{}'),
  ('c1800000-0000-4000-8000-000000000002','delivery.tutor@example.test','{}','{}'),
  ('c1800000-0000-4000-8000-000000000003','delivery.staff@example.test','{}','{}');
update public.profiles set role='tutor' where id='c1800000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id='c1800000-0000-4000-8000-000000000003';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
values ('c1800000-0000-4000-8000-000000000002','Delivery Tutor',true,200,array['online']);

select set_config('request.jwt.claim.sub','c1800000-0000-4000-8000-000000000002',true);
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount,proposed_by)
values ('c1810000-0000-4000-8000-000000000001',
  'c1800000-0000-4000-8000-000000000001','c1800000-0000-4000-8000-000000000002',
  now()+interval '1 day',now()+interval '25 hours','pending','online',60,200,200,
  'c1800000-0000-4000-8000-000000000002');
do $$
begin
  if (select count(*) from public.notifications where data->>'bookingId'='c1810000-0000-4000-8000-000000000001') <> 1
    or not exists(select 1 from public.notifications where user_id='c1800000-0000-4000-8000-000000000001'
      and title='Your tutor proposed a lesson') then
    raise exception 'A proposal notified its sender or failed to notify the student';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','c1800000-0000-4000-8000-000000000001',true);
update public.bookings set status='confirmed' where id='c1810000-0000-4000-8000-000000000001';
do $$
begin
  if exists(select 1 from public.notifications where user_id=auth.uid() and title='You accepted the booking')
    or not exists(select 1 from public.notifications where user_id='c1800000-0000-4000-8000-000000000002'
      and title='Your booking request was accepted') then
    raise exception 'Acceptance failed to notify only the other participant';
  end if;
end;
$$;

-- Every producer goes through the same actor gate.
insert into public.notifications(user_id,kind,title,body,data)
select owner,kind,'delivery-gate-fixture','This is a test notification.','{}'::jsonb
from unnest(array['c1800000-0000-4000-8000-000000000001'::uuid,'c1800000-0000-4000-8000-000000000002'::uuid]) owner
cross join unnest(array['system','booking','payment','message']) kind;
do $$
begin
  if exists(select 1 from public.notifications where title='delivery-gate-fixture' and user_id=auth.uid())
    or (select count(*) from public.notifications where title='delivery-gate-fixture'
      and user_id='c1800000-0000-4000-8000-000000000002') <> 4 then
    raise exception 'Notification gate dropped counterpart updates or kept self-action alerts';
  end if;
end;
$$;

set local role authenticated;
do $$
declare ticket uuid; bug uuid; result jsonb;
begin
  result := public.create_detailed_support_ticket('billing','payment','Billing question','Please explain when my next payment will be due.',gen_random_uuid());
  ticket := (result->>'id')::uuid;
  perform set_config('test.delivery_ticket',ticket::text,true);
  if (select count(*) from public.notifications where user_id=auth.uid() and data->>'ticketId'=ticket::text
    and data->>'event'='ticket_opened') <> 1 then
    raise exception 'Ticket creation did not retain exactly one receipt';
  end if;
  result := public.create_detailed_support_ticket('bug','bug','Broken search button','The search button shows an error after I click it.',gen_random_uuid());
  bug := (result->>'id')::uuid;
  if (select count(*) from public.notifications where user_id=auth.uid() and data->>'ticketId'=bug::text) <> 1 then
    raise exception 'Bug intake lost or duplicated the ticket receipt';
  end if;
  perform public.change_membership('premium',true,gen_random_uuid());
  if exists(select 1 from public.notifications where user_id=auth.uid() and title='Subscription activated') then
    raise exception 'A plan purchase generated a self-action notification';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','c1800000-0000-4000-8000-000000000003',true);
do $$
declare ticket uuid := current_setting('test.delivery_ticket')::uuid;
begin
  perform public.update_support_ticket(ticket,1,'investigating','Your billing question is being reviewed.','',null);
  if exists(select 1 from public.notifications where user_id=auth.uid() and data->>'ticketId'=ticket::text) then
    raise exception 'Claiming or replying to a ticket notified the acting administrator';
  end if;
  perform public.admin_support_check_in();
  perform public.admin_support_check_in();
  if (select count(*) from public.notifications where user_id=auth.uid() and data->>'event'='daily_reminder') <> 1 then
    raise exception 'The automatic daily work reminder was lost or duplicated';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','c1800000-0000-4000-8000-000000000001',true);
select public.reply_support_ticket(current_setting('test.delivery_ticket')::uuid,'Thank you. I can provide more detail about the charge.',gen_random_uuid());
reset role;
do $$
declare ticket text := current_setting('test.delivery_ticket');
begin
  if not exists(select 1 from public.notifications where user_id='c1800000-0000-4000-8000-000000000001'
      and data->>'ticketId'=ticket and title like 'Ticket % updated')
    or not exists(select 1 from public.notifications where user_id='c1800000-0000-4000-8000-000000000003'
      and data->>'ticketId'=ticket and title like 'New reply %') then
    raise exception 'A support reply failed to notify its recipient';
  end if;
  perform private.billing_notice(auth.uid(),'Subscription updated','Your current plan was automatically renewed.','pricing');
  if not exists(select 1 from public.notifications where user_id=auth.uid() and data->>'event'='subscription_renewal') then
    raise exception 'A lazy automatic renewal was mistaken for a self-action';
  end if;
end;
$$;

-- Disabling a category still suppresses incoming alerts.
insert into public.user_notification_preferences(user_id,push_messages,push_booking_updates,push_payment_updates)
values ('c1800000-0000-4000-8000-000000000002',false,false,false)
on conflict(user_id) do update set push_messages=false,push_booking_updates=false,push_payment_updates=false;
insert into public.notifications(user_id,kind,title,body,data)
select 'c1800000-0000-4000-8000-000000000002',kind,'disabled-category-fixture','Preference test.','{}'::jsonb
from unnest(array['message','booking','payment']) kind;
do $$
begin
  if exists(select 1 from public.notifications where title='disabled-category-fixture') then
    raise exception 'Actor filtering bypassed notification preferences';
  end if;
end;
$$;

rollback;
