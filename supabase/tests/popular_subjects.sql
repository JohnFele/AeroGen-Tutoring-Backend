begin;

insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data,last_sign_in_at)
select ('d6110000-0000-4000-8000-'||lpad(i::text,12,'0'))::uuid,
  'popularity-'||i||'@example.test','{}','{}',now()-make_interval(days=>age)
from (values (1,2),(2,5),(3,60),(4,2),(5,2),(6,2)) as fixtures(i,age);
update public.profiles set demo_dataset='popularity-test' where id='d6110000-0000-4000-8000-000000000004';
update public.profiles set role='tutor' where id in ('d6110000-0000-4000-8000-000000000005','d6110000-0000-4000-8000-000000000006');
insert into public.tutor_profiles(user_id,public_name,demo_dataset)
values ('d6110000-0000-4000-8000-000000000005','Popularity Tutor',null),
       ('d6110000-0000-4000-8000-000000000006','Demo Popularity Tutor','popularity-test');

insert into public.subjects(name,category,slug)
values ('Demand Alpha','Mathematics','demand-alpha'),
       ('Demand Beta','Mathematics','demand-beta'),
       ('Demand Gamma','Mathematics','demand-gamma');

insert into public.bookings(id,student_id,tutor_id,subject_id,starts_at,ends_at,status,teaching_mode,duration_minutes,hourly_rate,total_amount)
select ('d6120000-0000-4000-8000-'||lpad(f.id::text,12,'0'))::uuid,
  ('d6110000-0000-4000-8000-'||lpad(f.student::text,12,'0'))::uuid,
  ('d6110000-0000-4000-8000-'||lpad(f.tutor::text,12,'0'))::uuid,
  s.id, now()+make_interval(days=>f.day), now()+make_interval(days=>f.day,hours=>1),
  f.status,'online',60,200,200
from (values
  (1,'demand-alpha',1,5,-1,'completed'),
  (2,'demand-alpha',2,5,2,'confirmed'),
  (3,'demand-beta',1,5,-3,'completed'),
  (4,'demand-beta',3,5,-4,'completed'),
  (5,'demand-beta',1,5,-5,'completed'),
  (6,'demand-gamma',1,5,-6,'completed'),
  (7,'demand-gamma',1,5,-7,'completed'),
  (8,'demand-gamma',2,5,8,'confirmed'),
  (9,'demand-gamma',2,5,-9,'cancelled'),
  (10,'demand-gamma',2,5,-100,'completed'),
  (11,'demand-gamma',4,5,-11,'completed'),
  (12,'demand-gamma',2,6,-12,'completed'),
  (13,'demand-gamma',2,5,-13,'pending'),
  (14,'demand-gamma',2,5,-14,'no_show')
) as f(id,slug,student,tutor,day,status) join public.subjects s on s.slug=f.slug;

with paid as (
  insert into public.payments(booking_id,payer_id,payee_id,provider,status,amount,platform_fee)
  select id,student_id,tutor_id,'test-provider','paid',200,0 from public.bookings
  where id='d6120000-0000-4000-8000-000000000002'
  returning id,booking_id
)
insert into private.lesson_funds(booking_id,payment_id,source,state)
select booking_id,id,'checkout','held' from paid;

set local role anon;
do $$
declare ranked text[] := public.popular_subject_slugs();
begin
  if ranked is distinct from array['demand-alpha','demand-beta'] then
    raise exception 'Unexpected popularity ranking: %', ranked;
  end if;
end;
$$;

rollback;
