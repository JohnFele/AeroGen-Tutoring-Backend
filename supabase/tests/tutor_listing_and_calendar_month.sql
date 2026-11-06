begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('d6410000-0000-4000-8000-000000000001','listing-tutor@example.test','{}','{}'),
  ('d6410000-0000-4000-8000-000000000002','listing-student@example.test','{}','{}');
update public.profiles set role='tutor' where id='d6410000-0000-4000-8000-000000000001';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,hourly_rate,teaching_modes,students_per_session)
values ('d6410000-0000-4000-8000-000000000001','Listing Tutor',true,true,250,array['online'],'1');

set local role authenticated;
select set_config('request.jwt.claim.sub','d6410000-0000-4000-8000-000000000001',true);
do $$
declare
  stamp timestamptz := (select updated_at from public.tutor_profiles where user_id=auth.uid());
  target date := (date_trunc('month',now() at time zone 'Africa/Johannesburg')+interval '1 month')::date;
  calendar jsonb;
begin
  perform public.save_my_tutor_listing('{"hourly_rate":325.50,"teaching_modes":["online"],"years_experience":5.5}',stamp);
  if (select hourly_rate from public.tutor_directory where id=auth.uid()) is distinct from 325.50 then
    raise exception 'Public rate did not update';
  end if;
  begin
    perform public.save_my_tutor_listing('{"is_approved":false}',stamp);
    raise exception 'Protected approval state was editable';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.save_my_tutor_listing('{"hourly_rate":10}',stamp-interval '1 second');
    raise exception 'Stale profile edits were accepted';
  exception when sqlstate 'PT409' then null;
  end;
  perform public.save_booking_day(target,'custom',600,720);
  perform public.save_booking_day(target+1,'closed',null,null);
  calendar := public.my_booking_month(target);
  if calendar->0->>'mode' <> 'custom' or (calendar->0->'hours'->>'start_minute')::int <> 600
    or calendar->1->>'mode' <> 'closed' or calendar->2->>'mode' <> 'weekly'
    or calendar->2->'hours' <> 'null'::jsonb then
    raise exception 'Month did not reflect the correct availability: %',calendar;
  end if;
end;
$$;
select set_config('request.jwt.claim.sub','d6410000-0000-4000-8000-000000000002',true);
do $$
declare target date := (date_trunc('month',now() at time zone 'Africa/Johannesburg')+interval '1 month')::date;
begin
  begin
    perform public.save_my_tutor_listing('{"hourly_rate":1}',now());
    raise exception 'A student edited tutor listing details';
  exception when insufficient_privilege then null;
  end;
  if public.my_booking_month(target)->0->>'mode' <> 'weekly' then
    raise exception 'Tutor date overrides leaked into the student calendar';
  end if;
  perform public.save_booking_day(target,'custom',540,600);
  if public.my_booking_month(target)->0->>'mode' <> 'custom' then
    raise exception 'Student calendar did not reflect its date override';
  end if;
end;
$$;
rollback;
