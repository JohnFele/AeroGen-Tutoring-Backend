begin;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
 ('c2100000-0000-4000-8000-000000000001','format.student@example.test','{}','{}'),
 ('c2100000-0000-4000-8000-000000000002','format.tutor@example.test','{}','{}'),
 ('c2100000-0000-4000-8000-000000000003','format.other@example.test','{}','{}');
update public.profiles set role='tutor' where id in ('c2100000-0000-4000-8000-000000000002','c2100000-0000-4000-8000-000000000003');
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,teaching_modes,hourly_rate,students_per_session,city,province)
values ('c2100000-0000-4000-8000-000000000002','Format Tutor',true,true,array['online','in-person'],200,'1','Johannesburg','Gauteng'),
 ('c2100000-0000-4000-8000-000000000003','Other Tutor',true,true,array['online'],200,'1',null,null);
insert into public.tutor_subjects(tutor_id,subject_id)
select 'c2100000-0000-4000-8000-000000000002',id from public.subjects where is_active order by id limit 1;
select set_config('test.format_subject',(select subject_id::text from public.tutor_subjects where tutor_id='c2100000-0000-4000-8000-000000000002' limit 1),true);
select set_config('test.format_start',((private.booking_local_today()+2+time '10:00') at time zone 'Africa/Johannesburg')::text,true);
select set_config('test.format_series_start',((private.booking_local_today()+3+time '10:00') at time zone 'Africa/Johannesburg')::text,true);
select set_config('test.format_hours',(select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',540,'end_minute',1020))::text from generate_series(1,7)d),true);

set local role authenticated;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
select public.save_booking_availability(current_setting('test.format_hours')::jsonb,false);
select public.save_my_tutor_listing('{"online_hourly_rate":180,"in_person_hourly_rate":360}'::jsonb,
 (select updated_at from public.tutor_profiles where user_id=auth.uid()));
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
select public.save_booking_availability(current_setting('test.format_hours')::jsonb,true);
select public.change_membership('learning',true,gen_random_uuid());
select set_config('test.format_online',public.request_tutoring_booking('c2100000-0000-4000-8000-000000000002',auth.uid(),
 current_setting('test.format_subject')::bigint,current_setting('test.format_start')::timestamptz,60,'online','individual','')::text,true);
select set_config('test.format_physical',public.request_tutoring_booking('c2100000-0000-4000-8000-000000000002',auth.uid(),
 current_setting('test.format_subject')::bigint,current_setting('test.format_start')::timestamptz+interval '2 hours',60,'in-person','individual','')::text,true);
insert into public.saved_tutors(user_id,tutor_id) values(auth.uid(),'c2100000-0000-4000-8000-000000000002');
do $$
begin
 if (select hourly_rate from public.bookings where id=current_setting('test.format_online')::uuid)<>180
  or (select total_amount from public.bookings where id=current_setting('test.format_physical')::uuid)<>360 then raise exception 'Booking prices did not use the selected format'; end if;
 if jsonb_array_length(public.my_student_tutors())<>1 or public.my_student_tutors()->0->>'online_hourly_rate'<>'180.00' then
  raise exception 'The student tutor list lost the saved relationship or format prices: %',public.my_student_tutors(); end if;
end; $$;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
select public.respond_to_tutoring_booking(current_setting('test.format_online')::uuid,'accept');
select public.respond_to_tutoring_booking(current_setting('test.format_physical')::uuid,'accept');
select public.save_my_tutor_listing('{"online_hourly_rate":190,"in_person_hourly_rate":500}'::jsonb,
 (select updated_at from public.tutor_profiles where user_id=auth.uid()));
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
select public.checkout_booking(current_setting('test.format_physical')::uuid,'package',true,gen_random_uuid());
reset role;
do $$
begin
 if (select top_up_cents from private.lesson_funds where booking_id=current_setting('test.format_online')::uuid)<>0
  or (select top_up_cents from private.lesson_funds where booking_id=current_setting('test.format_physical')::uuid)<>13000
  or (select amount from public.payments where booking_id=current_setting('test.format_physical')::uuid)<>360 then
  raise exception 'Package coverage, the top-up, or the agreed booking price changed incorrectly'; end if;
end; $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
select public.save_booking_day((current_setting('test.format_series_start')::timestamptz at time zone 'Africa/Johannesburg')::date+14,'closed',null,null);
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
do $$
declare tutor uuid:='c2100000-0000-4000-8000-000000000002'; subject bigint:=current_setting('test.format_subject')::bigint;
 starts timestamptz:=current_setting('test.format_series_start')::timestamptz; preview jsonb;
begin
 preview:=public.recurring_booking_options(tutor,auth.uid(),starts,60,'weekly',4);
 if preview->2->>'available'<>'false' then raise exception 'Recurring preview ignored a closed date'; end if;
 begin
  perform public.request_recurring_tutoring_booking(tutor,auth.uid(),subject,starts,60,'online','individual','',null,'weekly',4,gen_random_uuid());
  raise exception 'A series with an unavailable occurrence was created';
 exception when sqlstate 'PT409' then null; end;
end; $$;
reset role;
do $$ begin
 if exists(select 1 from private.recurring_booking_requests where owner='c2100000-0000-4000-8000-000000000001')
  or exists(select 1 from public.bookings where series_id is not null and student_id='c2100000-0000-4000-8000-000000000001') then
  raise exception 'A failed series left partial requests'; end if;
end; $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
select public.save_booking_day((current_setting('test.format_series_start')::timestamptz at time zone 'Africa/Johannesburg')::date+14,'weekly',null,null);
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
do $$
declare request uuid:=gen_random_uuid(); result jsonb; retry jsonb; tutor uuid:='c2100000-0000-4000-8000-000000000002';
begin
 result:=public.request_recurring_tutoring_booking(tutor,auth.uid(),current_setting('test.format_subject')::bigint,
  current_setting('test.format_series_start')::timestamptz,60,'online','individual','Recurring test',null,'weekly',4,request);
 retry:=public.request_recurring_tutoring_booking(tutor,auth.uid(),current_setting('test.format_subject')::bigint,
  current_setting('test.format_series_start')::timestamptz,60,'online','individual','Recurring test',null,'weekly',4,request);
 if result is distinct from retry then raise exception 'Recurring retry was not idempotent'; end if;
 perform set_config('test.format_series',result->>'seriesId',true);
end; $$;
reset role;
do $$
declare series uuid:=current_setting('test.format_series')::uuid;
begin
 if (select count(*) from public.bookings where series_id=series)<>4
   or exists(select 1 from public.bookings where series_id=series and (status<>'pending' or hourly_rate<>190))
   or (select count(*) from public.notifications where data->>'seriesId'=series::text)<>1 then
   raise exception 'Recurring dates, prices, pending state or grouped notifications were wrong'; end if;
 if (select array_agg((starts_at at time zone 'Africa/Johannesburg')::date order by occurrence)
  from private.recurring_lesson_dates('2027-01-31T10:00:00+02:00','monthly',3))<>array['2027-01-31'::date,'2027-02-28'::date,'2027-03-31'::date] then
  raise exception 'Monthly recurrence drifted after a short month'; end if;
end; $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
do $$
declare booking record;
begin
 for booking in select id from public.bookings where series_id=current_setting('test.format_series')::uuid order by series_occurrence loop
  perform public.respond_to_tutoring_booking(booking.id,'accept');
 end loop;
end; $$;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
select set_config('test.remaining_credits',public.my_account_billing()->'lesson_credits'->>'available',true);
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000002',true);
do $$
begin
 perform set_config('test.cap_series',(public.request_recurring_tutoring_booking(auth.uid(),'c2100000-0000-4000-8000-000000000001',
  current_setting('test.format_subject')::bigint,current_setting('test.format_series_start')::timestamptz+interval '40 days',60,
  'online','individual','Capacity test',null,'daily',current_setting('test.remaining_credits')::integer+1,gen_random_uuid())->>'seriesId'),true);
end; $$;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
do $$
declare booking record; accepted integer:=0; capacity integer:=current_setting('test.remaining_credits')::integer;
begin
 for booking in select id from public.bookings where series_id=current_setting('test.cap_series')::uuid order by series_occurrence loop
  if accepted<capacity then perform public.respond_to_tutoring_booking(booking.id,'accept'); accepted:=accepted+1;
  else begin
   perform public.respond_to_tutoring_booking(booking.id,'accept'); raise exception 'Recurring acceptance exceeded the student credit balance';
  exception when sqlstate 'PT409' then null; end; end if;
 end loop;
 if (public.my_account_billing()->'lesson_credits'->>'available')::integer<>0 then raise exception 'Recurring acceptance lost or invented lesson credits'; end if;
end; $$;
reset role;
update public.tutor_profiles set is_accepting_students=false where user_id='c2100000-0000-4000-8000-000000000002';
set local role authenticated;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000001',true);
do $$ begin
 if jsonb_array_length(public.my_student_tutors())<>1 or public.my_student_tutors()->0->>'is_accepting_students'<>'false' then
  raise exception 'A paused saved tutor disappeared from the management list'; end if;
end; $$;
select set_config('request.jwt.claim.sub','c2100000-0000-4000-8000-000000000003',true);
do $$ begin
 begin perform public.my_student_tutors(); raise exception 'Tutor could access a student management list'; exception when insufficient_privilege then null; end;
end; $$;
reset role;
rollback;
