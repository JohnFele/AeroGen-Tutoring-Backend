begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('ba000000-0000-4000-8000-000000000001','billing.student@example.test','{}','{}'),
  ('ba000000-0000-4000-8000-000000000002','billing.tutor@example.test','{}','{}'),
  ('ba000000-0000-4000-8000-000000000003','billing.admin@example.test','{}','{}'),
  ('ba000000-0000-4000-8000-000000000004','billing.other@example.test','{}','{}');
update public.profiles set role='tutor' where id='ba000000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id='ba000000-0000-4000-8000-000000000003';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes) values
  ('ba000000-0000-4000-8000-000000000002','Billing Tutor',true,180,array['online']);
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select gen_random_uuid(),'ba000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002',
  now()+make_interval(hours=>i*2),now()+make_interval(hours=>i*2+1),'confirmed','online',60,180,180
from generate_series(1,4) i;
select set_config('test.lesson1',(array_agg(id order by starts_at))[1]::text,true),
       set_config('test.lesson2',(array_agg(id order by starts_at))[2]::text,true),
       set_config('test.lesson3',(array_agg(id order by starts_at))[3]::text,true),
       set_config('test.lesson4',(array_agg(id order by starts_at))[4]::text,true)
from public.bookings where student_id='ba000000-0000-4000-8000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000001',true);
do $$
declare k uuid := gen_random_uuid(); payment_key uuid := gen_random_uuid(); a jsonb; ticket jsonb;
begin
  a:=public.change_membership('learning',false,gen_random_uuid());
  if a->>'status'<>'failed' or public.my_account_billing()->'membership'->>'plan_id'<>'payg' then raise exception 'Decline changed subscription'; end if;
  a:=public.change_membership('learning',true,k);
  if a->>'status'<>'succeeded' or (a->>'amount_cents')::integer<>179900 or public.change_membership('learning',true,k) is distinct from a then raise exception 'Subscription payment or retry failed'; end if;
  begin
    perform public.change_membership('elite',true,gen_random_uuid());
    raise exception 'Student selected tutor plan';
  exception when invalid_parameter_value then null; end;
  if public.change_membership('premium',true,gen_random_uuid())->>'status'<>'scheduled' then raise exception 'Paid upgrade should be scheduled'; end if;
  if public.my_account_billing()->'membership'->>'next_plan_id'<>'premium' then raise exception 'Scheduled upgrade missing'; end if;
  perform public.change_membership('learning',true,gen_random_uuid());
  if public.my_account_billing()->'membership'->>'next_plan_id' is not null then raise exception 'Scheduled change not removed'; end if;
  a:=public.checkout_booking(current_setting('test.lesson1')::uuid,'checkout',false,gen_random_uuid());
  if a->>'status'<>'failed' or exists(select 1 from public.payments where booking_id=current_setting('test.lesson1')::uuid) then raise exception 'Decline created funds'; end if;
  a:=public.checkout_booking(current_setting('test.lesson1')::uuid,'checkout',true,payment_key);
  if a->>'status'<>'succeeded' or public.checkout_booking(current_setting('test.lesson1')::uuid,'checkout',true,payment_key) is distinct from a then raise exception 'Lesson charge retry duplicated'; end if;
  begin
    perform public.confirm_lesson_outcome(current_setting('test.lesson1')::uuid,true,'');
    raise exception 'Unfinished lesson confirmed';
  exception when sqlstate 'PT409' then null; end;
  perform public.checkout_booking(current_setting('test.lesson2')::uuid,'package',true,gen_random_uuid());
  perform public.checkout_booking(current_setting('test.lesson3')::uuid,'checkout',true,gen_random_uuid());
  perform public.checkout_booking(current_setting('test.lesson4')::uuid,'checkout',true,gen_random_uuid());
  perform public.respond_to_tutoring_booking(current_setting('test.lesson4')::uuid,'cancel');
  if (select status from public.payments where booking_id=current_setting('test.lesson4')::uuid)<>'refunded' then raise exception 'Cancelled lesson not refunded'; end if;
  if (public.my_account_billing()->'membership'->>'credits_used')::integer<>1 then raise exception 'Package credit not reserved'; end if;
  ticket:=public.create_support_ticket('billing','Question about my receipt','Please help me understand my simulated receipt.',k);
  if ticket->>'reference' not like 'AG-%' or public.create_support_ticket('billing','Question about my receipt','Please help me understand my simulated receipt.',k) is distinct from ticket then raise exception 'Ticket reference or retry failed'; end if;
  perform set_config('test.ticket',ticket->>'id',true);
end;
$$;
reset role;

update public.bookings set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'
where id in(current_setting('test.lesson1')::uuid,current_setting('test.lesson2')::uuid,current_setting('test.lesson3')::uuid);
set local role authenticated;
select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000002',true);
do $$
begin
  perform public.confirm_lesson_outcome(current_setting('test.lesson1')::uuid,true,'');
  if (public.my_account_billing()->>'payout_balance_cents')::integer<>0 then raise exception 'One response released funds'; end if;
  perform public.confirm_lesson_outcome(current_setting('test.lesson2')::uuid,false,'The student could not attend.');
  perform public.confirm_lesson_outcome(current_setting('test.lesson3')::uuid,true,'');
