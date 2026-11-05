begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('c1000000-0000-4000-8000-000000000001','credit.student@example.test','{}','{}'),
  ('c1000000-0000-4000-8000-000000000002','credit.tutor@example.test','{}','{}'),
  ('c1000000-0000-4000-8000-000000000003','credit.admin@example.test','{}','{}');
update public.profiles set role='tutor' where id='c1000000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id='c1000000-0000-4000-8000-000000000003';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
values ('c1000000-0000-4000-8000-000000000002','Credit Test Tutor',true,180,array['online']);

insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('c2000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'c1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002',
  now() + make_interval(days => 40+i),now() + make_interval(days => 40+i,mins => case when i=10 then 90 else 60 end),
  'confirmed','online',case when i=10 then 90 else 60 end,180,case when i=10 then 270 else 180 end
from generate_series(1,11) i;
update public.bookings set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'
where id='c2000000-0000-4000-8000-000000000009';

set local role authenticated;
select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000001',true);
do $$
declare
  package_key uuid := gen_random_uuid();
  lesson_key uuid := gen_random_uuid();
  billing jsonb;
  result jsonb;
  request uuid := gen_random_uuid();
begin
  perform public.change_membership('learning',false,gen_random_uuid());
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '0' then
    raise exception 'A declined payment awarded lesson credits';
  end if;
  result := public.change_membership('learning',true,package_key);
  if result is distinct from public.change_membership('learning',true,package_key) then raise exception 'Purchase replay failed'; end if;
  billing := public.my_account_billing();
  if billing->'lesson_credits'->>'available' is distinct from '8' or billing->'credit_purchases'->0->>'credits' is distinct from '8'
    or jsonb_array_length(billing->'lessons') <> 0 then raise exception 'Unused package credits are missing or double counted'; end if;
  result := public.checkout_booking('c2000000-0000-4000-8000-000000000001','package',true,lesson_key);
  if result is distinct from public.checkout_booking('c2000000-0000-4000-8000-000000000001','package',true,lesson_key) then
    raise exception 'Lesson checkout replay failed';
  end if;
  for i in 2..7 loop
    perform public.checkout_booking(('c2000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,'package',true,gen_random_uuid());
  end loop;
  begin
    perform public.checkout_booking('c2000000-0000-4000-8000-000000000010','package',true,gen_random_uuid());
    raise exception 'An ineligible lesson could use a package credit';
  exception when sqlstate 'PT409' then null; end;
  perform public.checkout_booking('c2000000-0000-4000-8000-000000000008','package',true,gen_random_uuid());
  if public.my_account_billing()->'lesson_credits'->>'reserved' is distinct from '8' then raise exception 'Incorrect reservation count'; end if;
  begin
    perform public.checkout_booking('c2000000-0000-4000-8000-000000000011','package',true,gen_random_uuid());
    raise exception 'A ninth lesson used an eight-credit package';
  exception when sqlstate 'PT409' then null; end;
  begin
    perform public.checkout_booking('c2000000-0000-4000-8000-000000000001','package',true,gen_random_uuid());
    raise exception 'A new request could charge the same booking twice';
  exception when sqlstate 'PT409' then null; end;
  begin
    perform public.confirm_lesson_outcome('c2000000-0000-4000-8000-000000000009',true,'');
    raise exception 'An unfunded lesson could be recorded as delivered';
  exception when sqlstate 'PT409' then null; end;
  perform public.create_detailed_support_ticket('account','access','Account question','I need help accessing my account today.',request);
  if public.my_support_ticket(request)->>'can_resolve' is distinct from 'true' then raise exception 'Requester cannot close an ordinary ticket'; end if;
  perform set_config('test.credit_ticket',request::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000002',true);
do $$
begin
  perform public.resolve_support_ticket(current_setting('test.credit_ticket')::uuid);
  raise exception 'Another user closed the ticket';
exception when sqlstate 'PT404' then null;
end;
$$;
select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000003',true);
do $$
declare ticket uuid := current_setting('test.credit_ticket')::uuid;
begin
  perform public.update_support_ticket(ticket,1,'investigating','','',null);
end;
$$;

select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000001',true);
do $$
declare ticket uuid := current_setting('test.credit_ticket')::uuid;
begin
  perform public.resolve_support_ticket(ticket);
  perform public.resolve_support_ticket(ticket);
  if public.my_support_ticket(ticket)->>'status' is distinct from 'resolved'
    or jsonb_array_length(public.my_support_ticket(ticket)->'thread') <> 0 then raise exception 'Closing the ticket required a reply'; end if;
  perform public.change_membership('payg',true,gen_random_uuid());
end;
$$;
reset role;

update private.memberships set period_start=now()-interval '31 days',period_end=now()-interval '1 day'
where owner='c1000000-0000-4000-8000-000000000001';
update public.bookings set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'
where id='c2000000-0000-4000-8000-000000000001';
select private.process_billing_queue();

set local role authenticated;
select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000001',true);
do $$
declare billing jsonb;
begin
  perform public.respond_to_tutoring_booking('c2000000-0000-4000-8000-000000000002','cancel');
  billing := public.my_account_billing();
  if billing->'membership'->>'plan_id' is distinct from 'payg'
    or billing->'lesson_credits'->>'available' is distinct from '1'
    or billing->'lesson_credits'->>'restored' is distinct from '1'
    or (select status from public.bookings where id='c2000000-0000-4000-8000-000000000009') is distinct from 'cancelled' then
    raise exception 'Cancellation lost a lesson credit or failed to close the expired booking';
  end if;
  perform public.checkout_booking('c2000000-0000-4000-8000-000000000011','package',true,gen_random_uuid());
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '0' then
    raise exception 'The carried credit could not be reserved on the free plan';
  end if;
  perform public.confirm_lesson_outcome('c2000000-0000-4000-8000-000000000001',true,'');
  perform public.change_membership('learning',true,gen_random_uuid());
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '8' then
    raise exception 'A new package did not add to the carried credit balance';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','c1000000-0000-4000-8000-000000000002',true);
select public.confirm_lesson_outcome('c2000000-0000-4000-8000-000000000001',true,'');
reset role;

do $$
declare student constant uuid := 'c1000000-0000-4000-8000-000000000001';
begin
  if private.lesson_credit_balance(student)->>'used' is distinct from '1'
    or private.lesson_credit_balance(student)->>'available' is distinct from '8' then raise exception 'Delivery changed the balance twice'; end if;
  if (select count(*) from public.notifications where title like 'Ticket % resolved'
      and data->>'ticketId' = current_setting('test.credit_ticket')) <> 1 then
    raise exception 'Requester closure sent duplicate notifications or missed the assigned admin';
  end if;
end;
$$;

rollback;
