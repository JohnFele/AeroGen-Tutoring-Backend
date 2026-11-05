begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('e1000000-0000-4000-8000-000000000001','topup.student@example.test','{}','{}'),
  ('e1000000-0000-4000-8000-000000000002','topup.tutor@example.test','{}','{}');
update public.profiles set role='tutor' where id='e1000000-0000-4000-8000-000000000002';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,teaching_modes)
values ('e1000000-0000-4000-8000-000000000002','Top-Up Test Tutor',true,true,400,array['online']);

set local role authenticated;
select set_config('request.jwt.claim.sub','e1000000-0000-4000-8000-000000000001',true);
select public.change_membership('learning',true,gen_random_uuid());
select set_config('request.jwt.claim.sub','e1000000-0000-4000-8000-000000000002',true);
select public.save_booking_availability((select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',540,'end_minute',720))
  from generate_series(1,7) d),false);
reset role;

insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('e2000000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'e1000000-0000-4000-8000-000000000001','e1000000-0000-4000-8000-000000000002',
  (private.booking_local_today()+i+2+time '10:00') at time zone 'Africa/Johannesburg',
  (private.booking_local_today()+i+2+time '11:00') at time zone 'Africa/Johannesburg',
  'pending','online',60,400,400 from generate_series(1,4) i;

set local role authenticated;
do $$
declare
  tutor constant uuid := 'e1000000-0000-4000-8000-000000000002';
  student constant uuid := 'e1000000-0000-4000-8000-000000000001';
  first_lesson constant uuid := 'e2000000-0000-4000-8000-000000000001';
  next_lesson constant uuid := 'e2000000-0000-4000-8000-000000000002';
  expiring_lesson constant uuid := 'e2000000-0000-4000-8000-000000000003';
  settling_lesson constant uuid := 'e2000000-0000-4000-8000-000000000004';
  attempt uuid := gen_random_uuid();
  result jsonb;
  row jsonb;
begin
  perform set_config('request.jwt.claim.sub',tutor::text,true);
  perform public.respond_to_tutoring_booking(first_lesson,'accept');
  if exists(select 1 from jsonb_array_elements(public.my_tutoring_workspace()->'bookings') b
    where b->>'id'=first_lesson::text and b->>'top_up_due_cents' is not null) then
    raise exception 'The student checkout balance appeared in the tutor workspace';
  end if;

  perform set_config('request.jwt.claim.sub',student::text,true);
  select b into row from jsonb_array_elements(public.my_tutoring_workspace()->'bookings') b where b->>'id'=first_lesson::text;
  if row->>'top_up_due_cents' is distinct from '17000' or row->>'payment_secured' is distinct from 'false'
    or public.my_account_billing()->'lesson_credits'->>'available' is distinct from '7' then
    raise exception 'Acceptance must reserve one credit with R170 still due: %',row;
  end if;
  begin
    perform public.checkout_booking(first_lesson,'checkout',true,gen_random_uuid());
    raise exception 'A reserved credit was bypassed by full-price checkout';
  exception when sqlstate 'PT409' then null; end;

  result := public.checkout_booking(first_lesson,'package',false,gen_random_uuid());
  if result->>'status' is distinct from 'failed' or result->>'amount_cents' is distinct from '17000'
    or public.my_account_billing()->'lesson_credits'->>'available' is distinct from '7' then
    raise exception 'Declined top-up changed the reservation or amount';
  end if;
  result := public.checkout_booking(first_lesson,'package',true,attempt);
  if result->>'status' is distinct from 'succeeded' or result->>'amount_cents' is distinct from '17000'
    or result is distinct from public.checkout_booking(first_lesson,'package',true,attempt) then
    raise exception 'Top-up checkout was not successful and idempotent';
  end if;
  select b into row from jsonb_array_elements(public.my_tutoring_workspace()->'bookings') b where b->>'id'=first_lesson::text;
  if row->>'top_up_due_cents' is not null or row->>'payment_secured' is distinct from 'true'
    or public.my_account_billing()->'lesson_credits'->>'available' is distinct from '7' then
    raise exception 'The top-up failed to secure the full lesson with exactly one credit';
  end if;
  perform public.respond_to_tutoring_booking(first_lesson,'cancel');
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '8'
    or not exists(select 1 from jsonb_array_elements(public.my_account_billing()->'events') e
      where e->>'kind'='refund' and e->>'target'=first_lesson::text and e->>'amount_cents'='17000') then
    raise exception 'Cancelling a paid top-up should return one credit and refund R170';
  end if;

  perform set_config('request.jwt.claim.sub',tutor::text,true);
  perform public.respond_to_tutoring_booking(next_lesson,'accept');
  perform public.respond_to_tutoring_booking(expiring_lesson,'accept');
  perform public.respond_to_tutoring_booking(settling_lesson,'accept');
  perform set_config('request.jwt.claim.sub',student::text,true);
  perform public.respond_to_tutoring_booking(next_lesson,'cancel');
  perform public.checkout_booking(settling_lesson,'package',true,gen_random_uuid());
  if not exists(select 1 from jsonb_array_elements(public.my_account_billing()->'events') e
    where e->>'kind'='refund' and e->>'target'=next_lesson::text and e->>'amount_cents'='0') then
    raise exception 'Cancelling an unpaid top-up recorded a cash refund';
  end if;
end;
$$;
reset role;

update public.bookings set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'
where id in ('e2000000-0000-4000-8000-000000000003','e2000000-0000-4000-8000-000000000004');
select private.process_billing_queue();
do $$
begin
  if (select status from public.bookings where id='e2000000-0000-4000-8000-000000000003') <> 'cancelled'
    or (private.lesson_credit_balance('e1000000-0000-4000-8000-000000000001')->>'available')::int <> 7 then
    raise exception 'Expired top-up did not release its reservation';
  end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub','e1000000-0000-4000-8000-000000000001',true);
select public.confirm_lesson_outcome('e2000000-0000-4000-8000-000000000004',true,'');
select set_config('request.jwt.claim.sub','e1000000-0000-4000-8000-000000000002',true);
select public.confirm_lesson_outcome('e2000000-0000-4000-8000-000000000004',true,'');
do $$
begin
  if public.my_account_billing()->>'payout_balance_cents' is distinct from '34000' then
    raise exception 'Tutor should receive R340 after the 15%% platform fee on the full R400';
  end if;
end;
$$;

rollback;
