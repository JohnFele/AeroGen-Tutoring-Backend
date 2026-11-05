begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('da000000-0000-4000-8000-000000000001','availability.student@example.test','{}','{}'),
  ('da000000-0000-4000-8000-000000000002','availability.tutor@example.test','{}','{}'),
  ('da000000-0000-4000-8000-000000000003','availability.other@example.test','{}','{}');
update public.profiles set role='tutor' where id in ('da000000-0000-4000-8000-000000000002','da000000-0000-4000-8000-000000000003');
update public.profiles set first_name='Schedule',last_name='Testlearner' where id='da000000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,teaching_modes,hourly_rate)
values ('da000000-0000-4000-8000-000000000002','Availability Tutor',true,true,array['online'],180),
  ('da000000-0000-4000-8000-000000000003','Second Tutor',true,true,array['online'],180);
with new_subject as (
  insert into public.subjects(name,category,slug) values ('Mutual availability test','General','mutual-availability-test') returning id
)
insert into public.tutor_subjects(tutor_id,subject_id)
select t.user_id,s.id from public.tutor_profiles t cross join new_subject s
where t.user_id in ('da000000-0000-4000-8000-000000000002','da000000-0000-4000-8000-000000000003');
select set_config('test.av_subject',(select id::text from public.subjects where slug='mutual-availability-test'),true);
select set_config('test.av_start',(((now() at time zone 'Africa/Johannesburg')::date+1+time '10:00') at time zone 'Africa/Johannesburg')::text,true);
select set_config('test.av_hours',(select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',540,'end_minute',780))::text from generate_series(1,7) d),true);
select set_config('test.av_student_hours',(select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',600,'end_minute',720))::text from generate_series(1,7) d),true);

set local role authenticated;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000002',true);
select public.save_booking_availability(current_setting('test.av_hours')::jsonb,false);
do $$
begin
  if exists(select 1 from public.search_bookable_students('Schedule')) then raise exception 'A private student was discoverable by name'; end if;
  if public.booking_slot_options(auth.uid(),'da000000-0000-4000-8000-000000000001',60)->>'studentReady' is distinct from 'false' then
    raise exception 'Tutor could propose before the student set hours';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000003',true);
select public.save_booking_availability(current_setting('test.av_hours')::jsonb,false);
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
select public.save_booking_availability(current_setting('test.av_student_hours')::jsonb,true);
select public.change_membership('learning',true,gen_random_uuid());
reset role;
-- Model the last credit in a package without creating seven unrelated sessions.
update private.billing_events set lesson_credits_awarded=1 where owner='da000000-0000-4000-8000-000000000001' and kind='subscription';

set local role authenticated;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
do $$
declare
  tutor constant uuid := 'da000000-0000-4000-8000-000000000002';
  starts timestamptz := current_setting('test.av_start')::timestamptz;
  booking_id uuid;
begin
  if public.my_booking_availability()->>'discoverable' is distinct from 'true' then raise exception 'Student settings did not persist'; end if;
  if exists(select 1 from public.tutors_available_at(starts-interval '1 hour',60))
    or (select count(*) from public.tutors_available_at(starts,60))<>2 then
    raise exception 'Exact tutor search ignored either participant’s hours';
  end if;
  booking_id := public.request_tutoring_booking(tutor,auth.uid(),current_setting('test.av_subject')::bigint,starts,60,'online','individual','');
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '1' then raise exception 'Pending request used a credit'; end if;
  perform set_config('test.av_booking',booking_id::text,true);
end;
$$;

select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000002',true);
do $$
declare booking_id uuid := current_setting('test.av_booking')::uuid;
begin
  if (select name from public.search_bookable_students('Schedule Testlearner')) is distinct from 'Schedule T.' then
    raise exception 'Student discovery is missing or exposes too much';
  end if;
  if public.respond_to_tutoring_booking(booking_id,'accept')<>'confirmed' or public.respond_to_tutoring_booking(booking_id,'accept')<>'confirmed' then
    raise exception 'Booking acceptance did not persist or replay';
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000003',true);
select set_config('test.av_second',public.request_tutoring_booking(auth.uid(),'da000000-0000-4000-8000-000000000001',
  current_setting('test.av_subject')::bigint,current_setting('test.av_start')::timestamptz+interval '1 hour',60,'online','individual','')::text,true);

select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
do $$
begin
  if public.my_account_billing()->'lesson_credits'->>'reserved' is distinct from '1'
    or exists(select 1 from public.tutors_available_at(current_setting('test.av_start')::timestamptz,60)) then
    raise exception 'Acceptance failed to reserve a credit or block the occupied time';
  end if;
  begin
    perform public.respond_to_tutoring_booking(current_setting('test.av_second')::uuid,'accept');
    raise exception 'A second booking was accepted without credits';
  exception when sqlstate 'PT409' then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000002',true);
select public.respond_to_tutoring_booking(current_setting('test.av_booking')::uuid,'cancel');
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
do $$
begin
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '1' then raise exception 'Tutor cancellation did not restore the credit'; end if;
  perform public.respond_to_tutoring_booking(current_setting('test.av_second')::uuid,'accept');
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '0' then raise exception 'Student acceptance did not reserve a credit'; end if;
end;
$$;
reset role;
update public.bookings set starts_at=now()+interval '1 hour',ends_at=now()+interval '2 hours'
where id=current_setting('test.av_second')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
do $$
begin
  perform public.respond_to_tutoring_booking(current_setting('test.av_second')::uuid,'cancel');
  raise exception 'Cancellation was allowed inside the cutoff';
exception when sqlstate 'PT409' then null;
end;
$$;
reset role;
update public.bookings set starts_at=now()+interval '3 hours',ends_at=now()+interval '4 hours'
where id=current_setting('test.av_second')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','da000000-0000-4000-8000-000000000001',true);
do $$
begin
  perform public.respond_to_tutoring_booking(current_setting('test.av_second')::uuid,'cancel');
  if public.my_account_billing()->'lesson_credits'->>'available' is distinct from '1' then raise exception 'Student cancellation did not restore the credit'; end if;
end;
$$;

rollback;
