-- Apply the home hero cutoff to the unrounded review average.
create or replace function public.platform_impact() returns jsonb
language sql stable security definer set search_path = '' as $$
  with members as (
    select p.id,p.role,u.last_sign_in_at
    from public.profiles p join auth.users u on u.id=p.id
    where p.role in ('student','tutor') and p.demo_dataset is null
  ), tutors as (
    select t.user_id,t.is_approved,t.is_accepting_students,t.city
    from public.tutor_profiles t join members m on m.id=t.user_id and m.role='tutor'
    where t.demo_dataset is null
  ), lessons as (
    select b.id,b.student_id,b.status,b.duration_minutes
    from public.bookings b join members s on s.id=b.student_id and s.role='student'
    join tutors t on t.user_id=b.tutor_id
    where b.status in ('completed','no_show') and b.ends_at<=now()
  ), delivery as (
    select count(*) filter(where status='completed') as completed,count(*) as concluded,
      count(distinct student_id) filter(where status='completed') as students,
      coalesce(sum(duration_minutes) filter(where status='completed'),0) as minutes
    from lessons
  ), lesson_rating as (
    select avg(r.rating) as value from public.reviews r join lessons l on l.id=r.booking_id
    where r.is_published and l.status='completed'
  )
  select jsonb_build_object(
    'users',(select count(*) from members),
    'activeUsers',(select count(*) from members where last_sign_in_at>=now()-interval '30 days'),
    'registeredStudents',(select count(*) from members where role='student'),
    'studentsTutored',delivery.students,
    'activeTutors',(select count(*) from tutors t join members m on m.id=t.user_id
      where t.is_approved and m.last_sign_in_at>=now()-interval '30 days'),
    'publishedTutors',(select count(*) from tutors where is_approved and is_accepting_students),
    'tutorCities',(select count(distinct nullif(lower(btrim(city)),'')) from tutors where is_approved and is_accepting_students),
    'publishedSubjects',(select count(*) from public.subjects s
      where s.is_active and exists(select 1 from public.tutor_subjects ts join tutors t on t.user_id=ts.tutor_id
        where ts.subject_id=s.id and t.is_approved and t.is_accepting_students)),
    'averageRating',round(lesson_rating.value,1),
    'homeHeroRating',case when lesson_rating.value>=3 then round(lesson_rating.value,1) end,
    'hoursTutored',round(delivery.minutes / 60.0,1),
    'completionRate',round(delivery.completed*100.0/nullif(delivery.concluded,0),1),
    'releasedTutorEarnings',(select coalesce(sum(p.amount-p.platform_fee),0)
      from private.lesson_funds f join public.payments p on p.id=f.payment_id join lessons l on l.id=f.booking_id
      where f.state='released' and p.status='paid' and p.provider<>'demo' and l.status='completed'),
    'openPositions',(select count(*) from public.career_openings
      where status='published' and (closes_on is null or closes_on>=(now() at time zone 'Africa/Johannesburg')::date))
  ) from delivery cross join lesson_rating;
$$;