end;
$$;
select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000001',true);
do $$
declare t uuid; confidential jsonb;
begin
  if public.confirm_lesson_outcome(current_setting('test.lesson1')::uuid,true,'') <> 'completed' then raise exception 'Mutual confirmation did not complete'; end if;
  if public.confirm_lesson_outcome(current_setting('test.lesson2')::uuid,false,'The lesson did not happen.') <> 'no_show' then raise exception 'Mutual no-show did not settle'; end if;
  if (public.my_account_billing()->'membership'->>'credits_used')::integer<>0 then raise exception 'Package credit not restored'; end if;
  confidential:=public.report_booking_ticket(current_setting('test.lesson3')::uuid,'safety','A separate private safety concern for staff.');
  perform set_config('test.confidential',confidential->>'id',true);
  if public.confirm_lesson_outcome(current_setting('test.lesson3')::uuid,false,'The lesson was not delivered.') <> 'disputed' then raise exception 'Disagreement did not open dispute'; end if;
  select (item->>'id')::uuid into t from public.my_support_tickets(0) item where item->>'category'='lesson_dispute';
  if t is null then raise exception 'Dispute missing from reporter tickets'; end if;
  perform set_config('test.dispute',t::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000002',true);
do $$
declare k uuid := gen_random_uuid(); a jsonb;
begin
  perform public.change_membership('pro',true,gen_random_uuid());
  perform public.set_mock_renewal_result(false);
  if (public.my_account_billing()->>'payout_balance_cents')::integer<>15300 then raise exception 'Balance does not reflect fees or holds'; end if;
  if public.request_tutor_payout(10000,false,gen_random_uuid())->>'status'<>'failed' then raise exception 'Simulated payout decline missing'; end if;
  if (public.my_account_billing()->>'payout_balance_cents')::integer<>15300 then raise exception 'Declined payout reduced balance'; end if;
  a:=public.request_tutor_payout(10000,true,k);
  if public.request_tutor_payout(10000,true,k) is distinct from a or (public.my_account_billing()->>'payout_balance_cents')::integer<>5300 then raise exception 'Payout retry withdrew again'; end if;
  if public.my_support_ticket(current_setting('test.dispute')::uuid)->>'reference' not like 'AG-%' then raise exception 'Tutor cannot see the shared dispute'; end if;
  begin
    perform public.my_support_ticket(current_setting('test.confidential')::uuid);
    raise exception 'Confidential report was merged into the shared dispute';
  exception when sqlstate 'PT404' then null; end;
  begin
    perform public.my_support_ticket(current_setting('test.ticket')::uuid);
    raise exception 'Tutor accessed unrelated support ticket';
  exception when sqlstate 'PT404' then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000003',true);
do $$
declare item jsonb; t uuid := current_setting('test.dispute')::uuid; general uuid := current_setting('test.ticket')::uuid;
begin
  begin
    perform public.change_membership('premium',true,gen_random_uuid());
    raise exception 'Admin changed a subscription';
  exception when insufficient_privilege then null; end;
  item:=public.admin_support_ticket(t);
  if jsonb_array_length(item->'lesson_outcomes')<>2 then raise exception 'Dispute evidence unavailable'; end if;
  perform public.update_support_ticket(t,(item->>'version')::integer,'investigating','','',null);
  perform public.update_support_ticket(t,(item->>'version')::integer+1,'resolved','The lesson was refunded.','Both participants provided evidence and this was resolved.','refund');
  if public.admin_support_ticket(t)->'booking'<>'null'::jsonb then raise exception 'Closed case still exposes booking'; end if;
  item:=public.admin_support_ticket(general);
  perform public.update_support_ticket(general,(item->>'version')::integer,'investigating','','',null);
  perform public.update_support_ticket(general,(item->>'version')::integer+1,'waiting','Please send a receipt reference.','',null);
end;
$$;

select set_config('request.jwt.claim.sub','ba000000-0000-4000-8000-000000000001',true);
do $$
declare t uuid := current_setting('test.ticket')::uuid; k uuid := gen_random_uuid(); item jsonb;
begin
  if (select status from public.payments where booking_id=current_setting('test.lesson3')::uuid)<>'refunded' then raise exception 'Dispute refund was not recorded'; end if;
  perform public.reply_support_ticket(t,'My reference is test-123.',k);
  perform public.reply_support_ticket(t,'My reference is test-123.',k);
  item:=public.my_support_ticket(t);
  if item->>'status'<>'investigating' or jsonb_array_length(item->'thread')<>2 or item ? 'outcome' then raise exception 'Ticket reply or privacy failed'; end if;
  perform public.change_membership('payg',true,gen_random_uuid());
end;
$$;
reset role;

update private.memberships set period_start=now()-interval '31 days',period_end=now()-interval '1 day'
where owner in ('ba000000-0000-4000-8000-000000000001','ba000000-0000-4000-8000-000000000002');
select private.process_billing_queue();
do $$
begin
  if not exists(select 1 from private.memberships where owner='ba000000-0000-4000-8000-000000000001' and plan_id='payg' and period_end is null) then
    raise exception 'End-of-cycle cancellation did not apply';
  end if;
  if not exists(select 1 from private.memberships where owner='ba000000-0000-4000-8000-000000000002' and plan_id='basic' and period_end is null)
    or not exists(select 1 from private.billing_events where owner='ba000000-0000-4000-8000-000000000002' and kind='renewal' and status='failed') then
    raise exception 'Declined renewal left the paid plan active';
  end if;
end;
$$;
rollback;
