begin;

insert into auth.users (id,email,raw_user_meta_data,raw_app_meta_data)
values ('ad000000-0000-4000-8000-000000000001','booking.student@example.test','{"first_name":"Case Student"}','{}'),
       ('ad000000-0000-4000-8000-000000000002','booking.tutor@example.test','{}','{}'),
       ('ad000000-0000-4000-8000-000000000003','booking.other@example.test','{}','{}'),
       ('ad000000-0000-4000-8000-000000000004','booking.admin@example.test','{}','{}');
update public.profiles set role='tutor' where id='ad000000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id='ad000000-0000-4000-8000-000000000004';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,teaching_modes,hourly_rate)
values('ad000000-0000-4000-8000-000000000002','Case Tutor',true,true,array['online'],180);
with subject as (
  insert into public.subjects(name,category,slug) values ('Private Booking Test','General','private-booking-test') returning id
)
insert into public.tutor_subjects(tutor_id,subject_id) select 'ad000000-0000-4000-8000-000000000002',id from subject;
select set_config('test.subject',(select id::text from public.subjects where slug='private-booking-test'),true);

set local role authenticated;
select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000002',true);
select public.save_tutor_booking_hours(
  (select jsonb_agg(jsonb_build_object('weekday',day,'start_minute',540,'end_minute',720)) from generate_series(1,7) day)
);
reset role;
set local role anon;
do $$
begin
  if not exists(select 1 from public.tutor_bookable_slots('ad000000-0000-4000-8000-000000000002',60))
    then raise exception 'Public availability missing'; end if;
  if has_column_privilege('public.reviews','booking_id','select') or has_column_privilege('public.reviews','student_id','select')
    then raise exception 'Public review exposes booking identities'; end if;
end;
$$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000001',true);
do $$
declare tutor constant uuid := 'ad000000-0000-4000-8000-000000000002'; slot timestamptz; booking_key uuid; again uuid;
begin
  select starts into slot from public.tutor_bookable_slots(tutor,60) as starts
  where starts > now() + interval '12 hours' order by starts limit 1;
  perform set_config('test.slot',slot::text,true);
  booking_key := public.request_tutoring_booking(tutor,auth.uid(),current_setting('test.subject')::bigint,slot,60,'online','individual','Please explain algebra.');
  again := public.request_tutoring_booking(tutor,auth.uid(),current_setting('test.subject')::bigint,slot,60,'online','individual','Please explain algebra.');
  if booking_key is distinct from again then raise exception 'Booking retry created a duplicate'; end if;
  perform set_config('test.booking',booking_key::text,true);
  if not exists(select 1 from public.bookings where bookings.id=booking_key and status='pending') then raise exception 'Student cannot read own request'; end if;
  if not exists(select 1 from public.notifications where data->>'bookingId'=booking_key::text and title='Booking request sent') then raise exception 'Student request notification missing'; end if;
  begin
    perform public.respond_to_tutoring_booking(booking_key,'accept');
    raise exception 'Proposer accepted their own booking';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000003',true);
do $$
declare tutor constant uuid := 'ad000000-0000-4000-8000-000000000002'; booking_key uuid;
begin
  if exists(select 1 from public.bookings where bookings.id=current_setting('test.booking')::uuid) then raise exception 'Unrelated account saw booking'; end if;
  booking_key := public.request_tutoring_booking(tutor,auth.uid(),current_setting('test.subject')::bigint,current_setting('test.slot')::timestamptz,60,'online','individual','');
  perform set_config('test.competing',booking_key::text,true);
  begin
    perform public.report_booking_concern(current_setting('test.booking')::uuid,'safety','The unrelated account has no access.');
    raise exception 'Unrelated account filed report';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000002',true);
