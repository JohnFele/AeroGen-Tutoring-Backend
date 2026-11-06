begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,last_sign_in_at) values
 ('d6010000-0000-4000-8000-000000000001','impact.student@example.test','{}','{}',now()-interval '2 days'),
 ('d6010000-0000-4000-8000-000000000002','impact.tutor@example.test','{}','{}',now()-interval '60 days'),
 ('d6010000-0000-4000-8000-000000000003','impact.demo@example.test','{}','{}',now()),
 ('d6010000-0000-4000-8000-000000000004','impact.admin@example.test','{}','{}',now());
update public.profiles set role='tutor' where id='d6010000-0000-4000-8000-000000000002';
update public.profiles set demo_dataset='impact-test' where id='d6010000-0000-4000-8000-000000000003';
update public.profiles set role='admin' where id='d6010000-0000-4000-8000-000000000004';
insert into public.tutor_profiles(user_id,public_name,is_approved,is_accepting_students,city)
values('d6010000-0000-4000-8000-000000000002','Impact Test Tutor',true,true,'Pretoria');
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('d6020000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 'd6010000-0000-4000-8000-000000000001','d6010000-0000-4000-8000-000000000002',
 now()-make_interval(days=>i,hours=>1),now()-make_interval(days=>i),status,'online',60,200,200
from (values(1,'completed'),(2,'no_show'),(3,'cancelled'),(4,'completed')) as fixtures(i,status);
insert into public.reviews(booking_id,student_id,tutor_id,rating,is_published)
values ('d6020000-0000-4000-8000-000000000001','d6010000-0000-4000-8000-000000000001','d6010000-0000-4000-8000-000000000002',5,true),
 ('d6020000-0000-4000-8000-000000000004','d6010000-0000-4000-8000-000000000001','d6010000-0000-4000-8000-000000000002',1,false);
with charges as (
 insert into public.payments(booking_id,payer_id,payee_id,provider,status,amount,platform_fee)
 select b.id,b.student_id,b.tutor_id,case when b.id='d6020000-0000-4000-8000-000000000001' then 'test-real-provider' else 'demo' end,
   'paid',200,30 from public.bookings b where b.id in ('d6020000-0000-4000-8000-000000000001','d6020000-0000-4000-8000-000000000004')
 returning id,booking_id
)
insert into private.lesson_funds(booking_id,payment_id,source,state,settled_at)
select booking_id,id,'checkout','released',now() from charges;

set local role anon;
do $$
declare impact jsonb := public.platform_impact();
begin
 if (impact->>'users')::int<>2 or (impact->>'activeUsers')::int<>1 or (impact->>'activeTutors')::int<>0
   or (impact->>'publishedTutors')::int<>1 then raise exception 'Registration, sign-in and tutor visibility were conflated: %',impact; end if;
 if (impact->>'hoursTutored')::numeric<>2 or (impact->>'completionRate')::numeric<>66.7
   or (impact->>'studentsTutored')::int<>1 or (impact->>'averageRating')::numeric<>5
   or (impact->>'homeHeroRating')::numeric is distinct from 5 then
   raise exception 'Lesson aggregates did not use completed lessons, valid outcomes and published reviews: %',impact;
 end if;
 if (impact->>'releasedTutorEarnings')::numeric<>170 then raise exception 'Simulated earnings were included: %',impact; end if;
end;
$$;
reset role;

-- A 2.95 average displays as 3.0 elsewhere, but stays out of the home hero.
update public.reviews set rating=3 where booking_id='d6020000-0000-4000-8000-000000000001';
insert into public.bookings(id,student_id,tutor_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('d6020000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
 'd6010000-0000-4000-8000-000000000001','d6010000-0000-4000-8000-000000000002',
 now()-make_interval(days=>i,hours=>1),now()-make_interval(days=>i),'completed','online',60,200,200
from generate_series(5,23) as fixtures(i);
insert into public.reviews(booking_id,student_id,tutor_id,rating,is_published)
select id,student_id,tutor_id,case when id='d6020000-0000-4000-8000-000000000023' then 2 else 3 end,true
from public.bookings where id between 'd6020000-0000-4000-8000-000000000005' and 'd6020000-0000-4000-8000-000000000023';
set local role anon;
do $$
declare impact jsonb := public.platform_impact();
begin
 if (impact->>'averageRating')::numeric is distinct from 3 or impact->>'homeHeroRating' is not null then
   raise exception 'The home hero rating used the rounded average: %',impact;
 end if;
end;
$$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','d6010000-0000-4000-8000-000000000001',true);
do $$
begin
 perform public.admin_active_accounts();
 raise exception 'A student accessed admin activity metrics';
exception when insufficient_privilege then null;
end;
$$;
select set_config('request.jwt.claim.sub','d6010000-0000-4000-8000-000000000004',true);
do $$
begin
 if public.admin_active_accounts()<>jsonb_build_object('live',2,'all',3) then
   raise exception 'Admin demo and live account totals were mixed';
 end if;
end;
$$;

rollback;
