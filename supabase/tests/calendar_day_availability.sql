begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('db000000-0000-4000-8000-000000000001','day.student@example.test','{}','{}'),
  ('db000000-0000-4000-8000-000000000002','day.tutor@example.test','{}','{}'),
  ('db000000-0000-4000-8000-000000000003','day.unrelated@example.test','{}','{}');
update public.profiles set role='tutor' where id='db000000-0000-4000-8000-000000000002';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,teaching_modes,hourly_rate)
values ('db000000-0000-4000-8000-000000000002','Calendar Day Tutor',true,true,array['online'],180);
select set_config('test.day',(private.booking_local_today()+2)::text,true);
select set_config('test.day_two',(private.booking_local_today()+3)::text,true);
select set_config('test.day_start',((current_setting('test.day')::date+time '10:00') at time zone 'Africa/Johannesburg')::text,true);

set local role authenticated;
select set_config('request.jwt.claim.sub','db000000-0000-4000-8000-000000000002',true);
do $$
declare target date := current_setting('test.day')::date;
begin
  perform public.save_booking_availability((select jsonb_agg(jsonb_build_object('weekday',d,'start_minute',540,'end_minute',720))
    from generate_series(1,7) d),false);
  if public.save_booking_day(target,'custom',600,660)->'hours'->>'start_minute' is distinct from '600' then
    raise exception 'Saving a one-day override did not return its hours';
  end if;
  if public.my_booking_day(target+1)->'hours'->>'start_minute' is distinct from '540' then
    raise exception 'The override changed an unrelated day';
  end if;
  if (select count(*) from public.tutor_bookable_slots(auth.uid(),60) as starts
      where (starts at time zone 'Africa/Johannesburg')::date=target)<>1 then
    raise exception 'The booking picker ignored the override or duration';
  end if;
  if public.save_booking_day(target,'closed',null,null)->>'mode' is distinct from 'closed' then
    raise exception 'The closed override did not save';
  end if;
  if exists(select 1 from public.tutors_available_at(current_setting('test.day_start')::timestamptz,60)) then
    raise exception 'A closed date was offered by exact-time search';
  end if;
  if public.save_booking_day(target,'weekly',null,null)->'hours'->>'start_minute' is distinct from '540' then
    raise exception 'Weekly hours did not return after clearing the override';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','db000000-0000-4000-8000-000000000001',true);
select public.save_booking_day(current_setting('test.day')::date,'custom',600,660);
select set_config('request.jwt.claim.sub','db000000-0000-4000-8000-000000000002',true);
do $$
declare
  student constant uuid := 'db000000-0000-4000-8000-000000000001';
  options jsonb := public.booking_slot_options(auth.uid(),student,60);
begin
  if options->>'studentReady' is distinct from 'true' or jsonb_array_length(options->'slots')<>1 then
    raise exception 'A date-only student schedule did not limit proposals to the matching slot';
  end if;
end;
$$;
reset role;

insert into public.bookings(student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
values ('db000000-0000-4000-8000-000000000001','db000000-0000-4000-8000-000000000002',
  current_setting('test.day_start')::timestamptz,current_setting('test.day_start')::timestamptz+interval '1 hour','confirmed','online',60,180,180);

set local role authenticated;
select set_config('request.jwt.claim.sub','db000000-0000-4000-8000-000000000002',true);
do $$
declare target date := current_setting('test.day')::date;
begin
  perform public.save_booking_day(target,'custom',600,660);
  if exists(select 1 from public.tutor_bookable_slots(auth.uid(),30) starts
    where (starts at time zone 'Africa/Johannesburg')::date=target) then
    raise exception 'A fully booked date returned selectable starts';
  end if;
  perform public.save_booking_day(target,'closed',null,null);
  if not exists(select 1 from public.bookings where tutor_id=auth.uid() and status='confirmed') then
    raise exception 'An availability edit changed an existing booking';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub','db000000-0000-4000-8000-000000000003',true);
do $$
begin
  if public.my_booking_day(current_setting('test.day')::date)->>'mode' is distinct from 'weekly' then
    raise exception 'Another account could see the tutor’s date settings';
  end if;
end;
$$;
reset role;

do $$
begin
  if has_function_privilege('anon','public.save_booking_day(date,text,integer,integer)','execute') then
    raise exception 'Public user can edit availability';
  end if;
end;
$$;

rollback;
