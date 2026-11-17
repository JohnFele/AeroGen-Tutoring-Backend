begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('c1900000-0000-4000-8000-000000000001','statement.student@example.test','{}','{}'),
  ('c1900000-0000-4000-8000-000000000002','statement.tutor@example.test','{}','{}'),
  ('c1900000-0000-4000-8000-000000000003','statement.other@example.test','{}','{}');
update public.profiles set role='tutor',first_name='Statement',last_name='Tutor'
where id in ('c1900000-0000-4000-8000-000000000002','c1900000-0000-4000-8000-000000000003');
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
select id,'Statement Tutor',true,100,array['online'] from public.profiles
where id in ('c1900000-0000-4000-8000-000000000002','c1900000-0000-4000-8000-000000000003');

do $$
declare starts date := (date_trunc('month',now() at time zone 'Africa/Johannesburg')-interval '3 months')::date;
  boundary timestamptz; released timestamptz; bid uuid; pid uuid; gross numeric; funds_state text; payment_status text;
begin
  perform set_config('test.statement_from',starts::text,true);
  perform set_config('test.statement_to',((starts+interval '3 months')::date-1)::text,true);
  boundary := starts::timestamp at time zone 'Africa/Johannesburg';
  for n in 1..67 loop
    bid := ('c1910000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    pid := ('c1920000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
    released := boundary + interval '1 day';
    gross := 100; funds_state := 'released'; payment_status := 'paid';
    if n=61 then gross:=1000; released:=boundary-interval '1 minute';
    elsif n=62 then gross:=500; released:=(starts+interval '1 month') at time zone 'Africa/Johannesburg';
    elsif n=63 then gross:=900; released:=(starts+interval '3 months') at time zone 'Africa/Johannesburg';
    elsif n=64 then gross:=10000; funds_state:='held';
    elsif n=65 then gross:=10000; funds_state:='disputed';
    elsif n=66 then gross:=10000; funds_state:='refunded';
    elsif n=67 then gross:=10000; payment_status:='pending';
    end if;
    insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
    values (bid,'c1900000-0000-4000-8000-000000000001','c1900000-0000-4000-8000-000000000002',
      now()+interval '1 day',now()+interval '25 hours','confirmed','online',60,100,gross);
    insert into public.payments(id,booking_id,payer_id,payee_id,provider,status,amount,platform_fee,paid_at)
    values (pid,bid,'c1900000-0000-4000-8000-000000000001','c1900000-0000-4000-8000-000000000002',
      'demo',payment_status,gross,gross/10,released);
    insert into private.lesson_funds(booking_id,payment_id,source,state,settled_at)
    values(bid,pid,'checkout',funds_state,released);
  end loop;
  insert into private.billing_events(owner,request_id,kind,target,amount_cents,status,created_at)
  values
    ('c1900000-0000-4000-8000-000000000002',gen_random_uuid(),'payout','10000',10000,'succeeded',boundary-interval '1 minute'),
    ('c1900000-0000-4000-8000-000000000002',gen_random_uuid(),'payout','20000',20000,'succeeded',boundary+interval '2 days'),
    ('c1900000-0000-4000-8000-000000000002',gen_random_uuid(),'payout','15000',15000,'succeeded',(starts+interval '1 month') at time zone 'Africa/Johannesburg'),
    ('c1900000-0000-4000-8000-000000000002',gen_random_uuid(),'payout','99000',99000,'failed',boundary+interval '1 day'),
    ('c1900000-0000-4000-8000-000000000002',gen_random_uuid(),'payout','99000',99000,'scheduled',boundary+interval '1 day');
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub','c1900000-0000-4000-8000-000000000002',true);
do $$
declare statement jsonb; s jsonb; from_date date := current_setting('test.statement_from')::date;
  to_date date := current_setting('test.statement_to')::date;
begin
  statement := public.my_tutor_earnings_statement(from_date,to_date);
  s := statement->'summary';
  if (s->>'opening_cents')::bigint<>80000 or (s->>'gross_cents')::bigint<>650000
    or (s->>'fee_cents')::bigint<>65000 or (s->>'net_cents')::bigint<>585000
    or (s->>'payout_cents')::bigint<>35000 or (s->>'closing_cents')::bigint<>630000 then
    raise exception 'Statement used incomplete records, lesson dates, unpaid funds or failed payouts: %',s;
  end if;
  if jsonb_array_length(statement->'months')<>3
    or (statement->'months'->0->>'closing_cents')::bigint<>600000
    or (statement->'months'->1->>'closing_cents')::bigint<>630000
    or (statement->'months'->2->>'net_cents')::bigint<>0
    or statement->>'simulation'<>'true'
    or statement->'holder'->>'name'<>'Statement Tutor'
    or statement ? 'lessons' then
    raise exception 'Monthly SAST boundaries, account details, simulation disclosure or scope were wrong';
  end if;
  begin
    perform public.my_tutor_earnings_statement(to_date,from_date);
    raise exception 'A reversed statement period was accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.my_tutor_earnings_statement((from_date-interval '12 months')::date,to_date);
    raise exception 'An excessive statement period was accepted';
  exception when sqlstate '22023' then null; end;
  begin
    perform public.my_tutor_earnings_statement(from_date,(now() at time zone 'Africa/Johannesburg')::date+1);
    raise exception 'A future statement end was accepted';
  exception when sqlstate '22023' then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','c1900000-0000-4000-8000-000000000003',true);
do $$
declare s jsonb;
begin
  s := public.my_tutor_earnings_statement(current_setting('test.statement_from')::date,current_setting('test.statement_to')::date)->'summary';
  if (s->>'gross_cents')::bigint<>0 or (s->>'opening_cents')::bigint<>0 or (s->>'closing_cents')::bigint<>0 then
    raise exception 'A tutor saw another account financial history';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','c1900000-0000-4000-8000-000000000001',true);
do $$
begin
  begin
    perform public.my_tutor_earnings_statement(current_setting('test.statement_from')::date,current_setting('test.statement_to')::date);
    raise exception 'A student could request a tutor income statement';
  exception when insufficient_privilege then null; end;
end;
$$;
reset role;

update private.lesson_funds set settled_at=null where payment_id='c1920000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','c1900000-0000-4000-8000-000000000002',true);
do $$
declare s jsonb;
begin
  s := public.my_tutor_earnings_statement(current_setting('test.statement_from')::date,current_setting('test.statement_to')::date)->'summary';
  if (s->>'estimated_release_dates')::integer<>1 or (s->>'closing_cents')::bigint<>630000 then
    raise exception 'Legacy releases lost their amounts or their estimated-date disclosure';
  end if;
end;
$$;
reset role;
rollback;