do $$
declare booking_key uuid := current_setting('test.booking')::uuid; slot timestamptz;
begin
  if not exists(select 1 from public.notifications where data->>'bookingId'=booking_key::text and title='Booking request received') then raise exception 'Tutor request notification missing'; end if;
  perform public.respond_to_tutoring_booking(booking_key,'accept');
  if not exists(select 1 from public.bookings where bookings.id=booking_key and status='confirmed' and confirmed_at is not null) then raise exception 'Confirmation not persisted'; end if;
  if not exists(select 1 from public.notifications where data->>'bookingId'=booking_key::text and title='Booking accepted') then raise exception 'Tutor acceptance notification missing'; end if;
  if exists(select 1 from public.tutor_bookable_slots(auth.uid(),60) as t where t=current_setting('test.slot')::timestamptz) then raise exception 'Confirmed slot remains public'; end if;
  begin
    perform public.respond_to_tutoring_booking(current_setting('test.competing')::uuid,'accept');
    raise exception 'Overlapping request confirmed';
  exception when sqlstate 'PT409' then null;
  end;
  perform public.respond_to_tutoring_booking(current_setting('test.competing')::uuid,'decline');
  if not exists(select 1 from public.notifications where data->>'bookingId'=current_setting('test.competing') and title='Booking declined') then
    raise exception 'Tutor decline notification missing';
  end if;
  select starts into slot from public.tutor_bookable_slots(auth.uid(),60) as starts where starts > now() + interval '12 hours' limit 1;
  perform set_config('test.invitation',public.request_tutoring_booking(auth.uid(),'ad000000-0000-4000-8000-000000000003',
    current_setting('test.subject')::bigint,slot,60,'online','individual','')::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000003',true);
do $$
begin
  if not exists(select 1 from public.notifications where data->>'bookingId'=current_setting('test.competing') and title='Booking declined') then
    raise exception 'Student decline notification missing';
  end if;
  perform public.respond_to_tutoring_booking(current_setting('test.invitation')::uuid,'accept');
end;
$$;

select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000001',true);
do $$
declare booking_key uuid := current_setting('test.booking')::uuid; item uuid;
begin
  if not exists(select 1 from public.notifications where data->>'bookingId'=booking_key::text and title='Booking accepted') then raise exception 'Student acceptance notification missing'; end if;
  item := public.report_booking_concern(booking_key,'lesson_quality','Please review the quality of this lesson.');
  perform set_config('test.case',item::text,true);
  if exists(select 1 from public.booking_safety_cases where booking_safety_cases.id=item) then raise exception 'Participant bypassed the private review queue'; end if;
  begin
    perform public.open_booking_safety_case(item);
    raise exception 'Participant opened administrative case details';
  exception when insufficient_privilege then null;
  end;
end;
$$;

select set_config('request.jwt.claim.sub','ad000000-0000-4000-8000-000000000004',true);
do $$
declare item uuid := current_setting('test.case')::uuid; details jsonb; metrics jsonb;
begin
  if exists(select 1 from public.bookings where id=current_setting('test.booking')::uuid) then raise exception 'Administrator retained direct booking access'; end if;
  if not exists(select 1 from public.booking_safety_cases where id=item) then raise exception 'Admin case queue is empty'; end if;
  details := public.open_booking_safety_case(item);
  if details->'booking'->>'tutor' is distinct from 'Case Tutor' then raise exception 'Case-scoped access failed'; end if;
  perform public.review_booking_safety_case(item,'investigating','',1);
  perform public.review_booking_safety_case(item,'resolved','Reviewed and recorded the resolution.',2);
  if public.open_booking_safety_case(item)->'booking' <> 'null'::jsonb then raise exception 'Closed case retained access to booking details'; end if;
  metrics := public.admin_booking_metrics();
  if jsonb_array_length(metrics->'bookings') < 1 or metrics::text like '%'||current_setting('test.booking')||'%'
    then raise exception 'Analytics missing or exposed a booking identifier'; end if;
end;
$$;
reset role;

do $$
begin
  if (select count(*) from private.booking_safety_case_audit where case_id=current_setting('test.case')::uuid) <> 3 then
    raise exception 'Case access and changes were not audited';
  end if;
  if (select count(*) from public.notifications where user_id='ad000000-0000-4000-8000-000000000001'
    and title in ('Safety report closed','Safety report under review') and data->>'bookingId'=current_setting('test.booking')) <> 2 then
    raise exception 'Reporter case status notifications missing';
  end if;
end;
$$;

rollback;
