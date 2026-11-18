begin;
-- Successful staff workflows model a verified MFA session; denial cases are in staff_mfa.sql.
select set_config('request.jwt.claims',jsonb_build_object('aal','aal2','amr',jsonb_build_array(jsonb_build_object('method','totp','timestamp',extract(epoch from now())::bigint)))::text,true);

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data) values
  ('c1700000-0000-4000-8000-000000000001','attendance.student@example.test','{}','{}'),
  ('c1700000-0000-4000-8000-000000000002','attendance.tutor@example.test','{}','{}'),
  ('c1700000-0000-4000-8000-000000000003','attendance.staff@example.test','{}','{}'),
  ('c1700000-0000-4000-8000-000000000004','attendance.outside@example.test','{}','{}');
update public.profiles set role='tutor' where id='c1700000-0000-4000-8000-000000000002';
update public.profiles set role='admin' where id='c1700000-0000-4000-8000-000000000003';
insert into public.tutor_profiles(user_id,public_name,is_approved,hourly_rate,teaching_modes)
values ('c1700000-0000-4000-8000-000000000002','Attendance Test Tutor',true,200,array['online']);

insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount,proposed_by)
select ('c1710000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'c1700000-0000-4000-8000-000000000001','c1700000-0000-4000-8000-000000000002',
  starts,starts+interval '1 hour',status,'online',60,200,200,'c1700000-0000-4000-8000-000000000002'
from (values
  (1,now()-interval '4 hours','pending'),(2,now()+interval '1 day','pending'),
  (3,now()-interval '2 hours','completed'),
  (4,(date_trunc('month',now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg')+interval '1 day','confirmed'),
  (5,(date_trunc('month',now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg')+interval '2 days','confirmed'),
  (6,(date_trunc('month',now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg')-interval '1 day','confirmed'),
  (7,(date_trunc('month',now() at time zone 'Africa/Johannesburg') at time zone 'Africa/Johannesburg')+interval '3 days','confirmed'),
  (8,now()-interval '30 minutes','pending')
) fixture(n,starts,status);

do $$
begin
  perform private.expire_lesson_invitations();
  perform private.expire_lesson_invitations();
  if (select status from public.bookings where id='c1710000-0000-4000-8000-000000000001') <> 'declined'
    or (select invitation_expired_at from public.bookings where id='c1710000-0000-4000-8000-000000000001') is null
    or (select status from public.bookings where id='c1710000-0000-4000-8000-000000000002') <> 'pending' then
    raise exception 'Invitation deadline did not distinguish past and future';
  end if;
  if (select count(*) from public.notifications where title='Lesson invitation expired'
      and data->>'bookingId'='c1710000-0000-4000-8000-000000000001') <> 2 then
    raise exception 'Expected one expiration notification per participant';
  end if;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub','c1700000-0000-4000-8000-000000000004',true);
do $$
begin
  begin
    perform public.report_booking_ticket('c1710000-0000-4000-8000-000000000001','attendance','I was not a participant in this lesson.');
    raise exception 'Outsider filed a private attendance ticket';
  exception when insufficient_privilege then null; end;
  begin
    perform public.rate_completed_lesson('c1710000-0000-4000-8000-000000000003',5);
    raise exception 'Outsider rated a private lesson';
  exception when insufficient_privilege then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','c1700000-0000-4000-8000-000000000001',true);
do $$
declare expired text;
begin
  expired := public.report_booking_ticket('c1710000-0000-4000-8000-000000000001','attendance','The lesson happened as scheduled despite the invitation expiring.')->>'id';
  begin
    perform public.report_booking_ticket('c1710000-0000-4000-8000-000000000002','attendance','The tutor and I are planning to meet at the scheduled time.');
    raise exception 'A future lesson allowed an attendance request';
  exception when sqlstate 'PT409' then null; end;
  begin
    perform public.report_booking_ticket('c1710000-0000-4000-8000-000000000008','attendance','This lesson is still within its scheduled teaching time.');
    raise exception 'An ongoing lesson allowed an attendance request';
  exception when sqlstate 'PT409' then null; end;
  if public.my_support_ticket(expired::uuid)->>'can_resolve' is distinct from 'false' then
    raise exception 'Participant could bypass the attendance decision';
  end if;
  perform set_config('test.attendance_expired',expired,true);
end;
$$;

select set_config('request.jwt.claim.sub','c1700000-0000-4000-8000-000000000003',true);
do $$
declare expired uuid := current_setting('test.attendance_expired')::uuid;
begin
  perform public.update_support_ticket(expired,1,'investigating','','',null);
  perform public.update_support_ticket(expired,2,'resolved','','Both participants confirmed the lesson took place.','happened');
end;
$$;

select set_config('request.jwt.claim.sub','c1700000-0000-4000-8000-000000000001',true);
do $$
declare first_lesson uuid := 'c1710000-0000-4000-8000-000000000001';
  first_rating jsonb; retried_rating jsonb;
begin
  if jsonb_array_length(public.my_tutoring_workspace()->'lesson_rating_prompts') <> 1
    or public.my_tutoring_workspace()->'lesson_rating_prompts'->0->>'booking_id' <> first_lesson::text then
    raise exception 'The same counterpart generated multiple prompts or the wrong first lesson';
  end if;
  first_rating := public.rate_completed_lesson(first_lesson,5);
  retried_rating := public.rate_completed_lesson(first_lesson,1);
  if first_rating->>'rating' is distinct from '5' or retried_rating->>'rating' is distinct from '5'
    or jsonb_array_length(public.my_tutoring_workspace()->'lesson_rating_prompts') <> 0 then
    raise exception 'Rating did not persist once, or prompt was not removed';
  end if;
  begin
    perform public.rate_completed_lesson('c1710000-0000-4000-8000-000000000003',4);
    raise exception 'A repeat lesson created another rating';
  exception when sqlstate 'PT409' then null; end;
end;
$$;

select set_config('request.jwt.claim.sub','c1700000-0000-4000-8000-000000000002',true);
do $$
begin
  if public.my_tutoring_workspace()->'lesson_rating_prompts'->0->>'for_tutor' is distinct from 'false' then
    raise exception 'Tutor could not rate their student';
  end if;
  perform public.rate_completed_lesson('c1710000-0000-4000-8000-000000000001',4);
  if jsonb_array_length(public.my_tutoring_workspace()->'lesson_rating_prompts') <> 0 then
    raise exception 'Tutor rating prompt was not cleared';
  end if;
end;
$$;
reset role;

insert into public.payments(id,booking_id,payer_id,payee_id,provider,status,amount,platform_fee,paid_at)
select ('c1720000-0000-4000-8000-'||right(b.id::text,12))::uuid,b.id,b.student_id,b.tutor_id,'demo',
  case when right(b.id::text,1)='7' then 'pending' else 'paid' end,200,20,
  case when right(b.id::text,1)<>'7' then now() end
from public.bookings b where left(b.id::text,8)='c1710000' and right(b.id::text,1) between '4' and '7';
insert into private.lesson_funds(booking_id,payment_id,source,state,settled_at)
select booking_id,id,'checkout',case right(id::text,1) when '4' then 'released' when '6' then 'disputed' else 'held' end,
  case when right(id::text,1)='4' then now() end
from public.payments where left(id::text,8)='c1720000';

do $$
declare stats jsonb; tutor uuid := 'c1700000-0000-4000-8000-000000000002';
begin
  if (select count(*) from public.reviews where tutor_id=tutor) <> 1
    or (select count(*) from private.student_lesson_ratings where tutor_id=tutor) <> 1
    or exists(select 1 from public.payments where booking_id='c1710000-0000-4000-8000-000000000001') then
    raise exception 'Attendance or rating changed billing or double counted a review';
  end if;
  stats := private.tutor_billing_performance(tutor);
  if (stats->>'released_month_cents')::integer <> 18000
    or (stats->>'unreleased_month_cents')::integer <> 18000
    or (stats->>'unreleased_cents')::integer <> 36000
    or (stats->>'rating_average')::numeric <> 5 or (stats->>'rating_count')::integer <> 1 then
    raise exception 'Unexpected tutor performance totals: %',stats;
  end if;
end;
$$;

rollback;
