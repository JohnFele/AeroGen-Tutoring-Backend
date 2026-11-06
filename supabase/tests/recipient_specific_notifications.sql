begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('e6100000-0000-4000-8000-000000000001','notices.student@example.test','{}','{}'),
  ('e6100000-0000-4000-8000-000000000002','notices.tutor@example.test','{}','{}'),
  ('e6100000-0000-4000-8000-000000000003','notices.outsider@example.test','{}','{}');
update public.profiles set first_name='Maya' where id='e6100000-0000-4000-8000-000000000001';
update public.profiles set role='tutor' where id='e6100000-0000-4000-8000-000000000002';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,teaching_modes)
values ('e6100000-0000-4000-8000-000000000002','Tutor Lee',true,true,400,array['online']);

set local role authenticated;
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000001',true);
select public.change_membership('learning',true,gen_random_uuid());
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000002',true);
select public.save_booking_availability((select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',540,'end_minute',720))
  from generate_series(1,7) d),false);
reset role;

insert into public.bookings(id,student_id,tutor_id,proposed_by,starts_at,ends_at,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('e6200000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'e6100000-0000-4000-8000-000000000001','e6100000-0000-4000-8000-000000000002',
  case when i=2 then 'e6100000-0000-4000-8000-000000000002'::uuid else 'e6100000-0000-4000-8000-000000000001'::uuid end,
  (private.booking_local_today()+i+2+time '10:00') at time zone 'Africa/Johannesburg',
  (private.booking_local_today()+i+2+time '11:00') at time zone 'Africa/Johannesburg',
  'online',60,400,case when i=3 then 200 else 400 end from generate_series(1,3) i;

set local role authenticated;
do $$
declare
  student constant uuid := 'e6100000-0000-4000-8000-000000000001';
  tutor constant uuid := 'e6100000-0000-4000-8000-000000000002';
  booking constant uuid := 'e6200000-0000-4000-8000-000000000001';
  proposal constant uuid := 'e6200000-0000-4000-8000-000000000002';
  covered constant uuid := 'e6200000-0000-4000-8000-000000000003';
  request_key uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub',tutor::text,true);
  if not exists(select 1 from public.notifications where title='Booking request received'
    and data->>'bookingId'=booking::text and body like '%Maya%accept or decline%') then
    raise exception 'Tutor did not receive an actionable notice for a student request';
  end if;
  perform public.respond_to_tutoring_booking(booking,'accept');
  perform public.respond_to_tutoring_booking(booking,'accept');
  if (select count(*) from public.notifications where title='You accepted the booking' and data->>'bookingId'=booking::text
    and body like '%student still needs to finish checkout%' and body not like '%R170%')<>1 then
    raise exception 'Tutor acceptance notice was duplicated or contained student checkout details';
  end if;

  perform set_config('request.jwt.claim.sub',student::text,true);
  if not exists(select 1 from public.notifications where title='Booking request sent' and data->>'bookingId'=booking::text
    and body like '%Tutor Lee%when they respond%') or
    not exists(select 1 from public.notifications where title='Your booking request was accepted' and data->>'bookingId'=booking::text
    and body like '%credit is reserved%R170.00%') or
    not exists(select 1 from public.notifications where title='Your tutor proposed a lesson' and data->>'bookingId'=proposal::text
    and body like '%Tutor Lee%accept or decline%') then
    raise exception 'Student did not receive their own request, funding, and proposal notices';
  end if;
  perform public.respond_to_tutoring_booking(proposal,'decline');
  perform public.checkout_booking(booking,'package',true,request_key);
  perform public.checkout_booking(booking,'package',true,request_key);
  if (select count(*) from public.notifications where title='Your lesson is funded' and data->>'bookingId'=booking::text)<>1 then
    raise exception 'Student did not get exactly one payment success notice';
  end if;
  perform public.respond_to_tutoring_booking(booking,'cancel');
  if not exists(select 1 from public.notifications where title='You cancelled the lesson' and data->>'bookingId'=booking::text) or
    not exists(select 1 from public.notifications where title='Your lesson refund was recorded'
      and kind='payment' and data->>'tab'='payments' and body like '%credit was returned%top-up was refunded%') then
    raise exception 'Student cancellation and refund notices are missing';
  end if;

  perform set_config('request.jwt.claim.sub',tutor::text,true);
  if (select count(*) from public.notifications where kind='payment' and title='Lesson funding secured')<>1 or
    not exists(select 1 from public.notifications where title='Lesson earnings adjusted' and data->>'tab'='earnings') or
    not exists(select 1 from public.notifications where title='Your booking request was declined' and data->>'bookingId'=proposal::text) then
    raise exception 'Tutor payment and decline notices are missing or duplicated';
  end if;
  perform public.respond_to_tutoring_booking(covered,'accept');
  perform set_config('request.jwt.claim.sub',student::text,true);
  if not exists(select 1 from public.notifications where data->>'bookingId'=covered::text and body like '%credit covers this booking%') then
    raise exception 'Fully covered booking was missing the credit confirmation';
  end if;
end;
$$;
reset role;

update public.bookings set starts_at=now()-interval '2 hours',ends_at=now()-interval '1 hour'
where id='e6200000-0000-4000-8000-000000000003';
insert into public.user_notification_preferences(user_id,push_payment_updates)
values('e6100000-0000-4000-8000-000000000002',false)
on conflict(user_id) do update set push_payment_updates=false;

set local role authenticated;
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000001',true);
select public.confirm_lesson_outcome('e6200000-0000-4000-8000-000000000003',true,'');
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000002',true);
do $$
begin
  if not exists(select 1 from public.notifications where title='Confirm the lesson you taught' and body like '%Maya%') then
    raise exception 'Tutor did not receive the outcome action';
  end if;
  perform public.confirm_lesson_outcome('e6200000-0000-4000-8000-000000000003',true,'');
  if exists(select 1 from public.notifications where title='Lesson earnings released') then
    raise exception 'Tutor payment preference was ignored';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000001',true);
do $$
begin
  if exists(select 1 from public.notifications where title='Confirm your lesson') or
    not exists(select 1 from public.notifications where title='Your lesson is complete') then
    raise exception 'Student received a redundant reminder or missed lesson completion';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','e6100000-0000-4000-8000-000000000003',true);
do $$
begin
  if exists(select 1 from public.notifications where data->>'bookingId' like 'e6200000-%') then
    raise exception 'A nonparticipant could read private booking notifications';
  end if;
end;
$$;

rollback;
